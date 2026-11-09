import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  final api = useTestApi();

  late TestUser owner;
  late String project;

  Future<String> newProject(TestUser user) async {
    final response = await api().post(
      '/v1/projects',
      body: {
        'name': 'Tasks',
        'plannedStart': '2026-01-01',
        'plannedEnd': '2026-12-31',
      },
      as: user,
    );
    return response.body['id']! as String;
  }

  /// Creates a task in [project] and returns its ID.
  Future<String> task(
    String name, {
    List<String> dependsOn = const [],
    String start = '2099-01-01',
    String end = '2099-02-01',
    String? inProject,
  }) async {
    final response = await api().post(
      '/v1/projects/${inProject ?? project}/tasks',
      body: {
        'name': name,
        'plannedStart': start,
        'plannedEnd': end,
        'dependsOn': dependsOn,
      },
      as: owner,
    );
    expect(response.status, 201, reason: '$response');
    return response.body['id']! as String;
  }

  String path(String taskId, [String suffix = '']) =>
      '/v1/projects/$project/tasks/$taskId$suffix';

  Future<ApiResponse> act(String taskId, String action) =>
      api().post(path(taskId, '/$action'), as: owner);

  Future<Map<String, Object?>> details(String taskId) async =>
      (await api().get(path(taskId), as: owner)).body;

  setUp(() async {
    owner = await api().user();
    project = await newProject(owner);
  });

  group('IDs', () {
    test(
      'count up within each project, uniquely under load, never reused',
      () async {
        final first = await task('First');
        expect(first, '$project-T-0001');
        final other = await newProject(owner);
        expect(await task('Elsewhere', inProject: other), '$other-T-0001');

        final created = await Future.wait([
          for (var i = 0; i < 20; i++) task('Parallel $i'),
        ]);
        expect(created.toSet(), hasLength(20));
        final numbers =
            created.map((id) => int.parse(id.split('-T-').last)).toList()
              ..sort();
        expect(numbers, [for (var n = 2; n <= 21; n++) n]);

        expect((await api().delete(path(created.last), as: owner)).status, 204);
        expect(await task('After delete'), '$project-T-0022');
      },
    );

    test('a task ID from another project is not found in this one', () async {
      final other = await newProject(owner);
      final foreign = await task('Foreign', inProject: other);
      expect((await api().get(path(foreign), as: owner)).status, 404);
      expect((await api().get(path('$project-T-9999'), as: owner)).status, 404);
      expect((await api().get(path('nonsense'), as: owner)).status, 404);
    });

    test('non-members cannot see or change tasks', () async {
      final a = await task('Private');
      final outsider = await api().user();
      for (final response in [
        await api().get('/v1/projects/$project/tasks', as: outsider),
        await api().get(path(a), as: outsider),
        await api().post(path(a, '/start'), as: outsider),
        await api().post(
          '/v1/projects/$project/tasks',
          body: {
            'name': 'x',
            'plannedStart': '2026-01-01',
            'plannedEnd': '2026-01-02',
          },
          as: outsider,
        ),
      ]) {
        expect(response.status, 404);
      }
    });
  });

  group('dependencies', () {
    test(
      'chains and side-by-side waits are both followed, with distances',
      () async {
        final a = await task('A');
        final b = await task('B', dependsOn: [a]);
        final c = await task('C', dependsOn: [b]);
        final d = await task('D', dependsOn: [a, c]);

        final dDetails = await details(d);
        expect(dDetails['dependsOn'], [a, c]);
        expect((dDetails['waitsOn']! as List).map(_idAndDistance), [
          [a, 1],
          [c, 1],
          [b, 2],
        ]);
        final aDetails = await details(a);
        expect(aDetails['dependentsCount'], 2);
        expect((aDetails['waitedOnBy']! as List).map(_idAndDistance), [
          [b, 1],
          [d, 1],
          [c, 2],
        ]);
      },
    );

    test('loops are refused, directly, indirectly and onto itself', () async {
      final a = await task('A');
      final b = await task('B', dependsOn: [a]);
      final c = await task('C', dependsOn: [b]);
      for (final (from, to) in [(a, b), (a, c), (a, a)]) {
        final response = await api().put(
          path(from, '/dependencies/$to'),
          as: owner,
        );
        expect(response.status, 409, reason: '$from -> $to');
        expect(response.errorCode, 'dependency_cycle');
      }
    });

    test(
      'two requests closing a loop at the same moment: one is refused',
      () async {
        final a = await task('A');
        final b = await task('B');
        final results = await Future.wait([
          api().put(path(a, '/dependencies/$b'), as: owner),
          api().put(path(b, '/dependencies/$a'), as: owner),
        ]);
        expect(results.map((r) => r.status).toList()..sort(), [201, 409]);
      },
    );

    test('dependencies stay inside one project', () async {
      final a = await task('A');
      final other = await newProject(owner);
      final foreign = await task('Foreign', inProject: other);
      final response = await api().put(
        path(a, '/dependencies/$foreign'),
        as: owner,
      );
      expect(response.status, 400);
      final create = await api().post(
        '/v1/projects/$project/tasks',
        body: {
          'name': 'Mixed',
          'plannedStart': '2026-01-01',
          'plannedEnd': '2026-01-02',
          'dependsOn': [foreign],
        },
        as: owner,
      );
      expect(create.status, 400);
    });

    test('adding is idempotent and removing works', () async {
      final a = await task('A');
      final b = await task('B');
      expect(
        (await api().put(path(b, '/dependencies/$a'), as: owner)).status,
        201,
      );
      expect(
        (await api().put(path(b, '/dependencies/$a'), as: owner)).status,
        200,
      );
      expect((await details(b))['blocked'], isTrue);
      expect(
        (await api().delete(path(b, '/dependencies/$a'), as: owner)).status,
        204,
      );
      expect((await details(b))['blocked'], isFalse);
      expect(
        (await api().delete(path(b, '/dependencies/$a'), as: owner)).status,
        404,
      );
    });

    test('a started task only gains dependencies on done tasks', () async {
      final a = await task('A');
      final b = await task('B');
      await act(b, 'start');
      final response = await api().put(path(b, '/dependencies/$a'), as: owner);
      expect(response.errorCode, 'task_already_started');
      await act(a, 'start');
      await act(a, 'complete');
      expect(
        (await api().put(path(b, '/dependencies/$a'), as: owner)).status,
        201,
      );
    });

    test('a task others depend on cannot be removed', () async {
      final a = await task('A');
      final b = await task('B', dependsOn: [a]);
      final response = await api().delete(path(a), as: owner);
      expect(response.errorCode, 'task_has_dependents');
      expect((response.body['error']! as Map)['details'], {
        'dependents': [b],
      });
      expect((await api().delete(path(b), as: owner)).status, 204);
      expect((await api().delete(path(a), as: owner)).status, 204);
    });
  });

  group('status', () {
    test('start waits for everything upstream, directly or not', () async {
      final a = await task('A');
      final b = await task('B', dependsOn: [a]);
      final c = await task('C', dependsOn: [b]);

      expect((await details(c))['allowedActions'], isEmpty);
      expect((await act(c, 'start')).errorCode, 'task_blocked');
      expect((await details(a))['allowedActions'], ['start']);

      await act(a, 'start');
      await act(a, 'complete');
      // B is free now; C still waits on B, so it stays blocked.
      expect((await details(b))['blocked'], isFalse);
      expect((await details(c))['blocked'], isTrue);
      expect((await act(c, 'start')).errorCode, 'task_blocked');

      await act(b, 'start');
      expect((await details(b))['allowedActions'], ['complete']);
      await act(b, 'complete');
      final started = await act(c, 'start');
      expect(started.status, 200);
      expect(started.body['status'], 'in_progress');
    });

    test('reopen only while nothing waiting on the task has started', () async {
      final a = await task('A');
      final b = await task('B', dependsOn: [a]);
      final c = await task('C', dependsOn: [b]);
      await act(a, 'start');
      await act(a, 'complete');
      expect((await details(a))['allowedActions'], ['reopen']);
      await act(b, 'start');
      await act(b, 'complete');
      await act(c, 'start');

      // C (two steps away) has started.
      expect((await details(a))['allowedActions'], isEmpty);
      expect((await act(a, 'reopen')).errorCode, 'dependents_started');
      expect((await act(b, 'reopen')).errorCode, 'dependents_started');

      final d = await task('D');
      await act(d, 'start');
      await act(d, 'complete');
      final reopened = await act(d, 'reopen');
      expect(reopened.status, 200);
      expect(reopened.body['status'], 'in_progress');
    });

    test('every other status change is refused', () async {
      final a = await task('A');
      expect((await act(a, 'complete')).errorCode, 'invalid_transition');
      expect((await act(a, 'reopen')).errorCode, 'invalid_transition');
      await act(a, 'start');
      expect((await act(a, 'start')).errorCode, 'invalid_transition');
      expect((await act(a, 'reopen')).errorCode, 'invalid_transition');
      await act(a, 'complete');
      expect((await act(a, 'complete')).errorCode, 'invalid_transition');
      expect((await act(a, 'start')).errorCode, 'invalid_transition');
      final patch = await api().patch(
        path(a),
        body: {'status': 'not_started'},
        as: owner,
      );
      expect(patch.status, 400);
    });

    test(
      'Late follows the dates, Blocked follows the graph, both can hold',
      () async {
        final past = await task(
          'Past start',
          start: '2020-01-01',
          end: '2099-01-01',
        );
        final overdue = await task(
          'Overdue',
          start: '2020-01-01',
          end: '2020-02-01',
        );
        final future = await task('Future', dependsOn: [past]);
        final both = await task(
          'Late and blocked',
          start: '2020-03-01',
          end: '2020-04-01',
          dependsOn: [overdue],
        );

        expect(
          (await details(past))['late'],
          isTrue,
        ); // not started, start passed
        expect((await details(future))['late'], isFalse);
        expect((await details(both))['late'], isTrue);
        expect((await details(both))['blocked'], isTrue);

        await act(past, 'start'); // in progress, end not passed
        expect((await details(past))['late'], isFalse);
        await act(overdue, 'start'); // in progress, end passed
        expect((await details(overdue))['late'], isTrue);
        await act(overdue, 'complete');
        expect((await details(overdue))['late'], isFalse);
        expect((await details(both))['blocked'], isFalse);

        final listed = (await api().get(
          '/v1/projects/$project',
          as: owner,
        )).body;
        expect(listed['taskCounts'], {
          'notStarted': 2,
          'inProgress': 1,
          'done': 1,
          'total': 4,
        });
        expect(listed['percentDone'], 25);
        expect(
          listed['lateTasks'],
          1,
        ); // "Late and blocked"; Past start is in progress
        expect(listed['blockedTasks'], 1); // Future waits on Past start

        final onlyLate = await api().get(
          '/v1/projects?hasLateTasks=true',
          as: owner,
        );
        expect(onlyLate.items.map((p) => (p! as Map)['id']), [project]);
      },
    );
  });

  group('tasks screen', () {
    test('filters, search and sorts', () async {
      final a = await task('Excavate', start: '2026-03-01', end: '2026-03-10');
      final b = await task(
        'Pour slab',
        dependsOn: [a],
        start: '2026-03-11',
        end: '2026-03-20',
      );
      final c = await task(
        'Erect steel',
        dependsOn: [a],
        start: '2026-04-01',
        end: '2026-04-30',
      );
      await act(a, 'start');

      Future<List<Object?>> ids(String query) async {
        final response = await api().get(
          '/v1/projects/$project/tasks?$query',
          as: owner,
        );
        expect(response.status, 200, reason: '$response');
        return response.items.map((t) => (t! as Map)['id']).toList();
      }

      expect(await ids('status=in_progress'), [a]);
      expect(await ids('status=not_started,in_progress'), [a, b, c]);
      expect(await ids('blocked=true'), [b, c]);
      expect(await ids('blocked=false'), [a]);
      expect(await ids('from=2026-03-15&to=2026-03-31'), [b]);
      expect(await ids('search=slab'), [b]);
      expect(await ids('search=T-0003'), [c]);
      expect(await ids('sort=-dependents'), [a, b, c]);
      expect(await ids('sort=name'), [c, a, b]);
      expect(await ids('sort=-endDate&limit=1'), [c]);
      expect(await ids('late=true'), isNotEmpty); // all 2026 dates are past

      final page = await api().get(
        '/v1/projects/$project/tasks?limit=2&offset=2',
        as: owner,
      );
      expect(page.body['total'], 3);
      expect(page.items, hasLength(1));

      final first = page.items.single! as Map;
      expect(first['dependsOn'], [a]);
      expect(first['dependentsCount'], 0);
      expect(
        (await api().get(
          '/v1/projects/$project/tasks?status=bogus',
          as: owner,
        )).status,
        400,
      );
    });
  });
}

List<Object?> _idAndDistance(Object? task) {
  final map = task! as Map;
  return [map['id'], map['distance']];
}
