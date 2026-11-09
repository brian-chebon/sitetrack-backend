import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

import '../auth/caller.dart';
import '../db/database.dart';
import '../http/api_error.dart';
import '../http/json.dart';
import '../http/validation.dart';
import '../ids.dart';

/// The notifications screen: the caller's project invitations, newest first.
///
/// "Unread" means pending and not yet seen. Opening the screen should call
/// `POST /v1/notifications/read`; answering an invitation marks it read too.
/// An invitation withdrawn before it was seen stops counting, since there is
/// nothing left to act on. Invitations to removed projects are hidden.
class NotificationRoutes {
  NotificationRoutes(this._db);

  final Database _db;

  static const _unreadSql = '''
    SELECT count(*)::int
      FROM project_invitations i
      JOIN projects p ON p.id = i.project_id AND p.deleted_at IS NULL
     WHERE i.invitee_id = @userId AND i.status = 'pending' AND i.read_at IS NULL''';

  /// `GET /v1/notifications?status=pending&limit=&offset=`
  Future<Response> list(Request request) async {
    final caller = callerOf(request);
    final query = QueryReader(request.url.queryParameters);
    final statuses = query.choices('status', {
      for (final s in ['pending', 'accepted', 'rejected', 'withdrawn']) s: s,
    });
    final page = query.page(defaultLimit: 20);
    query.throwIfInvalid();

    final rows = await _db.query(
      '''
      SELECT i.id, i.status, i.created_at, i.closed_at, i.read_at,
             p.id AS project_id, p.name AS project_name,
             i.invited_by, inviter.name AS invited_by_name,
             count(*) OVER () AS total
        FROM project_invitations i
        JOIN projects p ON p.id = i.project_id AND p.deleted_at IS NULL
        JOIN users inviter ON inviter.id = i.invited_by
       WHERE i.invitee_id = @userId
         AND (@statuses::text[] IS NULL OR i.status = ANY(@statuses::text[]))
       ORDER BY i.created_at DESC, i.id DESC
       LIMIT @limit OFFSET @offset''',
      {
        'userId': caller.id,
        'statuses': statuses,
        'limit': page.limit,
        'offset': page.offset,
      },
    );
    final unread = await _db.query(_unreadSql, {'userId': caller.id});
    return jsonResponse(
      pageJson(
        rows.map((r) => _notificationJson(r.toColumnMap())).toList(),
        total: rows.isEmpty ? 0 : rows.first.toColumnMap()['total'] as int,
        limit: page.limit,
        offset: page.offset,
        extra: {'unreadCount': unread.single[0]},
      ),
    );
  }

  /// `GET /v1/notifications/unread-count`: for the badge on every page.
  Future<Response> unreadCount(Request request) async {
    final caller = callerOf(request);
    final unread = await _db.query(_unreadSql, {'userId': caller.id});
    return jsonResponse({'unreadCount': unread.single[0]});
  }

  /// `POST /v1/notifications/read`, optionally with ids: marks the caller's
  /// notifications (or just those) read.
  Future<Response> markRead(Request request) async {
    final caller = callerOf(request);
    final text = await request.readAsString();
    List<int>? ids;
    if (text.trim().isNotEmpty) {
      final body = BodyReader(await readJsonObject(request.change(body: text)));
      if (body.has('ids')) {
        final raw = body.list('ids', maxLength: 200);
        ids = raw.whereType<int>().toList();
        if (ids.length != raw.length) body.error('ids', 'must be integers');
      }
      body.throwIfInvalid();
    }
    await _db.query(
      '''
      UPDATE project_invitations SET read_at = now()
       WHERE invitee_id = @userId AND read_at IS NULL
         AND (@ids::bigint[] IS NULL OR id = ANY(@ids::bigint[]))''',
      {'userId': caller.id, 'ids': ids},
    );
    final unread = await _db.query(_unreadSql, {'userId': caller.id});
    return jsonResponse({'unreadCount': unread.single[0]});
  }

  /// `POST /v1/invitations/{invitationId}/accept`: only the invitee; they
  /// join the project as a member.
  Future<Response> accept(Request request, String invitationId) =>
      _answer(request, invitationId, accept: true);

  /// `POST /v1/invitations/{invitationId}/reject`: only the invitee.
  Future<Response> reject(Request request, String invitationId) =>
      _answer(request, invitationId, accept: false);

  Future<Response> _answer(
    Request request,
    String invitationId, {
    required bool accept,
  }) async {
    final caller = callerOf(request);
    final id = int.tryParse(invitationId);
    // Someone else's invitation is a 404, like one that does not exist.
    ApiError notFound() => ApiError.notFound('No such invitation');
    if (id == null) throw notFound();

    final row = await _db.transaction((tx) async {
      final found = await tx.execute(
        Sql.named('''
          SELECT project_id FROM project_invitations
           WHERE id = @id AND invitee_id = @userId'''),
        parameters: {'id': id, 'userId': caller.id},
      );
      if (found.isEmpty) throw notFound();
      final projectId = found.single[0]! as int;
      // Joining changes the member list, so take the same project lock as
      // every other membership change.
      final project = await tx.execute(
        Sql.named('''
          SELECT id FROM projects
           WHERE id = @projectId AND deleted_at IS NULL FOR NO KEY UPDATE'''),
        parameters: {'projectId': projectId},
      );
      if (project.isEmpty) throw notFound();

      final updated = await tx.execute(
        Sql.named('''
          UPDATE project_invitations
             SET status = @status, closed_at = now(), closed_by = @userId,
                 read_at = coalesce(read_at, now())
           WHERE id = @id AND status = 'pending'
          RETURNING id'''),
        parameters: {
          'id': id,
          'userId': caller.id,
          'status': accept ? 'accepted' : 'rejected',
        },
      );
      if (updated.isEmpty) {
        throw ApiError.conflict(
          'invitation_closed',
          'This invitation has already been answered or withdrawn',
        );
      }
      if (accept) {
        await tx.execute(
          Sql.named('''
            INSERT INTO project_members (project_id, user_id)
            VALUES (@projectId, @userId) ON CONFLICT DO NOTHING'''),
          parameters: {'projectId': projectId, 'userId': caller.id},
        );
        await tx.execute(
          Sql.named('SELECT refresh_project_member_count(@projectId)'),
          parameters: {'projectId': projectId},
        );
      }
      final rows = await tx.execute(
        Sql.named('''
          SELECT i.id, i.status, i.created_at, i.closed_at, i.read_at,
                 p.id AS project_id, p.name AS project_name,
                 i.invited_by, inviter.name AS invited_by_name
            FROM project_invitations i
            JOIN projects p ON p.id = i.project_id
            JOIN users inviter ON inviter.id = i.invited_by
           WHERE i.id = @id'''),
        parameters: {'id': id},
      );
      return rows.single.toColumnMap();
    });
    return jsonResponse(_notificationJson(row));
  }

  static Map<String, Object?> _notificationJson(Map<String, dynamic> row) {
    final status = row['status'] as String;
    return {
      'id': row['id'],
      'type': 'project_invitation',
      'status': status,
      'read': row['read_at'] != null,
      'createdAt': formatTimestamp(row['created_at'] as DateTime),
      'answeredAt': row['closed_at'] == null
          ? null
          : formatTimestamp(row['closed_at'] as DateTime),
      'project': {
        'id': projectCode(row['project_id'] as int),
        'name': row['project_name'],
      },
      'invitedBy': {'id': row['invited_by'], 'name': row['invited_by_name']},
      'actions': status == 'pending' ? ['accept', 'reject'] : <String>[],
    };
  }
}
