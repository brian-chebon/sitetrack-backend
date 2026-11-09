import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

import '../auth/caller.dart';
import '../db/database.dart';
import '../http/api_error.dart';
import '../http/json.dart';
import '../http/sql.dart';
import '../http/validation.dart';
import '../ids.dart';
import '../projects/project_access.dart';
import 'task_graph.dart';

/// A project's tasks, their dependencies and their status actions.
///
/// Every change locks the project row first (ProjectLock.update), then ends
/// with refresh_project_task_stats(), which recomputes Blocked and the task
/// counters. Changes within one project therefore happen one at a time,
/// which is what makes task numbers, cycle checks and the status rules hold
/// under concurrent requests.
///
/// Rules beyond the brief's:
///   * A task that has started (In progress or Done) can only gain a
///     dependency on a task that is already Done. Otherwise a task could be
///     under way, or finished, while something it waits on is not, which the
///     Start rule exists to prevent. This keeps "everything a started task
///     waits on is Done" true at all times.
///   * A task other tasks depend on cannot be removed until those
///     dependencies are removed, so nothing becomes unblocked by accident.
class TaskRoutes {
  TaskRoutes(this._db);

  final Database _db;

  static const _statuses = {
    'not_started': 'not_started',
    'in_progress': 'in_progress',
    'done': 'done',
  };

  static const _sorts = {
    'id': 'number',
    'name': 'lower(name)',
    'startDate': 'planned_start',
    'endDate': 'planned_end',
    'dependents': 'dependents_count',
  };

  /// `GET /v1/projects/{projectId}/tasks`
  ///
  /// Filters: `status` (comma-separated), `late`, `blocked`, `from` / `to`
  /// (planned period overlaps the range), `search` (name or ID).
  /// Sort: `id`, `name`, `startDate`, `endDate`, `dependents`.
  Future<Response> list(Request request, String projectId) async {
    final caller = callerOf(request);
    final query = QueryReader(request.url.queryParameters);
    final statuses = query.choices('status', _statuses);
    final late = query.boolean('late');
    final blocked = query.boolean('blocked');
    final from = query.date('from');
    final to = query.date('to');
    final search = query.search();
    final sort = query.sort(_sorts, fallback: _sorts['id']!);
    final page = query.page();
    if (from != null && to != null && to.isBefore(from)) {
      query.error('to', 'must not be before from');
    }
    query.throwIfInvalid();

    final access = await loadProject(_db.pool, caller, projectId);
    final rows = await _taskRows(
      _db.pool,
      access.id,
      statuses: statuses,
      late: late,
      blocked: blocked,
      from: from,
      to: to,
      pattern: containsPattern(search),
      order: orderBy(
        sort.key,
        descending: sort.descending,
        tieBreaker: 'number',
      ),
      limit: page.limit,
      offset: page.offset,
    );
    return jsonResponse(
      pageJson(
        [for (final row in rows) _taskJson(access.id, row)],
        total: rows.isEmpty ? 0 : rows.first['total'] as int,
        limit: page.limit,
        offset: page.offset,
      ),
    );
  }

  /// `GET /v1/projects/{projectId}/tasks/{taskId}`: the task, the status
  /// actions allowed right now, and every task upstream and downstream of it
  /// with its distance in steps.
  Future<Response> get(Request request, String projectId, String taskId) async {
    final caller = callerOf(request);
    // One snapshot for the task, its graph and its neighbours.
    final details = await _db.pool.runTx(
      (tx) async {
        final access = await loadProject(tx, caller, projectId);
        return _details(tx, access.id, _taskNumber(access, taskId));
      },
      settings: TransactionSettings(
        isolationLevel: IsolationLevel.repeatableRead,
        accessMode: AccessMode.readOnly,
      ),
    );
    return jsonResponse(details);
  }

