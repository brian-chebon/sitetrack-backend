import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

import '../auth/caller.dart';
import '../db/database.dart';
import '../http/api_error.dart';
import '../http/json.dart';
import '../http/sql.dart';
import '../http/validation.dart';
import '../ids.dart';
import 'project_access.dart';

/// The projects screen and project create / edit / remove.
class ProjectRoutes {
  ProjectRoutes(this._db);

  final Database _db;

  static const _sorts = {
    'name': 'lower(name)',
    'startDate': 'planned_start',
    'percentDone': 'done_ratio',
    'lateTasks': 'late_tasks',
  };

  /// `GET /v1/projects`: every project the caller can access, with its task
  /// counts, percentage done, late and blocked counts.
  ///
  /// Filters: `search` (name or ID), `hasLateTasks=true`. Sort: `name`,
  /// `startDate`, `percentDone`, `lateTasks`, `-` prefix for descending.
  Future<Response> list(Request request) async {
    final caller = callerOf(request);
    final query = QueryReader(request.url.queryParameters);
    final search = query.search();
    final onlyLate = query.boolean('hasLateTasks') ?? false;
    final sort = query.sort(_sorts, fallback: _sorts['name']!);
    final page = query.page();
    query.throwIfInvalid();

    final rows = await _projectRows(
      _db.pool,
      caller,
      pattern: containsPattern(search),
      onlyLate: onlyLate,
      order: orderBy(sort.key, descending: sort.descending, tieBreaker: 'id'),
      limit: page.limit,
      offset: page.offset,
    );
    return jsonResponse(
      pageJson(
        rows.map(projectJson).toList(),
        total: rows.isEmpty ? 0 : rows.first['total'] as int,
        limit: page.limit,
        offset: page.offset,
      ),
    );
  }

  /// `GET /v1/projects/{projectId}`
  Future<Response> get(Request request, String projectId) async {
    final caller = callerOf(request);
    final access = await loadProject(_db.pool, caller, projectId);
    return jsonResponse(await _one(_db.pool, caller, access.id));
  }

  /// `POST /v1/projects` with name, plannedStart, plannedEnd. The creator
  /// becomes the project's first admin.
  Future<Response> create(Request request) async {
    final caller = callerOf(request);
    final body = BodyReader(await readJsonObject(request));
    final name = body.string('name');
    final start = body.date('plannedStart');
    final end = body.date('plannedEnd');
    if (body.has('plannedStart') &&
        body.has('plannedEnd') &&
        end.isBefore(start)) {
      body.error('plannedEnd', 'must not be before plannedStart');
    }
    body.throwIfInvalid();

    final project = await _db.transaction((tx) async {
      // The counter row is locked until commit, so simultaneous creates queue
      // here for a moment and each gets the next number.
      final counter = await tx.execute(
        "UPDATE counters SET value = value + 1 WHERE name = 'project' RETURNING value",
      );
      final id = counter.single[0]! as int;
      await tx.execute(
        Sql.named('''
          INSERT INTO projects (id, name, planned_start, planned_end, created_by)
          VALUES (@id, @name, @start:date, @end:date, @userId)'''),
        parameters: {
          'id': id,
          'name': name,
          'start': start,
          'end': end,
          'userId': caller.id,
        },
      );
      await tx.execute(
        Sql.named('''
          INSERT INTO project_members (project_id, user_id, is_admin)
          VALUES (@id, @userId, true)'''),
        parameters: {'id': id, 'userId': caller.id},
      );
      await tx.execute(
        Sql.named('SELECT refresh_project_member_count(@id)'),
        parameters: {'id': id},
      );
      return _one(tx, caller, id);
    });
    return jsonResponse(project, status: 201);
  }

