import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

import '../auth/auth_service.dart';
import '../auth/caller.dart';
import '../db/database.dart';
import '../http/api_error.dart';
import '../http/json.dart';
import '../http/validation.dart';
import 'visible_users.dart';

/// The caller's profile, the people directory used to pick invitees, and
/// app role changes.
class UserRoutes {
  UserRoutes(this._db);

  final Database _db;

  /// `GET /v1/me`: the caller's profile and unread notification count, so a
  /// frontend gets the header badge with the same call it needs anyway.
  Future<Response> me(Request request) async {
    final caller = callerOf(request);
    final rows = await _db.query(
      '''
      SELECT u.id, u.name, u.email, u.app_role, u.created_at,
             (SELECT count(*)::int
                FROM project_invitations i
                JOIN projects p ON p.id = i.project_id AND p.deleted_at IS NULL
               WHERE i.invitee_id = u.id
                 AND i.status = 'pending'
                 AND i.read_at IS NULL) AS unread
        FROM users u
       WHERE u.id = @id''',
      {'id': caller.id},
    );
    final row = rows.single.toColumnMap();
    return jsonResponse({
      ...UserProfile.fromRow(row).toJson(),
      'unreadNotifications': row['unread'],
    });
  }

  /// `GET /v1/users?search=`: people to invite, by name or email.
  ///
  /// It searches the caller and the people they share a project with
  /// ([visibleUserSql]); SuperAdmins search everyone. A search that is a
  /// whole email address also finds that one person, so anyone registered
  /// can still be invited. It shows names and emails only.
  Future<Response> search(Request request) async {
    final caller = callerOf(request);
    final query = QueryReader(request.url.queryParameters);
    final search = query.search();
    final page = query.page(defaultLimit: 20);
    query.throwIfInvalid();

    final exactEmail = search != null && search.contains('@')
        ? AuthService.normalizeEmail(search)
        : null;
    final rows = await _db.query(
      '''
      SELECT u.id, u.name, u.email, count(*) OVER () AS total
        FROM users u
       WHERE (${visibleUserSql('u.id')} OR u.email = @exactEmail::text)
         AND (@search::text IS NULL
              OR u.name ILIKE '%' || @search || '%'
              OR u.email ILIKE '%' || @search || '%')
       ORDER BY u.name, u.id
       LIMIT @limit OFFSET @offset''',
      {
        'callerId': caller.id,
        'superAdmin': caller.isSuperAdmin,
        'exactEmail': exactEmail,
        'search': search,
        'limit': page.limit,
        'offset': page.offset,
      },
    );
    final items = [
      for (final row in rows.map((r) => r.toColumnMap()))
        {'id': row['id'], 'name': row['name'], 'email': row['email']},
    ];
    return jsonResponse(
      pageJson(
        items,
        total: rows.isEmpty ? 0 : rows.first.toColumnMap()['total'] as int,
        limit: page.limit,
        offset: page.offset,
      ),
    );
  }

  /// `PATCH /v1/users/{userId}/role` with appRole: SuperAdmins only.
  ///
  /// The new role applies on the person's very next request, because the role
  /// is read from the database on every request, never from the token.
  Future<Response> changeRole(Request request, String userId) async {
    final caller = callerOf(request);
    if (!caller.isSuperAdmin) {
      throw ApiError.forbidden('Only SuperAdmins can change app roles');
    }
    final id = int.tryParse(userId);
    if (id == null) throw ApiError.notFound('No such user');
    final body = BodyReader(await readJsonObject(request));
    final role = body.choice(
      'appRole',
      AppRole.byValue,
      fallback: AppRole.user,
    );
    body.throwIfInvalid();

    final row = await _db.transaction((tx) async {
      // Serialise role changes so two SuperAdmins demoting each other cannot
      // leave the company without one.
      await tx.execute("SELECT pg_advisory_xact_lock(hashtext('app_roles'))");
      final rows = await tx.execute(
        Sql.named('''
          SELECT app_role,
                 (SELECT count(*)::int FROM users WHERE app_role = 'super_admin')
                   AS super_admins
            FROM users WHERE id = @id'''),
        parameters: {'id': id},
      );
      if (rows.isEmpty) throw ApiError.notFound('No such user');
      final current = rows.single.toColumnMap();
      if (current['app_role'] == AppRole.superAdmin.value &&
          role != AppRole.superAdmin &&
          current['super_admins'] == 1) {
        throw ApiError.conflict(
          'last_super_admin',
          'This is the only SuperAdmin; make someone else SuperAdmin first',
        );
      }
      final updated = await tx.execute(
        Sql.named('''
          UPDATE users SET app_role = @role, updated_at = now()
           WHERE id = @id
          RETURNING id, name, email, app_role, created_at'''),
        parameters: {'id': id, 'role': role.value},
      );
      return updated.single.toColumnMap();
    });
    return jsonResponse(UserProfile.fromRow(row).toJson());
  }
}