  /// `POST /v1/projects/{projectId}/tasks` with name, plannedStart,
  /// plannedEnd and optionally dependsOn (task IDs in this project).
  Future<Response> create(Request request, String projectId) async {
    final caller = callerOf(request);
    final body = BodyReader(await readJsonObject(request));
    final name = body.string('name');
    final start = body.date('plannedStart');
    final end = body.date('plannedEnd');
    final dependsOn = body.has('dependsOn')
        ? body.list('dependsOn', minLength: 0, maxLength: 500)
        : const <Object?>[];
    if (body.has('plannedStart') &&
        body.has('plannedEnd') &&
        end.isBefore(start)) {
      body.error('plannedEnd', 'must not be before plannedStart');
    }
    body.throwIfInvalid();

    final task = await _db.transaction((tx) async {
      final access = await loadProject(
        tx,
        caller,
        projectId,
        lock: ProjectLock.update,
      );
      final prerequisites = await _existingTasks(tx, access, dependsOn);

      // Under the project lock, so concurrent creates get distinct numbers.
      // The counter is never decremented, so numbers are never reused.
      final counter = await tx.execute(
        Sql.named('''
          UPDATE projects SET last_task_number = last_task_number + 1
           WHERE id = @projectId RETURNING last_task_number'''),
        parameters: {'projectId': access.id},
      );
      final number = counter.single[0]! as int;
      await tx.execute(
        Sql.named('''
          INSERT INTO tasks (project_id, number, name, planned_start, planned_end)
          VALUES (@projectId, @number, @name, @start:date, @end:date)'''),
        parameters: {
          'projectId': access.id,
          'number': number,
          'name': name,
          'start': start,
          'end': end,
        },
      );
      // A brand-new task has nothing depending on it, so these cannot form
      // a cycle, and it has not started, so it may wait on anything.
      if (prerequisites.isNotEmpty) {
        await tx.execute(
          Sql.named('''
            INSERT INTO task_dependencies (project_id, task_number, depends_on_number)
            SELECT @projectId, @number, unnest(@prerequisites::integer[])'''),
          parameters: {
            'projectId': access.id,
            'number': number,
            'prerequisites': prerequisites.keys.toList(),
          },
        );
      }
      await _refresh(tx, access.id);
      return _details(tx, access.id, number);
    });
    return jsonResponse(task, status: 201);
  }

  /// `PATCH /v1/projects/{projectId}/tasks/{taskId}` with any of name,
  /// plannedStart, plannedEnd. Status changes only through the actions.
  Future<Response> update(
    Request request,
    String projectId,
    String taskId,
  ) async {
    final caller = callerOf(request);
    final body = BodyReader(await readJsonObject(request));
    final name = body.optionalString('name');
    final start = body.optionalDate('plannedStart');
    final end = body.optionalDate('plannedEnd');
    if (body.has('status')) {
      body.error(
        'status',
        'change status with the start, complete and reopen actions',
      );
    }
    body.throwIfInvalid();

    final task = await _db.transaction((tx) async {
      final access = await loadProject(
        tx,
        caller,
        projectId,
        lock: ProjectLock.update,
      );
      final number = _taskNumber(access, taskId);
      final current = await _task(tx, access.id, number);
      final newStart = start ?? current['planned_start'] as DateTime;
      final newEnd = end ?? current['planned_end'] as DateTime;
      if (newEnd.isBefore(newStart)) {
        throw ApiError.badRequest(
          'Some fields are invalid',
          details: {
            'fields': {'plannedEnd': 'must not be before plannedStart'},
          },
        );
      }
      await tx.execute(
        Sql.named('''
          UPDATE tasks
             SET name = coalesce(@name, name), planned_start = @start:date,
                 planned_end = @end:date, updated_at = now()
           WHERE project_id = @projectId AND number = @number'''),
        parameters: {
          'projectId': access.id,
          'number': number,
          'name': name,
          'start': newStart,
          'end': newEnd,
        },
      );
      return _details(tx, access.id, number);
    });
    return jsonResponse(task);
  }

