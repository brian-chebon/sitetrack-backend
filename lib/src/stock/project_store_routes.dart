import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

import '../auth/caller.dart';
import '../db/database.dart';
import '../http/api_error.dart';
import '../http/json.dart';
import '../http/sql.dart';
import '../http/validation.dart';
import '../projects/project_access.dart';
import 'delivery_service.dart';

/// A project's store and deliveries. Members and SuperAdmins only, through
/// the same loadProject() check as every other project route.
class ProjectStoreRoutes {
  ProjectStoreRoutes(this._db);

  final Database _db;
  static const _deliveries = DeliveryService();

  static const _stockSorts = {
    'name': 'lower(m.name)',
    'quantity': 'ps.quantity',
    'lastDelivery': 'ps.last_delivery_at',
  };

  static const _deliveryStatuses = {
    'in_transit': 'in_transit',
    'delivered': 'delivered',
    'rejected': 'rejected',
    'cancelled': 'cancelled',
  };

  /// `GET /v1/projects/{projectId}/store`: every material the store holds or
  /// has held, with quantity, unit and date of its last delivery in or out.
  ///
  /// Filters: `search` (name), `category`. Sort: `name`, `quantity`,
  /// `lastDelivery`.
  Future<Response> stock(Request request, String projectId) async {
    final caller = callerOf(request);
    final query = QueryReader(request.url.queryParameters);
    final search = query.search();
    final category = query.string('category');
    final sort = query.sort(_stockSorts, fallback: _stockSorts['name']!);
    final page = query.page();
    query.throwIfInvalid();

    final access = await loadProject(_db.pool, caller, projectId);
    final rows = await _db.query(
      '''
      SELECT m.id, m.name, m.category, m.unit, ps.quantity, ps.last_delivery_at,
             count(*) OVER () AS total
        FROM project_stock ps
        JOIN materials m ON m.id = ps.material_id
       WHERE ps.project_id = @projectId
         AND (@pattern::text IS NULL OR m.name ILIKE @pattern::text)
         AND (@category::text IS NULL OR m.category = @category::text)
       ${orderBy(sort.key, descending: sort.descending, tieBreaker: 'm.id')}
       LIMIT @limit OFFSET @offset''',
      {
        'projectId': access.id,
        'pattern': containsPattern(search),
        'category': category,
        'limit': page.limit,
        'offset': page.offset,
      },
    );
    return jsonResponse(
      pageJson(
        [
          for (final row in rows.map((r) => r.toColumnMap()))
            {
              'materialId': row['id'],
              'name': row['name'],
              'category': row['category'],
              'unit': row['unit'],
              'quantity': quantityToJson(row['quantity']),
              'lastDeliveryAt': formatTimestamp(
                row['last_delivery_at'] as DateTime,
              ),
            },
        ],
        total: rows.isEmpty ? 0 : rows.first.toColumnMap()['total'] as int,
        limit: page.limit,
        offset: page.offset,
      ),
    );
  }

  /// `GET /v1/projects/{projectId}/deliveries`: the store's incoming and
  /// outgoing deliveries, newest first.
  ///
  /// Filters: `direction` (`incoming` = from the company store, `outgoing` =
  /// back to it), `status` (comma-separated), `from` / `to` (date sent).
  Future<Response> deliveries(Request request, String projectId) async {
    final caller = callerOf(request);
    final query = QueryReader(request.url.queryParameters);
    final direction = query.choice('direction', {
      'incoming': 'to_project',
      'outgoing': 'to_company',
    });
    final statuses = query.choices('status', _deliveryStatuses);
    final from = query.date('from');
    final to = query.date('to');
    final page = query.page();
    query.throwIfInvalid();

    final access = await loadProject(_db.pool, caller, projectId);
    var total = 0;
    final items = await fetchDeliveries(
      _db.pool,
      side: StoreSide.project,
      where: '''
        d.project_id = @projectId
        AND (@direction::text IS NULL OR d.direction = @direction::text)
        AND (@statuses::text[] IS NULL OR d.status = ANY(@statuses::text[]))
        AND (@from::date IS NULL OR d.sent_at >= @from::date)
        AND (@to::date IS NULL OR d.sent_at < @to::date + 1)''',
      parameters: {
        'projectId': access.id,
        'direction': direction,
        'statuses': statuses,
        'from': from,
        'to': to,
        'limit': page.limit,
        'offset': page.offset,
      },
      tail: 'ORDER BY d.sent_at DESC, d.id DESC LIMIT @limit OFFSET @offset',
      withTotal: true,
      onTotal: (value) => total = value,
    );
    return jsonResponse(
      pageJson(items, total: total, limit: page.limit, offset: page.offset),
    );
  }

