import 'dart:convert';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

import '../auth/caller.dart';
import '../db/database.dart';
import '../http/api_error.dart';
import '../http/json.dart';
import '../http/sql.dart';
import '../http/validation.dart';
import '../ids.dart';
import 'delivery_service.dart';

/// The company store screens. Only company store managers and SuperAdmins
/// reach any of this; everyone else gets a 403 (the company store's
/// existence is no secret, unlike a project's).
class CompanyStoreRoutes {
  CompanyStoreRoutes(this._db);

  final Database _db;
  static const _deliveries = DeliveryService();

  static const _stockStatuses = {
    'out_of_stock': 'out_of_stock',
    'low_stock': 'low_stock',
    'available': 'available',
  };

  static const _stockSorts = {
    'name': 'lower(m.name)',
    'quantity': 'cs.quantity',
    // Most urgent first when ascending.
    'status':
        "CASE cs.status WHEN 'out_of_stock' THEN 0 WHEN 'low_stock' THEN 1 ELSE 2 END",
  };

  static const _deliveryStatuses = {
    'in_transit': 'in_transit',
    'delivered': 'delivered',
    'rejected': 'rejected',
    'cancelled': 'cancelled',
  };

  /// `GET /v1/company-store/stock`: every material with its quantity, unit,
  /// quantity in transit to projects, reorder point and status.
  ///
  /// Filters: `status` (comma-separated), `category`, `search` (name).
  /// Sort: `name`, `quantity`, `status`.
  Future<Response> stock(Request request) async {
    _requireStoreStaff(request);
    final query = QueryReader(request.url.queryParameters);
    final statuses = query.choices('status', _stockStatuses);
    final category = query.string('category');
    final search = query.search();
    final sort = query.sort(_stockSorts, fallback: _stockSorts['name']!);
    final page = query.page();
    query.throwIfInvalid();

    final rows = await _db.query(
      '''
      SELECT m.id, m.name, m.category, m.unit, cs.quantity, cs.in_transit,
             cs.reorder_point, cs.status, count(*) OVER () AS total
        FROM company_stock cs
        JOIN materials m ON m.id = cs.material_id
       WHERE m.deleted_at IS NULL
         AND (@pattern::text IS NULL OR m.name ILIKE @pattern::text)
         AND (@category::text IS NULL OR m.category = @category::text)
         AND (@statuses::text[] IS NULL OR cs.status = ANY(@statuses::text[]))
       ${orderBy(sort.key, descending: sort.descending, tieBreaker: 'm.id')}
       LIMIT @limit OFFSET @offset''',
      {
        'pattern': containsPattern(search),
        'category': category,
        'statuses': statuses,
        'limit': page.limit,
        'offset': page.offset,
      },
    );
    return jsonResponse(
      pageJson(
        [for (final row in rows) _stockJson(row.toColumnMap())],
        total: rows.isEmpty ? 0 : rows.first.toColumnMap()['total'] as int,
        limit: page.limit,
        offset: page.offset,
      ),
    );
  }

  /// `POST /v1/company-store/stock-additions` with lines and optionally a
  /// note: stock arriving from a supplier. All lines apply, or none.
  Future<Response> addStock(Request request) async {
    final caller = _requireStoreStaff(request);
    final body = BodyReader(await readJsonObject(request));
    final lines = readStockLines(body);
    final note = body.optionalString('note', maxLength: 1000);
    body.throwIfInvalid();

    final items = await _db.transaction((tx) async {
      await _deliveries.addStock(tx, caller, lines, note);
      return _stockItems(tx, [for (final line in lines) line.materialId]);
    });
    return jsonResponse({'items': items}, status: 201);
  }

  /// `PATCH /v1/company-store/stock/{materialId}` with reorderPoint.
  Future<Response> setReorderPoint(Request request, String materialId) async {
    _requireStoreStaff(request);
    final id = int.tryParse(materialId);
    final body = BodyReader(await readJsonObject(request));
    final reorderPoint = parseQuantity(
      body.raw('reorderPoint'),
      allowZero: true,
    );
    if (reorderPoint == null) {
      body.error(
        'reorderPoint',
        'must be a number of at least 0 with at most 3 decimals',
      );
    }
    body.throwIfInvalid();

    final items = await _db.transaction((tx) async {
      final updated = id == null
          ? null
          : await tx.execute(
              Sql.named('''
                UPDATE company_stock cs SET reorder_point = @reorderPoint::numeric, updated_at = now()
                  FROM materials m
                 WHERE cs.material_id = @id AND m.id = cs.material_id AND m.deleted_at IS NULL
                RETURNING cs.material_id'''),
              parameters: {'id': id, 'reorderPoint': reorderPoint},
            );
      if (updated == null || updated.isEmpty) {
        throw ApiError.notFound('No such material');
      }
      return _stockItems(tx, [id!]);
    });
    return jsonResponse(items.single);
  }