  /// `DELETE /v1/projects/{projectId}/tasks/{taskId}`. Refused while other
  /// tasks depend on it. Its number is never reused.
  Future<Response> remove(
    Request request,
    String projectId,
    String taskId,
  ) async {
    final caller = callerOf(request);
    await _db.transaction((tx) async {
      final access = await loadProject(
        tx,
        caller,
        projectId,
        lock: ProjectLock.update,
      );
      final number = _taskNumber(access, taskId);
      await _task(tx, access.id, number);
      final dependents = await tx.execute(
        Sql.named('''
          SELECT task_number FROM task_dependencies
           WHERE project_id = @projectId AND depends_on_number = @number
           ORDER BY task_number'''),
        parameters: {'projectId': access.id, 'number': number},
      );
      if (dependents.isNotEmpty) {
        throw ApiError.conflict(
          'task_has_dependents',
          '${dependents.length} task(s) depend on this one; '
              'remove those dependencies first',
          details: {
            'dependents': [
              for (final row in dependents) taskCode(access.id, row[0]! as int),
            ],
          },
        );
      }
      await tx.execute(
        Sql.named(
          'DELETE FROM tasks WHERE project_id = @projectId AND number = @number',
        ),
        parameters: {'projectId': access.id, 'number': number},
      );
      await _refresh(tx, access.id);
    });
    return Response(204);
  }

  /// `POST .../tasks/{taskId}/start`: Not started to In progress, only when
  /// every task it waits on, directly or indirectly, is Done.
  Future<Response> start(Request request, String projectId, String taskId) =>
      _transition(request, projectId, taskId, _Action.start);

  /// `POST .../tasks/{taskId}/complete`: In progress to Done.
  Future<Response> complete(Request request, String projectId, String taskId) =>
      _transition(request, projectId, taskId, _Action.complete);

  /// `POST .../tasks/{taskId}/reopen`: Done back to In progress, only while
  /// no task that waits on it, directly or indirectly, has started.
  Future<Response> reopen(Request request, String projectId, String taskId) =>
      _transition(request, projectId, taskId, _Action.reopen);

  /// `PUT .../tasks/{taskId}/dependencies/{dependsOnId}`: makes the task wait
  /// on another task in the same project. Idempotent.
  Future<Response> addDependency(
    Request request,
    String projectId,
    String taskId,
    String dependsOnId,
  ) async {
    final caller = callerOf(request);
    final (task, created) = await _db.transaction((tx) async {
      final access = await loadProject(
        tx,
        caller,
        projectId,
        lock: ProjectLock.update,
      );
      final number = _taskNumber(access, taskId);
      final target = parseTaskCode(dependsOnId);
      if (target == null) throw ApiError.notFound('No such task');
      if (target.projectId != access.id) {
        throw ApiError.badRequest(
          'Dependencies only link tasks in the same project',
        );
      }
      final waiting = await _task(tx, access.id, number);
      final prerequisite = await _task(tx, access.id, target.number);

      if (target.number == number) {
        throw ApiError.conflict(
          'dependency_cycle',
          'A task cannot wait on itself',
        );
      }
      // Would the new edge close a loop? Only if the prerequisite already
      // waits, directly or not, on this task.
      final loop = await tx.execute(
        Sql.named('''
          WITH RECURSIVE upstream (number) AS (
              SELECT @prerequisite::integer
            UNION
              SELECT d.depends_on_number
                FROM upstream u
                JOIN task_dependencies d
                  ON d.project_id = @projectId AND d.task_number = u.number
          )
          SELECT EXISTS (SELECT 1 FROM upstream WHERE number = @number)'''),
        parameters: {
          'projectId': access.id,
          'number': number,
          'prerequisite': target.number,
        },
      );
      if (loop.single[0]! as bool) {
        throw ApiError.conflict(
          'dependency_cycle',
          '${taskCode(access.id, target.number)} already waits on '
              '${taskCode(access.id, number)}, directly or through other tasks',
        );
      }
      if (waiting['status'] != 'not_started' &&
          prerequisite['status'] != 'done') {
        throw ApiError.conflict(
          'task_already_started',
          'A task that has started can only depend on tasks that are done',
        );
      }
      final inserted = await tx.execute(
        Sql.named('''
          INSERT INTO task_dependencies (project_id, task_number, depends_on_number)
          VALUES (@projectId, @number, @prerequisite)
          ON CONFLICT DO NOTHING RETURNING 1'''),
        parameters: {
          'projectId': access.id,
          'number': number,
          'prerequisite': target.number,
        },
      );
      await _refresh(tx, access.id);
      return (await _details(tx, access.id, number), inserted.isNotEmpty);
    });
    return jsonResponse(task, status: created ? 201 : 200);
  }

