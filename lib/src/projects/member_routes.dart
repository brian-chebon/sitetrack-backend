import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

import '../auth/auth_service.dart';
import '../auth/caller.dart';
import '../db/database.dart';
import '../http/api_error.dart';
import '../http/json.dart';
import '../http/validation.dart';
import '../users/visible_users.dart';
import 'project_access.dart';

/// The project members screen: members, unanswered invitations, and the
/// admin actions on them.
///
/// Every change runs under the project row lock (ProjectLock.update), so the
/// "at least one admin" check cannot be raced: two admins demoting each other
/// at the same moment are serialised, and the second is refused.
class MemberRoutes {
  MemberRoutes(this._db);

  final Database _db;

  /// `GET /v1/projects/{projectId}/members`
  Future<Response> list(Request request, String projectId) async {
    final caller = callerOf(request);
    final access = await loadProject(_db.pool, caller, projectId);
    final members = await _db.query(
      '''
      SELECT m.user_id, u.name, u.email, m.is_admin, m.joined_at
        FROM project_members m
        JOIN users u ON u.id = m.user_id
       WHERE m.project_id = @id
       ORDER BY m.is_admin DESC, lower(u.name), u.id''',
      {'id': access.id},
    );
    final invitations = await _db.query(
      '''
      SELECT i.id, i.invitee_id, u.name, u.email, i.created_at,
             i.invited_by, inviter.name AS invited_by_name
        FROM project_invitations i
        JOIN users u ON u.id = i.invitee_id
        JOIN users inviter ON inviter.id = i.invited_by
       WHERE i.project_id = @id AND i.status = 'pending'
       ORDER BY i.created_at DESC, i.id DESC''',
      {'id': access.id},
    );
    return jsonResponse({
      'projectId': access.code,
      'canManage': access.isAdmin,
      'members': [
        for (final row in members.map((r) => r.toColumnMap()))
          {
            'userId': row['user_id'],
            'name': row['name'],
            'email': row['email'],
            'isAdmin': row['is_admin'],
            'joinedAt': formatTimestamp(row['joined_at'] as DateTime),
          },
      ],
      'pendingInvitations': [
        for (final row in invitations.map((r) => r.toColumnMap()))
          {
            'id': row['id'],
            'userId': row['invitee_id'],
            'name': row['name'],
            'email': row['email'],
            'invitedBy': {
              'id': row['invited_by'],
              'name': row['invited_by_name'],
            },
            'createdAt': formatTimestamp(row['created_at'] as DateTime),
          },
      ],
    });
  }

  /// `POST /v1/projects/{projectId}/invitations` with userId or email.
  /// Project admins only.
  ///
  /// A userId only finds someone the admin may already look up
  /// ([visibleUserSql]); anyone else is invited by email. Otherwise inviting
  /// IDs one after another would reveal every registered email.
  Future<Response> invite(Request request, String projectId) async {
    final caller = callerOf(request);
    final body = BodyReader(await readJsonObject(request));
    final userId = body.has('userId') ? body.integer('userId') : null;
    final email = body.optionalString('email', maxLength: 320);
    if (userId == null && email == null) {
      body.error('userId', 'give userId or email');
    }
    body.throwIfInvalid();

    final invitation = await _db.transaction((tx) async {
      final access = await loadProject(
        tx,
        caller,
        projectId,
        lock: ProjectLock.update,
      );
      access.requireAdmin();
      final invitees = await tx.execute(
        Sql.named('''
          SELECT u.id, u.name, u.email,
                 EXISTS (SELECT 1 FROM project_members m
                          WHERE m.project_id = @projectId AND m.user_id = u.id) AS is_member,
                 EXISTS (SELECT 1 FROM project_invitations i
                          WHERE i.project_id = @projectId AND i.invitee_id = u.id
                            AND i.status = 'pending') AS is_invited
            FROM users u
           WHERE (u.id = @userId::bigint AND ${visibleUserSql('u.id')})
              OR u.email = @email::text'''),
        parameters: {
          'projectId': access.id,
          'callerId': caller.id,
          'superAdmin': caller.isSuperAdmin,
          'userId': userId,
          'email': email == null ? null : AuthService.normalizeEmail(email),
        },
      );
      if (invitees.isEmpty) {
        throw ApiError.badRequest(
          'No registered user matches',
          details: {
            'fields': {userId != null ? 'userId' : 'email': 'no such user'},
          },
        );
      }
      final invitee = invitees.first.toColumnMap();
      if (invitee['is_member'] as bool) {
        throw ApiError.conflict(
          'already_member',
          '${invitee['name']} is already a member of this project',
        );
      }
      if (invitee['is_invited'] as bool) {
        throw ApiError.conflict(
          'already_invited',
          '${invitee['name']} already has an unanswered invitation',
        );
      }
      final inserted = await tx.execute(
        Sql.named('''
          INSERT INTO project_invitations (project_id, invitee_id, invited_by)
          VALUES (@projectId, @inviteeId, @userId)
          RETURNING id, created_at'''),
        parameters: {
          'projectId': access.id,
          'inviteeId': invitee['id'],
          'userId': caller.id,
        },
      );
      final row = inserted.single.toColumnMap();
      return {
        'id': row['id'],
        'userId': invitee['id'],
        'name': invitee['name'],
        'email': invitee['email'],
        'invitedBy': {'id': caller.id, 'name': caller.name},
        'createdAt': formatTimestamp(row['created_at'] as DateTime),
      };
    });
    return jsonResponse(invitation, status: 201);
  }