  /// `GET /v1/company-store/projects?search=`: the projects a store manager
  /// can deliver to, by ID and name only. Managers deliver to every project
  /// without being members, so they need to pick one; nothing inside the
  /// project is shown.
  Future<Response> projects(Request request) async {
    _requireStoreStaff(request);
    final query = QueryReader(request.url.queryParameters);
    final search = query.search();
    final page = query.page();
    query.throwIfInvalid();
    final rows = await _db.query(
      '''
      SELECT id, name, count(*) OVER () AS total
        FROM projects
       WHERE deleted_at IS NULL
         AND (@pattern::text IS NULL OR name ILIKE @pattern::text
              OR project_code(id) ILIKE @pattern::text)
       ORDER BY lower(name), id
       LIMIT @limit OFFSET @offset''',
      {
        'pattern': containsPattern(search),
        'limit': page.limit,
        'offset': page.offset,
      },
    );
    return jsonResponse(
      pageJson(
        [
          for (final row in rows.map((r) => r.toColumnMap()))
            {'id': projectCode(row['id'] as int), 'name': row['name']},
        ],
        total: rows.isEmpty ? 0 : rows.first.toColumnMap()['total'] as int,
        limit: page.limit,
        offset: page.offset,
      ),
    );
  }

  /// `GET /v1/company-store/deliveries`: incoming and outgoing deliveries
  /// across all projects, newest first.
  ///
  /// Filters: `projectId`, `direction` (`incoming` = from projects,
  /// `outgoing` = to projects), `status` (comma-separated), `from` / `to`
  /// (date sent). Paged by cursor: pass `nextCursor` back as `cursor`. With
  /// 400,000 deliveries an offset would rescan every earlier page, and a
  /// total count would read every match, so neither is offered here.
  Future<Response> deliveries(Request request) async {
    _requireStoreStaff(request);
    final query = QueryReader(request.url.queryParameters);
    final projectRaw = query.string('projectId');
    final direction = query.choice('direction', {
      'incoming': 'to_company',
      'outgoing': 'to_project',
    });
    final statuses = query.choices('status', _deliveryStatuses);
    final from = query.date('from');
    final to = query.date('to');
    final limit = query.integer('limit', fallback: 50, min: 1, max: 200);
    final cursor = _decodeCursor(query, query.string('cursor', maxLength: 200));
    final projectId = projectRaw == null ? null : parseProjectCode(projectRaw);
    if (projectRaw != null && projectId == null) {
      query.error('projectId', 'must be a project ID such as PRJ-0042');
    }
    query.throwIfInvalid();

    final items = await fetchDeliveries(
      _db.pool,
      side: StoreSide.company,
      where: '''
        (@projectId::integer IS NULL OR d.project_id = @projectId::integer)
        AND (@direction::text IS NULL OR d.direction = @direction::text)
        AND (@statuses::text[] IS NULL OR d.status = ANY(@statuses::text[]))
        AND (@from::date IS NULL OR d.sent_at >= @from::date)
        AND (@to::date IS NULL OR d.sent_at < @to::date + 1)
        AND (@cursorAt::timestamptz IS NULL
             OR (d.sent_at, d.id) < (@cursorAt::timestamptz, @cursorId::bigint))''',
      parameters: {
        'projectId': projectId,
        'direction': direction,
        'statuses': statuses,
        'from': from,
        'to': to,
        'cursorAt': cursor?.sentAt,
        'cursorId': cursor?.id,
        'limit': limit + 1,
      },
      tail: 'ORDER BY d.sent_at DESC, d.id DESC LIMIT @limit',
    );
    final hasMore = items.length > limit;
    final page = hasMore ? items.sublist(0, limit) : items;
    return jsonResponse({
      'items': page,
      'limit': limit,
      'nextCursor': hasMore ? _encodeCursor(page.last) : null,
    });
  }

  /// `GET /v1/company-store/deliveries/{deliveryId}`
  Future<Response> delivery(Request request, String deliveryId) async {
    _requireStoreStaff(request);
    return jsonResponse(await _one(_db.pool, _deliveryId(deliveryId)));
  }