  /// `DELETE .../tasks/{taskId}/dependencies/{dependsOnId}`
  Future<Response> removeDependency(
    Request request,
    String projectId,
    String taskId,
    String dependsOnId,
  ) async {
    final caller = callerOf(request);
    await _db.transaction((tx) async {
      final access = await loadProject(
        tx,
        caller,
        projectId,
        lock: ProjectLock.update,
      );
      final number = _taskNumber(access, taskId);
      final target = parseTaskCode(dependsOnId);
      final deleted = target == null || target.projectId != access.id
          ? null
          : await tx.execute(
              Sql.named('''
                DELETE FROM task_dependencies
                 WHERE project_id = @projectId AND task_number = @number
                   AND depends_on_number = @prerequisite
                RETURNING 1'''),
              parameters: {
                'projectId': access.id,
                'number': number,
                'prerequisite': target.number,
              },
            );
      if (deleted == null || deleted.isEmpty) {
        throw ApiError.notFound('No such dependency');
      }
      await _refresh(tx, access.id);
    });
    return Response(204);
  }

  Future<Response> _transition(
    Request request,
    String projectId,
    String taskId,
    _Action action,
  ) async {
    final caller = callerOf(request);
    final details = await _db.transaction((tx) async {
      final access = await loadProject(
        tx,
        caller,
        projectId,
        lock: ProjectLock.update,
      );
      final number = _taskNumber(access, taskId);
      final status = (await _task(tx, access.id, number))['status'] as String;
      if (status != action.from) {
        throw ApiError.conflict('invalid_transition', action.wrongState);
      }
      switch (action) {
        case _Action.start:
          final waiting = await _unfinishedUpstream(tx, access.id, number);
          if (waiting > 0) {
            throw ApiError.conflict(
              'task_blocked',
              'This task waits on $waiting unfinished task(s)',
            );
          }
        case _Action.reopen:
          final started = await _startedDownstream(tx, access.id, number);
          if (started > 0) {
            throw ApiError.conflict(
              'dependents_started',
              '$started task(s) waiting on this one have already started',
            );
          }
        case _Action.complete:
          break;
      }
      await tx.execute(
        Sql.named('''
          UPDATE tasks SET status = @status, updated_at = now()
           WHERE project_id = @projectId AND number = @number'''),
        parameters: {
          'projectId': access.id,
          'number': number,
          'status': action.to,
        },
      );
      await _refresh(tx, access.id);
      return _details(tx, access.id, number);
    });
    return jsonResponse(details);
  }

  /// The task number in [taskId], if it names a task of this project.
  static int _taskNumber(ProjectAccess access, String taskId) {
    final parsed = parseTaskCode(taskId);
    if (parsed == null || parsed.projectId != access.id) {
      throw ApiError.notFound('No such task');
    }
    return parsed.number;
  }

  static Future<Map<String, dynamic>> _task(
    Session session,
    int projectId,
    int number,
  ) async {
    final rows = await session.execute(
      Sql.named('''
        SELECT number, status, planned_start, planned_end
          FROM tasks WHERE project_id = @projectId AND number = @number'''),
      parameters: {'projectId': projectId, 'number': number},
    );
    if (rows.isEmpty) throw ApiError.notFound('No such task');
    return rows.single.toColumnMap();
  }

  /// Resolves task IDs from a request body to numbers that exist in this
  /// project, or throws a 400 naming the ones that do not.
  static Future<Map<int, String>> _existingTasks(
    Session session,
    ProjectAccess access,
    List<Object?> ids,
  ) async {
    final numbers = <int, String>{};
    final invalid = <Object?>[];
    for (final id in ids) {
      final parsed = id is String ? parseTaskCode(id) : null;
      if (parsed == null || parsed.projectId != access.id) {
        invalid.add(id);
      } else {
        numbers[parsed.number] = id! as String;
      }
    }
    if (numbers.isNotEmpty) {
      final found = await session.execute(
        Sql.named(
          '''
          SELECT number FROM tasks
           WHERE project_id = @projectId AND number = ANY(@numbers::integer[])''',
        ),
        parameters: {'projectId': access.id, 'numbers': numbers.keys.toList()},
      );
      final existing = {for (final row in found) row[0]! as int};
      for (final MapEntry(:key, :value) in numbers.entries) {
        if (!existing.contains(key)) invalid.add(value);
      }
    }
    if (invalid.isNotEmpty) {
      throw ApiError.badRequest(
        'dependsOn must list tasks of this project',
        details: {
          'fields': {'dependsOn': 'unknown tasks: ${invalid.join(', ')}'},
        },
      );
    }
    return numbers;
  }

