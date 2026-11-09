import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'db/database.dart';
import 'http/api_error.dart';
import 'http/json.dart';
import 'http/middleware.dart';

/// Builds the API's request handler.
Handler buildApp(Database db) {
  final router = Router(notFoundHandler: _notFound)
    ..get('/health', (Request request) async {
      await db.query('SELECT 1');
      return jsonResponse({'status': 'ok'});
    });

  return const Pipeline()
      .addMiddleware(logRequestTimings())
      .addMiddleware(handleErrors())
      .addHandler(router.call);
}

Response _notFound(Request request) =>
    jsonResponse(ApiError.notFound('No such endpoint').toJson(), status: 404);