  /// `DELETE /v1/projects/{projectId}/invitations/{invitationId}`: withdraws
  /// an unanswered invitation. Project admins only.
  Future<Response> withdraw(
    Request request,
    String projectId,
    String invitationId,
  ) async {
    final caller = callerOf(request);
    final id = int.tryParse(invitationId);
    await _db.transaction((tx) async {
      final access = await loadProject(
        tx,
        caller,
        projectId,
        lock: ProjectLock.update,
      );
      access.requireAdmin();
      if (id == null) throw ApiError.notFound('No such invitation');
      final rows = await tx.execute(
        Sql.named('''
          SELECT status FROM project_invitations
           WHERE id = @id AND project_id = @projectId FOR UPDATE'''),
        parameters: {'id': id, 'projectId': access.id},
      );
      if (rows.isEmpty) throw ApiError.notFound('No such invitation');
      if (rows.single[0] != 'pending') {
        throw ApiError.conflict(
          'invitation_closed',
          'This invitation has already been ${rows.single[0]}',
        );
      }
      await tx.execute(
        Sql.named('''
          UPDATE project_invitations
             SET status = 'withdrawn', closed_at = now(), closed_by = @userId
           WHERE id = @id'''),
        parameters: {'id': id, 'userId': caller.id},
      );
    });
    return Response(204);
  }

  /// `PATCH /v1/projects/{projectId}/members/{userId}` with isAdmin.
  /// Project admins only; the last admin cannot be demoted.
  Future<Response> update(
    Request request,
    String projectId,
    String userId,
  ) async {
    final caller = callerOf(request);
    final body = BodyReader(await readJsonObject(request));
    final isAdmin = body.boolean('isAdmin');
    body.throwIfInvalid();

    final member = await _db.transaction((tx) async {
      final access = await loadProject(
        tx,
        caller,
        projectId,
        lock: ProjectLock.update,
      );
      access.requireAdmin();
      final target = await _member(tx, access.id, userId);
      if (!isAdmin && target.isAdmin) await _ensureAnotherAdmin(tx, access.id);
      final rows = await tx.execute(
        Sql.named('''
          UPDATE project_members m SET is_admin = @isAdmin
            FROM users u
           WHERE m.project_id = @projectId AND m.user_id = @userId AND u.id = m.user_id
          RETURNING m.user_id, u.name, u.email, m.is_admin, m.joined_at'''),
        parameters: {
          'projectId': access.id,
          'userId': target.userId,
          'isAdmin': isAdmin,
        },
      );
      final row = rows.single.toColumnMap();
      return {
        'userId': row['user_id'],
        'name': row['name'],
        'email': row['email'],
        'isAdmin': row['is_admin'],
        'joinedAt': formatTimestamp(row['joined_at'] as DateTime),
      };
    });
    return jsonResponse(member);
  }

  /// `DELETE /v1/projects/{projectId}/members/{userId}`: project admins remove
  /// members, and any member may leave. The last admin can do neither. The
  /// removed person loses access on their very next request, because
  /// membership is checked on every request.
  Future<Response> remove(
    Request request,
    String projectId,
    String userId,
  ) async {
    final caller = callerOf(request);
    await _db.transaction((tx) async {
      final access = await loadProject(
        tx,
        caller,
        projectId,
        lock: ProjectLock.update,
      );
      final target = await _member(tx, access.id, userId);
      if (target.userId != caller.id) access.requireAdmin();
      if (target.isAdmin) await _ensureAnotherAdmin(tx, access.id);
      await tx.execute(
        Sql.named(
          '''
          DELETE FROM project_members WHERE project_id = @projectId AND user_id = @userId''',
        ),
        parameters: {'projectId': access.id, 'userId': target.userId},
      );
      await tx.execute(
        Sql.named('SELECT refresh_project_member_count(@projectId)'),
        parameters: {'projectId': access.id},
      );
    });
    return Response(204);
  }

  Future<({int userId, bool isAdmin})> _member(
    TxSession tx,
    int projectId,
    String userId,
  ) async {
    final id = int.tryParse(userId);
    final rows = id == null
        ? null
        : await tx.execute(
            Sql.named('''
              SELECT is_admin FROM project_members
               WHERE project_id = @projectId AND user_id = @userId'''),
            parameters: {'projectId': projectId, 'userId': id},
          );
    if (rows == null || rows.isEmpty) {
      throw ApiError.notFound('No such member in this project');
    }
    return (userId: id!, isAdmin: rows.single[0]! as bool);
  }

  Future<void> _ensureAnotherAdmin(TxSession tx, int projectId) async {
    final admins = await tx.execute(
      Sql.named('''
        SELECT count(*)::int FROM project_members
         WHERE project_id = @projectId AND is_admin'''),
      parameters: {'projectId': projectId},
    );
    if ((admins.single[0]! as int) <= 1) {
      throw ApiError.conflict(
        'last_admin',
        'A project must keep at least one admin; make another member admin first',
      );
    }
  }
}
