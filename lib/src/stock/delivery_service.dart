import 'package:postgres/postgres.dart';

import '../auth/caller.dart';
import '../http/api_error.dart';
import '../http/validation.dart';
import '../ids.dart';

/// One material and quantity on a delivery or stock addition.
typedef StockLine = ({int materialId, String quantity});

/// Which store's screen a request comes from.
enum StoreSide { company, project }

/// Record, reject and cancel: the three ways a delivery leaves In transit.
enum DeliveryAction {
  record('delivered'),
  reject('rejected'),
  cancel('cancelled');

  const DeliveryAction(this.status);

  /// The status the delivery ends in.
  final String status;
}

/// Reads `lines: [{materialId, quantity}, ...]` from a request body, sorted
/// by material so every transaction locks stock rows in the same order.
List<StockLine> readStockLines(BodyReader body) {
  final raw = body.list('lines', minLength: 1, maxLength: 200);
  final lines = <StockLine>[];
  final seen = <int>{};
  for (var i = 0; i < raw.length; i++) {
    final item = raw[i];
    if (item is! Map<String, Object?>) {
      body.error('lines[$i]', 'must be an object with materialId and quantity');
      continue;
    }
    final materialId = item['materialId'];
    final quantity = parseQuantity(item['quantity']);
    if (materialId is! int) {
      body.error('lines[$i].materialId', 'must be an integer');
    } else if (!seen.add(materialId)) {
      body.error('lines[$i].materialId', 'appears more than once');
    }
    if (quantity == null) {
      body.error(
        'lines[$i].quantity',
        'must be a positive number with at most 3 decimals',
      );
    }
    if (materialId is int && quantity != null) {
      lines.add((materialId: materialId, quantity: quantity));
    }
  }
  lines.sort((a, b) => a.materialId.compareTo(b.materialId));
  return lines;
}

/// Moves material between stores. Every method runs inside the caller's
/// transaction and either completes or throws, so each operation happens
/// completely or not at all.
///
/// Concurrency rules, the same in every method:
///   * Stock rows are locked `FOR UPDATE` in material order before they are
///     read or changed, so two deliveries from one store serialise on the
///     rows they share and can never deadlock each other.
///   * A quantity is only taken after checking, under that lock, that it is
///     there; the CHECK (quantity >= 0) constraints are the backstop.
///   * A delivery row is locked before its status changes, so of a record
///     and a cancel racing on one delivery, exactly one succeeds.
///   * Locks are always taken in the order project, materials, delivery,
///     company stock, project stock.
class DeliveryService {
  const DeliveryService();

  /// A store manager adds stock from a supplier to the company store: the
  /// only way new material enters SiteTrack.
  Future<void> addStock(
    TxSession tx,
    Caller caller,
    List<StockLine> lines,
    String? note,
  ) async {
    await _lockMaterials(tx, lines);
    await _lockCompanyStock(tx, lines.map((l) => l.materialId));
    await tx.execute(
      Sql.named('''
        UPDATE company_stock cs
           SET quantity = cs.quantity + l.qty, updated_at = now()
          FROM unnest(@ids::integer[], (@qtys::text[])::numeric[]) AS l (material_id, qty)
         WHERE cs.material_id = l.material_id'''),
      parameters: _lineParameters(lines),
    );
    await tx.execute(
      Sql.named(
        '''
        INSERT INTO stock_additions (material_id, quantity, added_by, note)
        SELECT l.material_id, l.qty, @userId, @note
          FROM unnest(@ids::integer[], (@qtys::text[])::numeric[]) AS l (material_id, qty)''',
      ),
      parameters: {
        ..._lineParameters(lines),
        'userId': caller.id,
        'note': note,
      },
    );
  }

  /// Company store to project store. The quantities leave the company
  /// store at once and count as in transit until the delivery is closed.
  Future<int> sendToProject(
    TxSession tx,
    Caller caller,
    int projectId,
    List<StockLine> lines,
    String? note,
  ) async {
    // Hold the project so it cannot be removed while this is being sent.
    final project = await tx.execute(
      Sql.named(
        'SELECT id FROM projects WHERE id = @id AND deleted_at IS NULL FOR SHARE',
      ),
      parameters: {'id': projectId},
    );
    if (project.isEmpty) {
      throw ApiError.badRequest(
        'Some fields are invalid',
        details: {
          'fields': {'projectId': 'no such project'},
        },
      );
    }
    await _lockMaterials(tx, lines);
    await _lockCompanyStock(tx, lines.map((l) => l.materialId));
    await _ensureAvailable(
      tx,
      lines,
      '''SELECT material_id, quantity FROM company_stock
          WHERE material_id = ANY(@ids::integer[])''',
      const {},
    );
    await tx.execute(
      Sql.named('''
        UPDATE company_stock cs
           SET quantity = cs.quantity - l.qty, in_transit = cs.in_transit + l.qty,
               updated_at = now()
          FROM unnest(@ids::integer[], (@qtys::text[])::numeric[]) AS l (material_id, qty)
         WHERE cs.material_id = l.material_id'''),
      parameters: _lineParameters(lines),
    );
    return _insertDelivery(tx, caller, projectId, 'to_project', lines, note);
  }

