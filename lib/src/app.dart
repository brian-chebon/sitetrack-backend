import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth/auth_routes.dart';
import 'auth/auth_service.dart';
import 'auth/passwords.dart';
import 'auth/tokens.dart';
import 'config.dart';
import 'db/database.dart';
import 'http/api_error.dart';
import 'http/json.dart';
import 'http/middleware.dart';
import 'users/user_routes.dart';

/// Builds the API's request handler.
///
/// Everything under `/v1/` except register, login and refresh goes through
/// [authenticate], which resolves the caller from the database on every
/// request. Access to projects and stores is then checked by each handler.
Handler buildApp(Database db, Config config) {
  final passwords = PasswordHasher(cost: config.bcryptCost);
  final tokens = AccessTokens(config.jwtSecret, config.accessTokenTtl);
  final auth = AuthService(db, config, passwords, tokens);

  final authRoutes = AuthRoutes(auth);
  final users = UserRoutes(db);

  final protected = Router(notFoundHandler: _notFound)
    ..post('/auth/logout', authRoutes.logout)
    ..get('/me', users.me)
    ..get('/users', users.search)
    ..patch('/users/<userId>/role', users.changeRole);

  final root = Router(notFoundHandler: _notFound)
    ..get('/health', (Request request) async {
      await db.query('SELECT 1');
      return jsonResponse({'status': 'ok'});
    })
    ..post('/v1/auth/register', authRoutes.register)
    ..post('/v1/auth/login', authRoutes.login)
    ..post('/v1/auth/refresh', authRoutes.refresh)
    ..mount(
      '/v1/',
      const Pipeline()
          .addMiddleware(authenticate(auth))
          .addHandler(protected.call),
    );

  var pipeline = const Pipeline();
  if (config.logRequests) {
    pipeline = pipeline.addMiddleware(logRequestTimings());
  }
  return pipeline
      .addMiddleware(cors())
      .addMiddleware(handleErrors())
      .addHandler(root.call);
}

Response _notFound(Request request) =>
    jsonResponse(ApiError.notFound('No such endpoint').toJson(), status: 404);
