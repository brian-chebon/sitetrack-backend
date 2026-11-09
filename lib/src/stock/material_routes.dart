import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

import '../auth/caller.dart';
import '../db/database.dart';
import '../http/api_error.dart';
import '../http/json.dart';
import '../http/sql.dart';
import '../http/validation.dart';

/// The materials catalogue. Everyone signed in can read it; company store
/// managers and SuperAdmins, who run the company store, maintain it.
class MaterialRoutes {
  MaterialRoutes(this._db);

  final Database _db;

  /// `GET /v1/materials?search=&category=&limit=&offset=`
  Future<Response> list(Request request) async {
    callerOf(request);
    final query = QueryReader(request.url.queryParameters);
    final search = query.search();
    final category = query.string('category');
    final page = query.page();
    query.throwIfInvalid();

    final rows = await _db.query(
      '''
      SELECT id, name, category, unit, created_at, updated_at, count(*) OVER () AS total
        FROM materials
       WHERE deleted_at IS NULL
         AND (@pattern::text IS NULL OR name ILIKE @pattern::text)
         AND (@category::text IS NULL OR category = @category::text)
       ORDER BY lower(name), id
       LIMIT @limit OFFSET @offset''',
      {
        'pattern': containsPattern(search),
        'category': category,
        'limit': page.limit,
        'offset': page.offset,
      },
    );
    return jsonResponse(
      pageJson(
        [for (final row in rows) _materialJson(row.toColumnMap())],
        total: rows.isEmpty ? 0 : rows.first.toColumnMap()['total'] as int,
        limit: page.limit,
        offset: page.offset,
      ),
    );
  }

  /// `GET /v1/materials/categories`: for the category filters.
  Future<Response> categories(Request request) async {
    callerOf(request);
    final rows = await _db.query('''
      SELECT category, count(*)::int AS materials
        FROM materials WHERE deleted_at IS NULL
       GROUP BY category ORDER BY lower(category)''');
    return jsonResponse({
      'items': [
        for (final row in rows) {'name': row[0], 'materials': row[1]},
      ],
    });
  }

  /// `GET /v1/materials/{materialId}`
  Future<Response> get(Request request, String materialId) async {
    callerOf(request);
    return jsonResponse(await _one(_db.pool, _id(materialId)));
  }

  /// `POST /v1/materials` with name, category, unit and optionally
  /// reorderPoint. Also opens its row in the company store at zero.
  Future<Response> create(Request request) async {
    _requireStoreStaff(callerOf(request));
    final body = BodyReader(await readJsonObject(request));
    final name = body.string('name');
    final category = body.string('category', maxLength: 100);
    final unit = body.string('unit', maxLength: 30);
    final reorderPoint = body.has('reorderPoint')
        ? parseQuantity(body.raw('reorderPoint'), allowZero: true)
        : '0';
    if (reorderPoint == null) {
      body.error(
        'reorderPoint',
        'must be a number of at least 0 with at most 3 decimals',
      );
    }
    body.throwIfInvalid();

    final material = await _db.transaction((tx) async {
      final Result rows;
      try {
        rows = await tx.execute(
          Sql.named('''
            INSERT INTO materials (name, category, unit)
            VALUES (@name, @category, @unit) RETURNING id'''),
          parameters: {'name': name, 'category': category, 'unit': unit},
        );
      } on ServerException catch (error) {
        if (error.code == '23505') throw _nameTaken(name);
        rethrow;
      }
      final id = rows.single[0]! as int;
      await tx.execute(
        Sql.named('''
          INSERT INTO company_stock (material_id, reorder_point)
          VALUES (@id, @reorderPoint::numeric)'''),
        parameters: {'id': id, 'reorderPoint': reorderPoint},
      );
      return _one(tx, id);
    });
    return jsonResponse(material, status: 201);
  }