  /// Project store back to the company store. The caller must already hold
  /// the project with ProjectLock.share.
  Future<int> sendToCompany(
    TxSession tx,
    Caller caller,
    int projectId,
    List<StockLine> lines,
    String? note,
  ) async {
    await _lockMaterials(tx, lines);
    await _lockProjectStock(tx, projectId, lines.map((l) => l.materialId));
    await _ensureAvailable(
      tx,
      lines,
      '''SELECT material_id, quantity FROM project_stock
          WHERE project_id = @projectId AND material_id = ANY(@ids::integer[])''',
      {'projectId': projectId},
    );
    await tx.execute(
      Sql.named(
        '''
        UPDATE project_stock ps
           SET quantity = ps.quantity - l.qty, last_delivery_at = now()
          FROM unnest(@ids::integer[], (@qtys::text[])::numeric[]) AS l (material_id, qty)
         WHERE ps.project_id = @projectId AND ps.material_id = l.material_id''',
      ),
      parameters: {..._lineParameters(lines), 'projectId': projectId},
    );
    return _insertDelivery(tx, caller, projectId, 'to_company', lines, note);
  }

  /// Records, rejects or cancels delivery [deliveryId] from [side].
  ///
  /// The receiving store records or rejects; the sending store cancels. On
  /// the project side the caller must hold the project with
  /// ProjectLock.share and pass its ID; a delivery of another project is
  /// not found.
  Future<void> close(
    TxSession tx,
    Caller caller,
    int deliveryId,
    DeliveryAction action, {
    required StoreSide side,
    int? projectId,
  }) async {
    final rows = await tx.execute(
      Sql.named('''
        SELECT project_id, direction, status FROM deliveries
         WHERE id = @id AND (@projectId::integer IS NULL OR project_id = @projectId::integer)
         FOR UPDATE'''),
      parameters: {'id': deliveryId, 'projectId': projectId},
    );
    if (rows.isEmpty) throw ApiError.notFound('No such delivery');
    final delivery = rows.single.toColumnMap();
    final direction = delivery['direction'] as String;
    final deliveryProject = delivery['project_id'] as int;

    final incoming = side == StoreSide.company
        ? direction == 'to_company'
        : direction == 'to_project';
    if (action == DeliveryAction.cancel && incoming) {
      throw ApiError.conflict(
        'not_sender',
        'Only the sending store can cancel a delivery',
      );
    }
    if (action != DeliveryAction.cancel && !incoming) {
      throw ApiError.conflict(
        'not_receiver',
        'Only the receiving store can record or reject a delivery',
      );
    }
    if (delivery['status'] != 'in_transit') {
      throw ApiError.conflict(
        'delivery_closed',
        'This delivery is already ${delivery['status']}',
      );
    }

    await tx.execute(
      Sql.named('''
        UPDATE deliveries SET status = @status, closed_by = @userId, closed_at = now()
         WHERE id = @id'''),
      parameters: {
        'id': deliveryId,
        'status': action.status,
        'userId': caller.id,
      },
    );

    final lines = await tx.execute(
      Sql.named('''
        SELECT material_id FROM delivery_lines
         WHERE delivery_id = @id ORDER BY material_id'''),
      parameters: {'id': deliveryId},
    );
    final materialIds = [for (final row in lines) row[0]! as int];
    final delivered = action == DeliveryAction.record;
    final params = {'id': deliveryId, 'projectId': deliveryProject};

    if (direction == 'to_project') {
      // Either way it is no longer in transit from the company store.
      await _lockCompanyStock(tx, materialIds);
      await tx.execute(
        Sql.named('''
          UPDATE company_stock cs
             SET in_transit = cs.in_transit - l.quantity,
                 quantity = cs.quantity + CASE WHEN @delivered::boolean THEN 0 ELSE l.quantity END,
                 updated_at = now()
            FROM delivery_lines l
           WHERE l.delivery_id = @id AND cs.material_id = l.material_id'''),
        parameters: {'id': deliveryId, 'delivered': delivered},
      );
      if (delivered) {
        await _lockProjectStock(tx, deliveryProject, materialIds);
        await tx.execute(
          Sql.named('''
            INSERT INTO project_stock AS ps (project_id, material_id, quantity, last_delivery_at)
            SELECT @projectId, l.material_id, l.quantity, now()
              FROM delivery_lines l WHERE l.delivery_id = @id
             ORDER BY l.material_id
            ON CONFLICT (project_id, material_id) DO UPDATE
               SET quantity = ps.quantity + excluded.quantity,
                   last_delivery_at = excluded.last_delivery_at'''),
          parameters: params,
        );
      }
    } else if (delivered) {
      await _lockCompanyStock(tx, materialIds);
      await tx.execute(
        Sql.named('''
          UPDATE company_stock cs
             SET quantity = cs.quantity + l.quantity, updated_at = now()
            FROM delivery_lines l
           WHERE l.delivery_id = @id AND cs.material_id = l.material_id'''),
        parameters: {'id': deliveryId},
      );
    } else {
      // Rejected or cancelled on the way back: it returns to the project.
      await _lockProjectStock(tx, deliveryProject, materialIds);
      await tx.execute(
        Sql.named('''
          UPDATE project_stock ps
             SET quantity = ps.quantity + l.quantity
            FROM delivery_lines l
           WHERE l.delivery_id = @id AND ps.project_id = @projectId
             AND ps.material_id = l.material_id'''),
        parameters: params,
      );
    }
  }

