import 'package:postgres/postgres.dart';

import '../auth/caller.dart';
import '../http/api_error.dart';
import '../ids.dart';

/// How a transaction holds the project row while it works.
///
/// Every change to a project's tasks, dependencies or members takes
/// [update]; that serialises them per project, which is what keeps task
/// numbers, cycle checks, Blocked flags and the one-admin rule correct under
/// concurrent requests. Store and delivery changes take [share], so they run
/// alongside each other but never alongside deleting the project ([delete]).
/// Plain reads take no lock.
enum ProjectLock {
  none(''),
  share('FOR SHARE OF p'),
  update('FOR NO KEY UPDATE OF p'),
  delete('FOR UPDATE OF p');

  const ProjectLock(this.sql);

  final String sql;
}

/// A project the caller may see, and what they are in it.
class ProjectAccess {
  ProjectAccess(this.id, {required this.isMember, required this.isAdmin});

  final int id;
  final bool isMember;
  final bool isAdmin;

  String get code => projectCode(id);

  /// Only project admins change members, invitations, admin status and the
  /// project itself. The caller already knows the project exists, so this is
  /// a 403, not a 404.
  void requireAdmin() {
    if (!isAdmin) {
      throw ApiError.forbidden('Only project admins can do this');
    }
  }
}

ApiError projectNotFound() => ApiError.notFound('No such project');

/// Loads project [code] if [caller] may see it: a member, or any SuperAdmin.
///
/// Anything else, including a malformed ID, a removed project and a project
/// the caller is not in, is the same 404, so a response never confirms that
/// a project ID is real.
Future<ProjectAccess> loadProject(
  Session session,
  Caller caller,
  String code, {
  ProjectLock lock = ProjectLock.none,
}) async {
  final id = parseProjectCode(code);
  if (id == null) throw projectNotFound();
  return loadProjectById(session, caller, id, lock: lock);
}

Future<ProjectAccess> loadProjectById(
  Session session,
  Caller caller,
  int id, {
  ProjectLock lock = ProjectLock.none,
}) async {
  // The visibility test is part of the locking query, so someone who cannot
  // see the project cannot hold its lock either.
  final rows = await session.execute(
    Sql.named('''
      SELECT p.id, m.user_id IS NOT NULL AS is_member, coalesce(m.is_admin, false) AS is_admin
        FROM projects p
        LEFT JOIN project_members m ON m.project_id = p.id AND m.user_id = @userId
       WHERE p.id = @id
         AND p.deleted_at IS NULL
         AND (m.user_id IS NOT NULL OR @superAdmin::boolean)
       ${lock.sql}'''),
    parameters: {
      'id': id,
      'userId': caller.id,
      'superAdmin': caller.isSuperAdmin,
    },
  );
  if (rows.isEmpty) throw projectNotFound();
  final row = rows.single.toColumnMap();
  return ProjectAccess(
    id,
    isMember: row['is_member'] as bool,
    isAdmin: row['is_admin'] as bool,
  );
}
