import 'package:shelf/shelf.dart';

/// The three app roles. [value] is the form used in the API and database.
enum AppRole {
  user('user'),
  storeManager('store_manager'),
  superAdmin('super_admin');

  const AppRole(this.value);

  final String value;

  static final byValue = {for (final role in values) role.value: role};

  static AppRole parse(String value) =>
      byValue[value] ?? (throw StateError('Unknown app role "$value"'));
}

/// The signed-in person making the current request, loaded from the database
/// on every request, so a role change applies to their very next request.
class Caller {
  const Caller({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.sessionId,
  });

  final int id;
  final String name;
  final String email;
  final AppRole role;
  final String sessionId;

  bool get isSuperAdmin => role == AppRole.superAdmin;

  /// Company store managers and SuperAdmins reach the company store.
  bool get canUseCompanyStore =>
      role == AppRole.storeManager || role == AppRole.superAdmin;
}

const _callerKey = 'sitetrack.caller';

/// The [Caller] the authentication middleware attached to [request].
Caller callerOf(Request request) => request.context[_callerKey]! as Caller;

Request attachCaller(Request request, Caller caller) =>
    request.change(context: {_callerKey: caller});