  /// Checks every material exists and is in the catalogue, and holds them
  /// (FOR SHARE) so none can be removed while this transaction runs.
  Future<void> _lockMaterials(TxSession tx, List<StockLine> lines) async {
    final ids = [for (final line in lines) line.materialId];
    final found = await tx.execute(
      Sql.named('''
        SELECT id FROM materials
         WHERE id = ANY(@ids::integer[]) AND deleted_at IS NULL
         ORDER BY id FOR SHARE'''),
      parameters: {'ids': ids},
    );
    final existing = {for (final row in found) row[0]! as int};
    final missing = ids.where((id) => !existing.contains(id)).toList();
    if (missing.isNotEmpty) {
      throw ApiError.badRequest(
        'Some fields are invalid',
        details: {
          'fields': {'lines': 'unknown materials: ${missing.join(', ')}'},
        },
      );
    }
  }

  Future<void> _lockCompanyStock(TxSession tx, Iterable<int> materialIds) =>
      tx.execute(
        Sql.named('''
          SELECT 1 FROM company_stock
           WHERE material_id = ANY(@ids::integer[])
           ORDER BY material_id FOR UPDATE'''),
        parameters: {'ids': materialIds.toList()},
      );

  Future<void> _lockProjectStock(
    TxSession tx,
    int projectId,
    Iterable<int> materialIds,
  ) => tx.execute(
    Sql.named('''
      SELECT 1 FROM project_stock
       WHERE project_id = @projectId AND material_id = ANY(@ids::integer[])
       ORDER BY material_id FOR UPDATE'''),
    parameters: {'projectId': projectId, 'ids': materialIds.toList()},
  );

  /// Throws a 409 listing every line asking for more than the (already
  /// locked) store holds.
  Future<void> _ensureAvailable(
    TxSession tx,
    List<StockLine> lines,
    String stockQuery,
    Map<String, Object?> parameters,
  ) async {
    final rows = await tx.execute(
      Sql.named('''
        WITH stock AS ($stockQuery)
        SELECT l.material_id, coalesce(s.quantity, 0)::text AS available, l.qty::text AS requested
          FROM unnest(@ids::integer[], (@qtys::text[])::numeric[]) AS l (material_id, qty)
          LEFT JOIN stock s ON s.material_id = l.material_id
         WHERE coalesce(s.quantity, 0) < l.qty
         ORDER BY l.material_id'''),
      parameters: {..._lineParameters(lines), ...parameters},
    );
    if (rows.isNotEmpty) {
      throw ApiError.conflict(
        'insufficient_stock',
        'The sending store does not hold enough of some materials',
        details: {
          'shortages': [
            for (final row in rows.map((r) => r.toColumnMap()))
              {
                'materialId': row['material_id'],
                'requested': quantityToJson(row['requested']),
                'available': quantityToJson(row['available']),
              },
          ],
        },
      );
    }
  }