  /// `PATCH /v1/projects/{projectId}` with any of name, plannedStart,
  /// plannedEnd. Project admins only.
  Future<Response> update(Request request, String projectId) async {
    final caller = callerOf(request);
    final body = BodyReader(await readJsonObject(request));
    final name = body.optionalString('name');
    final start = body.optionalDate('plannedStart');
    final end = body.optionalDate('plannedEnd');
    body.throwIfInvalid();

    final project = await _db.transaction((tx) async {
      final access = await loadProject(
        tx,
        caller,
        projectId,
        lock: ProjectLock.update,
      );
      access.requireAdmin();
      final current = (await tx.execute(
        Sql.named(
          'SELECT planned_start, planned_end FROM projects WHERE id = @id',
        ),
        parameters: {'id': access.id},
      )).single.toColumnMap();
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
          UPDATE projects
             SET name = coalesce(@name, name),
                 planned_start = @start:date,
                 planned_end = @end:date,
                 updated_at = now()
           WHERE id = @id'''),
        parameters: {
          'id': access.id,
          'name': name,
          'start': newStart,
          'end': newEnd,
        },
      );
      return _one(tx, caller, access.id);
    });
    return jsonResponse(project);
  }

  /// `DELETE /v1/projects/{projectId}`. Project admins only.
  ///
  /// Refused while the project store holds stock or a delivery is in transit:
  /// material only ever leaves a store by delivery, so it must be sent back
  /// first. The project then disappears for everyone; its number is never
  /// reused and the company store's delivery history keeps pointing at it.
  Future<Response> remove(Request request, String projectId) async {
    final caller = callerOf(request);
    await _db.transaction((tx) async {
      final access = await loadProject(
        tx,
        caller,
        projectId,
        lock: ProjectLock.delete,
      );
      access.requireAdmin();
      final state = (await tx.execute(
        Sql.named(
          '''
          SELECT EXISTS (SELECT 1 FROM project_stock
                          WHERE project_id = @id AND quantity > 0) AS has_stock,
                 EXISTS (SELECT 1 FROM deliveries
                          WHERE project_id = @id AND status = 'in_transit') AS in_transit''',
        ),
        parameters: {'id': access.id},
      )).single.toColumnMap();
      if (state['in_transit'] as bool) {
        throw ApiError.conflict(
          'deliveries_in_transit',
          'Deliveries to or from this project are in transit; '
              'record, reject or cancel them first',
        );
      }
      if (state['has_stock'] as bool) {
        throw ApiError.conflict(
          'project_store_not_empty',
          'The project store still holds material; send it back to the '
              'company store first',
        );
      }
      await tx.execute(
        Sql.named('UPDATE projects SET deleted_at = now() WHERE id = @id'),
        parameters: {'id': access.id},
      );
      await tx.execute(
        Sql.named('''
          UPDATE project_invitations
             SET status = 'withdrawn', closed_at = now(), closed_by = @userId
           WHERE project_id = @id AND status = 'pending' '''),
        parameters: {'id': access.id, 'userId': caller.id},
      );
    });
    return Response(204);
  }

  Future<Map<String, Object?>> _one(
    Session session,
    Caller caller,
    int id,
  ) async {
    final rows = await _projectRows(
      session,
      caller,
      id: id,
      order: 'ORDER BY id',
      limit: 1,
      offset: 0,
    );
    if (rows.isEmpty) throw projectNotFound();
    return projectJson(rows.single);
  }

  /// The projects screen query. Visibility is the first condition, so every
  /// count, search and sort runs over visible projects only.
  ///
  /// Task counts and Blocked come from counters on the project row. Late
  /// depends on today's date, so it is counted here from the two partial
  /// indexes on unfinished tasks: a task not started is late once its start
  /// date has passed, a task in progress once its end date has.
  static Future<List<Map<String, dynamic>>> _projectRows(
    Session session,
    Caller caller, {
    int? id,
    String? pattern,
    bool onlyLate = false,
    required String order,
    required int limit,
    required int offset,
  }) async {
    final result = await session.execute(
      Sql.named('''
        WITH visible AS (
          SELECT p.*, m.user_id IS NOT NULL AS is_member,
                 coalesce(m.is_admin, false) AS is_admin
            FROM projects p
            LEFT JOIN project_members m ON m.project_id = p.id AND m.user_id = @userId
           WHERE p.deleted_at IS NULL
             AND (m.user_id IS NOT NULL OR @superAdmin::boolean)
             AND (@id::integer IS NULL OR p.id = @id::integer)
             AND (@pattern::text IS NULL
                  OR p.name ILIKE @pattern::text
                  OR project_code(p.id) ILIKE @pattern::text)
        ),
        late AS (
          SELECT project_id, count(*)::int AS n
            FROM (SELECT t.project_id FROM tasks t
                   WHERE t.status = 'not_started' AND t.planned_start < current_date
                     AND t.project_id IN (SELECT id FROM visible)
                  UNION ALL
                  SELECT t.project_id FROM tasks t
                   WHERE t.status = 'in_progress' AND t.planned_end < current_date
                     AND t.project_id IN (SELECT id FROM visible)) unfinished
           GROUP BY project_id
        ),
        listed AS (
          SELECT v.*, coalesce(l.n, 0) AS late_tasks,
                 CASE WHEN v.tasks_not_started + v.tasks_in_progress + v.tasks_done = 0 THEN 0
                      ELSE v.tasks_done::numeric
                           / (v.tasks_not_started + v.tasks_in_progress + v.tasks_done)
                 END AS done_ratio
            FROM visible v
            LEFT JOIN late l ON l.project_id = v.id
           WHERE NOT @onlyLate::boolean OR l.n > 0
        )
        SELECT *, count(*) OVER () AS total
          FROM listed
          $order
         LIMIT @limit OFFSET @offset'''),
      parameters: {
        'userId': caller.id,
        'superAdmin': caller.isSuperAdmin,
        'id': id,
        'pattern': pattern,
        'onlyLate': onlyLate,
        'limit': limit,
        'offset': offset,
      },
    );
    return result.map((row) => row.toColumnMap()).toList();
  }
}

/// A project as the projects screen shows it.
Map<String, Object?> projectJson(Map<String, dynamic> row) {
  final notStarted = row['tasks_not_started'] as int;
  final inProgress = row['tasks_in_progress'] as int;
  final done = row['tasks_done'] as int;
  final total = notStarted + inProgress + done;
  return {
    'id': projectCode(row['id'] as int),
    'name': row['name'],
    'plannedStart': formatDate(row['planned_start'] as DateTime),
    'plannedEnd': formatDate(row['planned_end'] as DateTime),
    'isMember': row['is_member'],
    'isAdmin': row['is_admin'],
    'memberCount': row['member_count'],
    'taskCounts': {
      'notStarted': notStarted,
      'inProgress': inProgress,
      'done': done,
      'total': total,
    },
    'percentDone': total == 0 ? 0 : (done * 1000 / total).round() / 10,
    'lateTasks': row['late_tasks'],
    'blockedTasks': row['tasks_blocked'],
    'createdAt': formatTimestamp(row['created_at'] as DateTime),
    'updatedAt': formatTimestamp(row['updated_at'] as DateTime),
  };
}
