/// SQL that is true when the user in [column] is someone the caller may look
/// up by name or user ID: the caller themselves, and everyone they share a
/// project with. SuperAdmins may look up everyone, since they assign app
/// roles.
///
/// Anyone else is reached only by their exact email, which an inviter who
/// knows the person already has. Without this, anyone could register, then
/// list every registered email by searching the directory or by inviting
/// user IDs one after another.
///
/// The query must bind `@callerId` and `@superAdmin`.
String visibleUserSql(String column) =>
    '''
  (@superAdmin::boolean
   OR $column = @callerId::bigint
   OR $column IN (SELECT theirs.user_id
                    FROM project_members mine
                    JOIN projects p ON p.id = mine.project_id AND p.deleted_at IS NULL
                    JOIN project_members theirs ON theirs.project_id = mine.project_id
                   WHERE mine.user_id = @callerId::bigint))''';
