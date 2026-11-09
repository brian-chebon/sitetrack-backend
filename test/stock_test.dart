import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  final api = useTestApi();

  late TestUser manager;
  late TestUser admin;
  late TestUser member;
  late String project;

  Future<int> material(
    String name, {
    String unit = 'bag',
    String category = 'Cement',
  }) async {
    final response = await api().post(
      '/v1/materials',
      body: {'name': name, 'category': category, 'unit': unit},
      as: manager,
    );
    expect(response.status, 201, reason: '$response');
    return response.body['id']! as int;
  }

  Future<void> addStock(Map<int, num> quantities) async {
    final response = await api().post(
      '/v1/company-store/stock-additions',
      body: {
        'lines': [
          for (final MapEntry(:key, :value) in quantities.entries)
            {'materialId': key, 'quantity': value},
        ],
      },
      as: manager,
    );
    expect(response.status, 201, reason: '$response');
  }

  Future<Map<String, Object?>> companyStock(int materialId) async {
    final response = await api().get(
      '/v1/company-store/stock?limit=200',
      as: manager,
    );
    return response.items.cast<Map<String, Object?>>().firstWhere(
      (item) => item['materialId'] == materialId,
    );
  }

  Future<num> projectQuantity(int materialId, {String? inProject}) async {
    final response = await api().get(
      '/v1/projects/${inProject ?? project}/store?limit=200',
      as: member,
    );
    final items = response.items.cast<Map<String, Object?>>();
    final item = items.where((i) => i['materialId'] == materialId).firstOrNull;
    return (item?['quantity'] as num?) ?? 0;
  }

  Future<ApiResponse> sendToProject(Map<int, num> lines, {String? to}) =>
      api().post(
        '/v1/company-store/deliveries',
        body: {
          'projectId': to ?? project,
          'lines': [
            for (final MapEntry(:key, :value) in lines.entries)
              {'materialId': key, 'quantity': value},
          ],
        },
        as: manager,
      );

  Future<ApiResponse> sendBack(Map<int, num> lines) => api().post(
    '/v1/projects/$project/deliveries',
    body: {
      'lines': [
        for (final MapEntry(:key, :value) in lines.entries)
          {'materialId': key, 'quantity': value},
      ],
    },
    as: member,
  );

  Future<ApiResponse> projectAction(
    Object deliveryId,
    String action, {
    TestUser? as,
  }) => api().post(
    '/v1/projects/$project/deliveries/$deliveryId/$action',
    as: as ?? member,
  );

  Future<ApiResponse> companyAction(Object deliveryId, String action) => api()
      .post('/v1/company-store/deliveries/$deliveryId/$action', as: manager);

  setUp(() async {
    manager = await api().user(role: 'store_manager');
    admin = await api().user();
    member = await api().user();
    final created = await api().post(
      '/v1/projects',
      body: {
        'name': 'Stock site',
        'plannedStart': '2026-01-01',
        'plannedEnd': '2026-12-31',
      },
      as: admin,
    );
    project = created.body['id']! as String;
    final invite = await api().post(
      '/v1/projects/$project/invitations',
      body: {'email': member.email},
      as: admin,
    );
    await api().post('/v1/invitations/${invite.body['id']}/accept', as: member);
  });

  var counter = 0;
  String unique(String name) => '$name ${++counter}';

  group('catalogue', () {
    test('everyone reads it; only store staff change it', () async {
      final id = await material(unique('Cement, OPC 50 kg bag'));
      expect((await api().get('/v1/materials/$id', as: member)).status, 200);
      final byUser = await api().post(
        '/v1/materials',
        body: {'name': 'Sand', 'category': 'Aggregates', 'unit': 'm3'},
        as: member,
      );
      expect(byUser.status, 403);
      final categories = await api().get(
        '/v1/materials/categories',
        as: member,
      );
      expect(
        (categories.body['items']! as List).map((c) => (c! as Map)['name']),
        contains('Cement'),
      );
    });

    test('names are unique, and the unit is fixed once stock exists', () async {
      final name = unique('Rebar Y12');
      final id = await material(name, unit: 'piece');
      final duplicate = await api().post(
        '/v1/materials',
        body: {
          'name': name.toUpperCase(),
          'category': 'Steel',
          'unit': 'piece',
        },
        as: manager,
      );
      expect(duplicate.errorCode, 'material_exists');
      expect(
        (await api().patch(
          '/v1/materials/$id',
          body: {'unit': 'bundle'},
          as: manager,
        )).status,
        200,
      );
      await addStock({id: 5});
      final change = await api().patch(
        '/v1/materials/$id',
        body: {'unit': 'kg'},
        as: manager,
      );
      expect(change.errorCode, 'unit_in_use');
      expect(
        (await api().delete('/v1/materials/$id', as: manager)).errorCode,
        'material_in_use',
      );
    });
  });

  group('company store', () {
    test('is closed to users who are not store staff', () async {
      for (final path in [
        '/v1/company-store/stock',
        '/v1/company-store/deliveries',
        '/v1/company-store/projects',
      ]) {
        expect((await api().get(path, as: member)).status, 403, reason: path);
      }
      final send = await api().post(
        '/v1/company-store/stock-additions',
        body: {
          'lines': [
            {'materialId': 1, 'quantity': 1},
          ],
        },
        as: admin,
      );
      expect(send.status, 403);
    });

    test('stock status follows quantity and reorder point', () async {
      final id = await material(unique('Tile adhesive'));
      expect((await companyStock(id))['status'], 'out_of_stock');
      await api().patch(
        '/v1/company-store/stock/$id',
        body: {'reorderPoint': 10},
        as: manager,
      );
      await addStock({id: 10});
      expect((await companyStock(id))['status'], 'low_stock');
      await addStock({id: 0.5});
      final stock = await companyStock(id);
      expect(stock['status'], 'available');
      expect(stock['quantity'], 10.5);

      final low = await api().get(
        '/v1/company-store/stock?status=available&search=Tile',
        as: manager,
      );
      expect(low.items.map((i) => (i! as Map)['materialId']), contains(id));
    });

    test('adding stock is all or nothing', () async {
      final id = await material(unique('Gravel'));
      final response = await api().post(
        '/v1/company-store/stock-additions',
        body: {
          'lines': [
            {'materialId': id, 'quantity': 5},
            {'materialId': 999999, 'quantity': 5},
          ],
        },
        as: manager,
      );
      expect(response.status, 400);
      expect((await companyStock(id))['quantity'], 0);
    });
  });

  group('deliveries', () {
    test('a round trip: out to the project and back', () async {
      final id = await material(unique('Cement'));
      await addStock({id: 100});

      final sent = await sendToProject({id: 30});
      expect(sent.status, 201);
      expect(sent.body['status'], 'in_transit');
      expect(sent.body['actions'], ['cancel']);
      var stock = await companyStock(id);
      expect(stock['quantity'], 70);
      expect(stock['inTransitToProjects'], 30);
      expect(await projectQuantity(id), 0);

      final incoming = await api().get(
        '/v1/projects/$project/deliveries',
        as: member,
      );
      final listed = incoming.items.single! as Map;
      expect(listed['flow'], 'incoming');
      expect(listed['actions'], ['record', 'reject']);

      final recorded = await projectAction(sent.body['id']!, 'record');
      expect(recorded.status, 200, reason: '$recorded');
      expect(recorded.body['status'], 'delivered');
      expect((recorded.body['receivedBy']! as Map)['id'], member.id);
      stock = await companyStock(id);
      expect(stock['quantity'], 70);
      expect(stock['inTransitToProjects'], 0);
      expect(await projectQuantity(id), 30);

      final back = await sendBack({id: 12.5});
      expect(back.status, 201, reason: '$back');
      expect(await projectQuantity(id), 17.5);
      expect((await companyAction(back.body['id']!, 'record')).status, 200);
      expect((await companyStock(id))['quantity'], 82.5);
    });

    test('rejected and cancelled deliveries return to the sender', () async {
      final id = await material(unique('Sand'));
      await addStock({id: 50});

      final rejected = await sendToProject({id: 10});
      expect(
        (await projectAction(rejected.body['id']!, 'reject')).body['status'],
        'rejected',
      );
      final cancelled = await sendToProject({id: 10});
      expect(
        (await companyAction(cancelled.body['id']!, 'cancel')).body['status'],
        'cancelled',
      );
      var stock = await companyStock(id);
      expect(stock['quantity'], 50);
      expect(stock['inTransitToProjects'], 0);

      final delivered = await sendToProject({id: 20});
      await projectAction(delivered.body['id']!, 'record');
      final returnRejected = await sendBack({id: 5});
      await companyAction(returnRejected.body['id']!, 'reject');
      final returnCancelled = await sendBack({id: 5});
      await projectAction(returnCancelled.body['id']!, 'cancel');
      expect(await projectQuantity(id), 20);
      stock = await companyStock(id);
      expect(stock['quantity'], 30);
    });

    test(
      'only the receiver records or rejects; only the sender cancels',
      () async {
        final id = await material(unique('Lime'));
        await addStock({id: 10});
        final out = await sendToProject({id: 1});
        expect(
          (await projectAction(out.body['id']!, 'cancel')).errorCode,
          'not_sender',
        );
        expect(
          (await companyAction(out.body['id']!, 'record')).errorCode,
          'not_receiver',
        );
        await projectAction(out.body['id']!, 'record');
        expect(
          (await projectAction(out.body['id']!, 'reject')).errorCode,
          'delivery_closed',
        );

        final back = await sendBack({id: 1});
        expect(
          (await companyAction(back.body['id']!, 'cancel')).errorCode,
          'not_sender',
        );
        expect(
          (await projectAction(back.body['id']!, 'record')).errorCode,
          'not_receiver',
        );
      },
    );

    test('a store cannot send more than it holds, and nothing moves', () async {
      final a = await material(unique('Bricks'));
      final b = await material(unique('Blocks'));
      await addStock({a: 10, b: 1});
      final response = await sendToProject({a: 5, b: 2});
      expect(response.errorCode, 'insufficient_stock');
      expect((response.body['error']! as Map)['details'], {
        'shortages': [
          {'materialId': b, 'requested': 2, 'available': 1},
        ],
      });
      expect((await companyStock(a))['quantity'], 10);
      expect((await sendBack({a: 1})).errorCode, 'insufficient_stock');
    });

    test('parallel deliveries never take a store below zero', () async {
      final id = await material(unique('Steel mesh'));
      await addStock({id: 10});
      final results = await Future.wait([
        for (var i = 0; i < 25; i++) sendToProject({id: 1}),
      ]);
      expect(results.where((r) => r.status == 201), hasLength(10));
      expect(
        results.where((r) => r.status != 201).map((r) => r.errorCode).toSet(),
        {'insufficient_stock'},
      );
      final stock = await companyStock(id);
      expect(stock['quantity'], 0);
      expect(stock['inTransitToProjects'], 10);
    });

    test('record racing cancel on one delivery: exactly one wins', () async {
      final id = await material(unique('Plywood'));
      await addStock({id: 10});
      for (var round = 0; round < 5; round++) {
        final sent = await sendToProject({id: 1});
        final results = await Future.wait([
          projectAction(sent.body['id']!, 'record'),
          companyAction(sent.body['id']!, 'cancel'),
        ]);
        expect(results.where((r) => r.status == 200), hasLength(1));
        expect(results.where((r) => r.status == 409), hasLength(1));
      }
      final stock = await companyStock(id);
      final atProject = await projectQuantity(id);
      expect(stock['inTransitToProjects'], 0);
      expect((stock['quantity']! as num) + atProject, 10);
    });

    test('overlapping multi-line deliveries do not deadlock', () async {
      final a = await material(unique('Paint A'));
      final b = await material(unique('Paint B'));
      final c = await material(unique('Paint C'));
      await addStock({a: 100, b: 100, c: 100});
      final results = await Future.wait([
        for (var i = 0; i < 12; i++)
          sendToProject(i.isEven ? {a: 1, b: 1, c: 1} : {c: 1, b: 1, a: 1}),
      ]);
      expect(results.map((r) => r.status).toSet(), {201});
      expect((await companyStock(b))['quantity'], 88);
    });

    test('outsiders cannot see or touch a project store', () async {
      final id = await material(unique('Nails'));
      await addStock({id: 5});
      final sent = await sendToProject({id: 1});
      final outsider = await api().user();
      for (final response in [
        await api().get('/v1/projects/$project/store', as: outsider),
        await api().get('/v1/projects/$project/deliveries', as: outsider),
        await api().get(
          '/v1/projects/$project/deliveries/${sent.body['id']}',
          as: outsider,
        ),
        await projectAction(sent.body['id']!, 'record', as: outsider),
      ]) {
        expect(response.status, 404);
      }
      // A delivery of another project is not found under this one.
      final other = await api().post(
        '/v1/projects',
        body: {
          'name': 'Other',
          'plannedStart': '2026-01-01',
          'plannedEnd': '2026-12-31',
        },
        as: member,
      );
      final otherId = other.body['id']! as String;
      final elsewhere = await api().post(
        '/v1/projects/$otherId/deliveries/${sent.body['id']}/record',
        as: member,
      );
      expect(elsewhere.status, 404);
    });

    test(
      'lists filter by direction, status and date and page by cursor',
      () async {
        final id = await material(unique('Cable'));
        await addStock({id: 100});
        final ids = <Object?>[];
        for (var i = 0; i < 5; i++) {
          ids.add((await sendToProject({id: 1})).body['id']);
        }
        await projectAction(ids.first!, 'record');
        final back = await sendBack({id: 1});

        final outgoing = await api().get(
          '/v1/projects/$project/deliveries?direction=outgoing',
          as: member,
        );
        expect(outgoing.items.map((d) => (d! as Map)['id']), [back.body['id']]);
        final inTransit = await api().get(
          '/v1/projects/$project/deliveries?direction=incoming&status=in_transit',
          as: member,
        );
        expect(inTransit.body['total'], 4);
        final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
        final dated = await api().get(
          '/v1/projects/$project/deliveries?from=$today&to=$today',
          as: member,
        );
        expect(dated.body['total'], 6);
        final none = await api().get(
          '/v1/projects/$project/deliveries?to=2020-01-01',
          as: member,
        );
        expect(none.body['total'], 0);

        final seen = <Object?>[];
        String? cursor;
        do {
          final page = await api().get(
            '/v1/company-store/deliveries?projectId=$project&limit=2'
            '${cursor == null ? '' : '&cursor=$cursor'}',
            as: manager,
          );
          expect(page.status, 200, reason: '$page');
          seen.addAll(page.items.map((d) => (d! as Map)['id']));
          cursor = page.body['nextCursor'] as String?;
        } while (cursor != null);
        expect(seen, [back.body['id'], ...ids.reversed]);
        final incomingToCompany = await api().get(
          '/v1/company-store/deliveries?projectId=$project&direction=incoming',
          as: manager,
        );
        expect(incomingToCompany.items.map((d) => (d! as Map)['flow']), [
          'incoming',
        ]);
      },
    );

    test(
      'a project with stock or deliveries in transit cannot be removed',
      () async {
        final id = await material(unique('Glass'));
        await addStock({id: 5});
        final sent = await sendToProject({id: 2});
        expect(
          (await api().delete('/v1/projects/$project', as: admin)).errorCode,
          'deliveries_in_transit',
        );
        await projectAction(sent.body['id']!, 'record');
        expect(
          (await api().delete('/v1/projects/$project', as: admin)).errorCode,
          'project_store_not_empty',
        );
        final back = await sendBack({id: 2});
        await companyAction(back.body['id']!, 'record');
        expect(
          (await api().delete('/v1/projects/$project', as: admin)).status,
          204,
        );
        // Its history stays in the company store's list.
        final history = await api().get(
          '/v1/company-store/deliveries?projectId=$project',
          as: manager,
        );
        expect(history.items, hasLength(2));
      },
    );
  });
}