  static Future<int> _unfinishedUpstream(
    TxSession tx,
    int projectId,
    int number,
  ) async {
    final rows = await tx.execute(
      Sql.named('''
        WITH RECURSIVE upstream (number) AS (
            SELECT depends_on_number FROM task_dependencies
             WHERE project_id = @projectId AND task_number = @number
          UNION
            SELECT d.depends_on_number
              FROM upstream u
              JOIN task_dependencies d
                ON d.project_id = @projectId AND d.task_number = u.number
        )
        SELECT count(*)::int
          FROM upstream u
          JOIN tasks t ON t.project_id = @projectId AND t.number = u.number
         WHERE t.status <> 'done' '''),
      parameters: {'projectId': projectId, 'number': number},
    );
    return rows.single[0]! as int;
  }

  static Future<int> _startedDownstream(
    TxSession tx,
    int projectId,
    int number,
  ) async {
    final rows = await tx.execute(
      Sql.named('''
        WITH RECURSIVE downstream (number) AS (
            SELECT task_number FROM task_dependencies
             WHERE project_id = @projectId AND depends_on_number = @number
          UNION
            SELECT d.task_number
              FROM downstream w
              JOIN task_dependencies d
                ON d.project_id = @projectId AND d.depends_on_number = w.number
        )
        SELECT count(*)::int
          FROM downstream w
          JOIN tasks t ON t.project_id = @projectId AND t.number = w.number
         WHERE t.status <> 'not_started' '''),
      parameters: {'projectId': projectId, 'number': number},
    );
    return rows.single[0]! as int;
  }

  static Future<void> _refresh(TxSession tx, int projectId) => tx.execute(
    Sql.named('SELECT refresh_project_task_stats(@projectId)'),
    parameters: {'projectId': projectId},
  );

  /// Task details: the task, its allowed actions, and its upstream and
  /// downstream tasks with distances.
  static Future<Map<String, Object?>> _details(
    Session session,
    int projectId,
    int number,
  ) async {
    final rows = await _taskRows(
      session,
      projectId,
      number: number,
      order: 'ORDER BY number',
      limit: 1,
      offset: 0,
    );
    if (rows.isEmpty) throw ApiError.notFound('No such task');
    final task = rows.single;

    final edges = await session.execute(
      Sql.named('''
        SELECT task_number, depends_on_number
          FROM task_dependencies WHERE project_id = @projectId'''),
      parameters: {'projectId': projectId},
    );
    final graph = TaskGraph(edges.map((r) => (r[0]! as int, r[1]! as int)));
    final upstream = graph.upstream(number);
    final downstream = graph.downstream(number);

    final related = <int, Map<String, dynamic>>{};
    final numbers = {...upstream.keys, ...downstream.keys}.toList();
    if (numbers.isNotEmpty) {
      final found = await session.execute(
        Sql.named(
          '''
          SELECT number, name, status, planned_start, planned_end, blocked,
                 task_is_late(status, planned_start, planned_end, current_date) AS late
            FROM tasks
           WHERE project_id = @projectId AND number = ANY(@numbers::integer[])''',
        ),
        parameters: {'projectId': projectId, 'numbers': numbers},
      );
      for (final row in found.map((r) => r.toColumnMap())) {
        related[row['number'] as int] = row;
      }
    }

    List<Map<String, Object?>> withDistance(Map<int, int> distances) {
      final entries = distances.entries.toList()
        ..sort(
          (a, b) => a.value != b.value ? a.value - b.value : a.key - b.key,
        );
      return [
        for (final MapEntry(key: n, value: distance) in entries)
          if (related[n] case final row?)
            {
              'id': taskCode(projectId, n),
              'name': row['name'],
              'status': row['status'],
              'plannedStart': formatDate(row['planned_start'] as DateTime),
              'plannedEnd': formatDate(row['planned_end'] as DateTime),
              'late': row['late'],
              'blocked': row['blocked'],
              'distance': distance,
            },
      ];
    }

    final status = task['status'] as String;
    final allowed = <String>[
      if (status == 'not_started' &&
          upstream.keys.every((n) => related[n]?['status'] == 'done'))
        'start',
      if (status == 'in_progress') 'complete',
      if (status == 'done' &&
          downstream.keys.every((n) => related[n]?['status'] == 'not_started'))
        'reopen',
    ];

    return {
      ..._taskJson(projectId, task),
      'allowedActions': allowed,
      'waitsOn': withDistance(upstream),
      'waitedOnBy': withDistance(downstream),
    };
  }

