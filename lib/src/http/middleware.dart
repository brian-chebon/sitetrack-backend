import 'dart:io';

import 'package:shelf/shelf.dart';

import 'api_error.dart';
import 'json.dart';

/// Turns [ApiError]s into JSON error responses, and anything else into a
/// generic 500 that leaks no internals (the details go to the log).
Middleware handleErrors() =>
    (inner) => (request) async {
      try {
        return await inner(request);
      } on ApiError catch (error) {
        return jsonResponse(error.toJson(), status: error.status);
      } on Object catch (error, stackTrace) {
        stderr.writeln(
          'Unhandled error on ${request.method} ${request.requestedUri.path}: '
          '$error\n$stackTrace',
        );
        return jsonResponse(
          ApiError(500, 'internal', 'Something went wrong').toJson(),
          status: 500,
        );
      }
    };

/// One log line per request: method, path, status and duration.
Middleware logRequestTimings() =>
    (inner) => (request) async {
      final watch = Stopwatch()..start();
      final response = await inner(request);
      stdout.writeln(
        '${request.method} ${request.requestedUri.path} '
        '${response.statusCode} ${watch.elapsedMilliseconds}ms',
      );
      return response;
    };