  /// `PATCH /v1/materials/{materialId}` with any of name, category, unit.
  ///
  /// The unit can only change while no stock of the material has ever been
  /// added: after that, existing quantities and delivery lines are counted
  /// in the old unit.
  Future<Response> update(Request request, String materialId) async {
    _requireStoreStaff(callerOf(request));
    final id = _id(materialId);
    final body = BodyReader(await readJsonObject(request));
    final name = body.optionalString('name');
    final category = body.optionalString('category', maxLength: 100);
    final unit = body.optionalString('unit', maxLength: 30);
    body.throwIfInvalid();

    final material = await _db.transaction((tx) async {
      final rows = await tx.execute(
        Sql.named('''
          SELECT unit, EXISTS (SELECT 1 FROM stock_additions WHERE material_id = @id) AS stocked
            FROM materials WHERE id = @id AND deleted_at IS NULL FOR UPDATE'''),
        parameters: {'id': id},
      );
      if (rows.isEmpty) throw _notFound();
      final current = rows.single.toColumnMap();
      if (unit != null &&
          unit != current['unit'] &&
          current['stocked'] as bool) {
        throw ApiError.conflict(
          'unit_in_use',
          'Stock of this material has been recorded in ${current['unit']}; '
              'create a new material for the new unit',
        );
      }
      try {
        await tx.execute(
          Sql.named('''
            UPDATE materials
               SET name = coalesce(@name, name), category = coalesce(@category, category),
                   unit = coalesce(@unit, unit), updated_at = now()
             WHERE id = @id'''),
          parameters: {
            'id': id,
            'name': name,
            'category': category,
            'unit': unit,
          },
        );
      } on ServerException catch (error) {
        if (error.code == '23505') throw _nameTaken(name!);
        rethrow;
      }
      return _one(tx, id);
    });
    return jsonResponse(material);
  }

  /// `DELETE /v1/materials/{materialId}`: removes it from the catalogue.
  /// Refused while any store holds it or a delivery of it is in transit;
  /// past deliveries keep showing it.
  Future<Response> remove(Request request, String materialId) async {
    _requireStoreStaff(callerOf(request));
    final id = _id(materialId);
    await _db.transaction((tx) async {
      // Deliveries take FOR SHARE on the materials they carry, so this lock
      // waits for any delivery being sent right now.
      final rows = await tx.execute(
        Sql.named(
          'SELECT id FROM materials WHERE id = @id AND deleted_at IS NULL FOR UPDATE',
        ),
        parameters: {'id': id},
      );
      if (rows.isEmpty) throw _notFound();
      final held = (await tx.execute(
        Sql.named(
          '''
          SELECT (SELECT quantity > 0 OR in_transit > 0 FROM company_stock
                   WHERE material_id = @id) AS in_company,
                 EXISTS (SELECT 1 FROM project_stock
                          WHERE material_id = @id AND quantity > 0) AS in_projects,
                 EXISTS (SELECT 1 FROM deliveries d
                           JOIN delivery_lines l ON l.delivery_id = d.id
                          WHERE d.status = 'in_transit' AND l.material_id = @id) AS in_transit''',
        ),
        parameters: {'id': id},
      )).single.toColumnMap();
      if (held.values.any((v) => v == true)) {
        throw ApiError.conflict(
          'material_in_use',
          'Stores still hold this material or a delivery of it is in transit',
        );
      }
      await tx.execute(
        Sql.named('UPDATE materials SET deleted_at = now() WHERE id = @id'),
        parameters: {'id': id},
      );
    });
    return Response(204);
  }

  static void _requireStoreStaff(Caller caller) {
    if (!caller.canUseCompanyStore) {
      throw ApiError.forbidden(
        'Only company store managers and SuperAdmins maintain the catalogue',
      );
    }
  }

  static int _id(String raw) => int.tryParse(raw) ?? (throw _notFound());

  static ApiError _notFound() => ApiError.notFound('No such material');

  static ApiError _nameTaken(String name) => ApiError.conflict(
    'material_exists',
    'A material named "$name" already exists',
  );

  static Future<Map<String, Object?>> _one(Session session, int id) async {
    final rows = await session.execute(
      Sql.named('''
        SELECT id, name, category, unit, created_at, updated_at
          FROM materials WHERE id = @id AND deleted_at IS NULL'''),
      parameters: {'id': id},
    );
    if (rows.isEmpty) throw _notFound();
    return _materialJson(rows.single.toColumnMap());
  }

  static Map<String, Object?> _materialJson(Map<String, dynamic> row) => {
    'id': row['id'],
    'name': row['name'],
    'category': row['category'],
    'unit': row['unit'],
    'createdAt': formatTimestamp(row['created_at'] as DateTime),
    'updatedAt': formatTimestamp(row['updated_at'] as DateTime),
  };
}