  /// `GET /v1/projects/{projectId}/deliveries/{deliveryId}`
  Future<Response> delivery(
    Request request,
    String projectId,
    String deliveryId,
  ) async {
    final caller = callerOf(request);
    final access = await loadProject(_db.pool, caller, projectId);
    return jsonResponse(await _one(_db.pool, access.id, deliveryId));
  }

  /// `POST /v1/projects/{projectId}/deliveries` with lines and optionally a
  /// note: sends material back to the company store.
  Future<Response> send(Request request, String projectId) async {
    final caller = callerOf(request);
    final body = BodyReader(await readJsonObject(request));
    final lines = readStockLines(body);
    final note = body.optionalString('note', maxLength: 1000);
    body.throwIfInvalid();

    final delivery = await _db.transaction((tx) async {
      final access = await loadProject(
        tx,
        caller,
        projectId,
        lock: ProjectLock.share,
      );
      final id = await _deliveries.sendToCompany(
        tx,
        caller,
        access.id,
        lines,
        note,
      );
      return _one(tx, access.id, '$id');
    });
    return jsonResponse(delivery, status: 201);
  }

  /// `POST .../deliveries/{deliveryId}/record`: a delivery from the company
  /// store arrived; its quantities join the project store.
  Future<Response> record(
    Request request,
    String projectId,
    String deliveryId,
  ) => _close(request, projectId, deliveryId, DeliveryAction.record);

  /// `POST .../deliveries/{deliveryId}/reject`: refused; the quantities
  /// return to the company store.
  Future<Response> reject(
    Request request,
    String projectId,
    String deliveryId,
  ) => _close(request, projectId, deliveryId, DeliveryAction.reject);

  /// `POST .../deliveries/{deliveryId}/cancel`: calls back a delivery to the
  /// company store that is still in transit.
  Future<Response> cancel(
    Request request,
    String projectId,
    String deliveryId,
  ) => _close(request, projectId, deliveryId, DeliveryAction.cancel);

  Future<Response> _close(
    Request request,
    String projectId,
    String deliveryId,
    DeliveryAction action,
  ) async {
    final caller = callerOf(request);
    final delivery = await _db.transaction((tx) async {
      final access = await loadProject(
        tx,
        caller,
        projectId,
        lock: ProjectLock.share,
      );
      final id =
          int.tryParse(deliveryId) ??
          (throw ApiError.notFound('No such delivery'));
      await _deliveries.close(
        tx,
        caller,
        id,
        action,
        side: StoreSide.project,
        projectId: access.id,
      );
      return _one(tx, access.id, deliveryId);
    });
    return jsonResponse(delivery);
  }

  static Future<Map<String, Object?>> _one(
    Session session,
    int projectId,
    String deliveryId,
  ) async {
    final id = int.tryParse(deliveryId);
    final found = id == null
        ? const <Map<String, Object?>>[]
        : await fetchDeliveries(
            session,
            side: StoreSide.project,
            where: 'd.id = @id AND d.project_id = @projectId',
            parameters: {'id': id, 'projectId': projectId},
            tail: '',
          );
    if (found.isEmpty) throw ApiError.notFound('No such delivery');
    return found.single;
  }
}