  /// The tasks screen query, also used for single tasks ([number]).
  static Future<List<Map<String, dynamic>>> _taskRows(
    Session session,
    int projectId, {
    int? number,
    List<String>? statuses,
    bool? late,
    bool? blocked,
    DateTime? from,
    DateTime? to,
    String? pattern,
    required String order,
    required int limit,
    required int offset,
  }) async {
    final result = await session.execute(
      Sql.named('''
        WITH dependents AS (
          SELECT depends_on_number AS number, count(*)::int AS n
            FROM task_dependencies
           WHERE project_id = @projectId
           GROUP BY depends_on_number
        ),
        filtered AS (
          SELECT t.number, t.name, t.planned_start, t.planned_end, t.status,
                 t.blocked, t.created_at, t.updated_at,
                 task_is_late(t.status, t.planned_start, t.planned_end, current_date) AS late,
                 coalesce(d.n, 0) AS dependents_count
            FROM tasks t
            LEFT JOIN dependents d ON d.number = t.number
           WHERE t.project_id = @projectId
             AND (@number::integer IS NULL OR t.number = @number::integer)
             AND (@statuses::text[] IS NULL OR t.status = ANY(@statuses::text[]))
             AND (@blocked::boolean IS NULL OR t.blocked = @blocked::boolean)
             AND (@from::date IS NULL OR t.planned_end >= @from::date)
             AND (@to::date IS NULL OR t.planned_start <= @to::date)
             AND (@pattern::text IS NULL
                  OR t.name ILIKE @pattern::text
                  OR task_code(t.project_id, t.number) ILIKE @pattern::text)
        ),
        page AS (
          SELECT f.*, count(*) OVER () AS total,
                 row_number() OVER ($order) AS position
            FROM filtered f
           WHERE @late::boolean IS NULL OR f.late = @late::boolean
           $order
           LIMIT @limit OFFSET @offset
        )
        SELECT p.*,
               coalesce((SELECT array_agg(d.depends_on_number ORDER BY d.depends_on_number)
                           FROM task_dependencies d
                          WHERE d.project_id = @projectId AND d.task_number = p.number),
                        '{}') AS depends_on
          FROM page p
         ORDER BY p.position'''),
      parameters: {
        'projectId': projectId,
        'number': number,
        'statuses': statuses,
        'late': late,
        'blocked': blocked,
        'from': from,
        'to': to,
        'pattern': pattern,
        'limit': limit,
        'offset': offset,
      },
    );
    return result.map((row) => row.toColumnMap()).toList();
  }

  static Map<String, Object?> _taskJson(
    int projectId,
    Map<String, dynamic> row,
  ) => {
    'id': taskCode(projectId, row['number'] as int),
    'number': row['number'],
    'name': row['name'],
    'plannedStart': formatDate(row['planned_start'] as DateTime),
    'plannedEnd': formatDate(row['planned_end'] as DateTime),
    'status': row['status'],
    'late': row['late'],
    'blocked': row['blocked'],
    'dependsOn': [
      for (final n in (row['depends_on'] as List<Object?>).cast<int>())
        taskCode(projectId, n),
    ],
    'dependentsCount': row['dependents_count'],
    'createdAt': formatTimestamp(row['created_at'] as DateTime),
    'updatedAt': formatTimestamp(row['updated_at'] as DateTime),
  };
}

enum _Action {
  start(
    'not_started',
    'in_progress',
    'Only a task that has not started can be started',
  ),
  complete(
    'in_progress',
    'done',
    'Only a task in progress can be marked as done',
  ),
  reopen('done', 'in_progress', 'Only a done task can be reopened');

  const _Action(this.from, this.to, this.wrongState);

  final String from;
  final String to;
  final String wrongState;
}