  /// `POST /v1/company-store/deliveries` with projectId, lines and optionally
  /// a note: sends material from the company store to a project store.
  Future<Response> send(Request request) async {
    final caller = _requireStoreStaff(request);
    final body = BodyReader(await readJsonObject(request));
    final projectRaw = body.string('projectId', maxLength: 20);
    final lines = readStockLines(body);
    final note = body.optionalString('note', maxLength: 1000);
    final projectId = parseProjectCode(projectRaw);
    if (body.has('projectId') && projectId == null) {
      body.error('projectId', 'must be a project ID such as PRJ-0042');
    }
    body.throwIfInvalid();

    final delivery = await _db.transaction((tx) async {
      final id = await _deliveries.sendToProject(
        tx,
        caller,
        projectId!,
        lines,
        note,
      );
      return _one(tx, id);
    });
    return jsonResponse(delivery, status: 201);
  }

  /// `POST /v1/company-store/deliveries/{deliveryId}/record`: a delivery
  /// from a project arrived; its quantities join the company store.
  Future<Response> record(Request request, String deliveryId) =>
      _close(request, deliveryId, DeliveryAction.record);

  /// `POST /v1/company-store/deliveries/{deliveryId}/reject`: refused; the
  /// quantities return to the project store.
  Future<Response> reject(Request request, String deliveryId) =>
      _close(request, deliveryId, DeliveryAction.reject);

  /// `POST /v1/company-store/deliveries/{deliveryId}/cancel`: the company
  /// store calls back a delivery to a project that is still in transit.
  Future<Response> cancel(Request request, String deliveryId) =>
      _close(request, deliveryId, DeliveryAction.cancel);

  Future<Response> _close(
    Request request,
    String deliveryId,
    DeliveryAction action,
  ) async {
    final caller = _requireStoreStaff(request);
    final id = _deliveryId(deliveryId);
    final delivery = await _db.transaction((tx) async {
      await _deliveries.close(tx, caller, id, action, side: StoreSide.company);
      return _one(tx, id);
    });
    return jsonResponse(delivery);
  }

  static Caller _requireStoreStaff(Request request) {
    final caller = callerOf(request);
    if (!caller.canUseCompanyStore) {
      throw ApiError.forbidden(
        'Only company store managers and SuperAdmins can use the company store',
      );
    }
    return caller;
  }

  static int _deliveryId(String raw) =>
      int.tryParse(raw) ?? (throw ApiError.notFound('No such delivery'));

  static Future<Map<String, Object?>> _one(Session session, int id) async {
    final found = await fetchDeliveries(
      session,
      side: StoreSide.company,
      where: 'd.id = @id',
      parameters: {'id': id},
      tail: '',
    );
    if (found.isEmpty) throw ApiError.notFound('No such delivery');
    return found.single;
  }

  static Future<List<Map<String, Object?>>> _stockItems(
    Session session,
    List<int> materialIds,
  ) async {
    final rows = await session.execute(
      Sql.named('''
        SELECT m.id, m.name, m.category, m.unit, cs.quantity, cs.in_transit,
               cs.reorder_point, cs.status
          FROM company_stock cs JOIN materials m ON m.id = cs.material_id
         WHERE cs.material_id = ANY(@ids::integer[])
         ORDER BY m.id'''),
      parameters: {'ids': materialIds},
    );
    return [for (final row in rows) _stockJson(row.toColumnMap())];
  }

  static Map<String, Object?> _stockJson(Map<String, dynamic> row) => {
    'materialId': row['id'],
    'name': row['name'],
    'category': row['category'],
    'unit': row['unit'],
    'quantity': quantityToJson(row['quantity']),
    'inTransitToProjects': quantityToJson(row['in_transit']),
    'reorderPoint': quantityToJson(row['reorder_point']),
    'status': row['status'],
  };

  static String _encodeCursor(Map<String, Object?> delivery) => base64Url
      .encode(utf8.encode('${delivery['sentAt']}|${delivery['id']}'))
      .replaceAll('=', '');

  static ({DateTime sentAt, int id})? _decodeCursor(
    QueryReader query,
    String? raw,
  ) {
    if (raw == null) return null;
    try {
      final text = utf8.decode(base64Url.decode(base64Url.normalize(raw)));
      final [sentAt, id] = text.split('|');
      return (sentAt: DateTime.parse(sentAt), id: int.parse(id));
    } on Object {
      query.error('cursor', 'is not a cursor this API returned');
      return null;
    }
  }
}