  Future<int> _insertDelivery(
    TxSession tx,
    Caller caller,
    int projectId,
    String direction,
    List<StockLine> lines,
    String? note,
  ) async {
    final rows = await tx.execute(
      Sql.named('''
        INSERT INTO deliveries (project_id, direction, sent_by, note)
        VALUES (@projectId, @direction, @userId, @note) RETURNING id'''),
      parameters: {
        'projectId': projectId,
        'direction': direction,
        'userId': caller.id,
        'note': note,
      },
    );
    final id = rows.single[0]! as int;
    await tx.execute(
      Sql.named(
        '''
        INSERT INTO delivery_lines (delivery_id, material_id, quantity)
        SELECT @id, l.material_id, l.qty
          FROM unnest(@ids::integer[], (@qtys::text[])::numeric[]) AS l (material_id, qty)''',
      ),
      parameters: {..._lineParameters(lines), 'id': id},
    );
    return id;
  }

  static Map<String, Object?> _lineParameters(List<StockLine> lines) => {
    'ids': [for (final line in lines) line.materialId],
    'qtys': [for (final line in lines) line.quantity],
  };
}

/// Fetches deliveries with their lines and people, shaped for [side]'s
/// screen. [where] is a fixed SQL fragment chosen by the caller, never
/// built from user input.
Future<List<Map<String, Object?>>> fetchDeliveries(
  Session session, {
  required StoreSide side,
  required String where,
  required Map<String, Object?> parameters,
  required String tail,
  bool withTotal = false,
  void Function(int total)? onTotal,
}) async {
  final rows = await session.execute(
    Sql.named('''
      SELECT d.id, d.project_id, p.name AS project_name, d.direction, d.status,
             d.sent_at, d.sent_by, sender.name AS sent_by_name,
             d.closed_at, d.closed_by, closer.name AS closed_by_name, d.note
             ${withTotal ? ', count(*) OVER () AS total' : ''}
        FROM deliveries d
        JOIN projects p ON p.id = d.project_id
        JOIN users sender ON sender.id = d.sent_by
        LEFT JOIN users closer ON closer.id = d.closed_by
       WHERE $where
       $tail'''),
    parameters: parameters,
  );
  final deliveries = [for (final row in rows) row.toColumnMap()];
  onTotal?.call(deliveries.isEmpty ? 0 : deliveries.first['total'] as int);
  if (deliveries.isEmpty) return [];

  final lines = await session.execute(
    Sql.named('''
      SELECT l.delivery_id, l.material_id, m.name, m.unit, l.quantity::text AS quantity
        FROM delivery_lines l
        JOIN materials m ON m.id = l.material_id
       WHERE l.delivery_id = ANY(@ids::bigint[])
       ORDER BY l.delivery_id, lower(m.name)'''),
    parameters: {
      'ids': [for (final d in deliveries) d['id']],
    },
  );
  final linesByDelivery = <int, List<Map<String, Object?>>>{};
  for (final row in lines.map((r) => r.toColumnMap())) {
    (linesByDelivery[row['delivery_id'] as int] ??= []).add({
      'materialId': row['material_id'],
      'name': row['name'],
      'unit': row['unit'],
      'quantity': quantityToJson(row['quantity']),
    });
  }
  return [
    for (final d in deliveries)
      deliveryJson(d, linesByDelivery[d['id']] ?? const [], side),
  ];
}

Map<String, Object?> deliveryJson(
  Map<String, dynamic> row,
  List<Map<String, Object?>> lines,
  StoreSide side,
) {
  final direction = row['direction'] as String;
  final status = row['status'] as String;
  final incoming = side == StoreSide.company
      ? direction == 'to_company'
      : direction == 'to_project';
  Map<String, Object?>? person(String id, String name) =>
      row[id] == null ? null : {'id': row[id], 'name': row[name]};
  String? time(String column) =>
      row[column] == null ? null : formatTimestamp(row[column] as DateTime);
  return {
    'id': row['id'],
    'project': {
      'id': projectCode(row['project_id'] as int),
      'name': row['project_name'],
    },
    'direction': direction,
    // Relative to the store whose screen this is.
    'flow': incoming ? 'incoming' : 'outgoing',
    'status': status,
    'lines': lines,
    'note': row['note'],
    'sentAt': time('sent_at'),
    'sentBy': person('sent_by', 'sent_by_name'),
    'receivedAt': status == 'delivered' ? time('closed_at') : null,
    'receivedBy': status == 'delivered'
        ? person('closed_by', 'closed_by_name')
        : null,
    'closedAt': time('closed_at'),
    'closedBy': person('closed_by', 'closed_by_name'),
    'actions': status != 'in_transit'
        ? <String>[]
        : incoming
        ? ['record', 'reject']
        : ['cancel'],
  };
}
