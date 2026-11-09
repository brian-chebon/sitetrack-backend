import 'dart:io';
import 'dart:typed_data';

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

/// Lets a browser frontend on another origin call the API. Tokens travel in
/// the Authorization header, not cookies, so allowing any origin does not
/// expose anyone to cross-site request forgery.
Middleware cors() {
  const headers = {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET, POST, PUT, PATCH, DELETE, OPTIONS',
    'access-control-allow-headers': 'authorization, content-type',
    'access-control-max-age': '86400',
  };
  return (inner) => (request) async {
    if (request.method == 'OPTIONS') return Response(204, headers: headers);
    final response = await inner(request);
    return response.change(headers: headers);
  };
}

/// Gzips JSON bodies of 8 KB or more for clients that accept it. Task details
/// in the largest projects list ~2,500 related tasks (~430 KB), which
/// compress about tenfold. (dart:io's autoCompress does not apply here,
/// because shelf sets a content length.)
Middleware gzipLargeResponses() =>
    (inner) => (request) async {
      final response = await inner(request);
      final accepts =
          request.headers['accept-encoding']?.contains('gzip') ?? false;
      final length = response.contentLength;
      if (!accepts ||
          length == null ||
          length < 8192 ||
          response.headers.containsKey('content-encoding')) {
        return response;
      }
      final bytes = BytesBuilder(copy: false);
      await response.read().forEach(bytes.add);
      final compressed = gzip.encode(bytes.takeBytes());
      return response.change(
        body: compressed,
        headers: {
          'content-encoding': 'gzip',
          'content-length': '${compressed.length}',
          'vary': 'accept-encoding',
        },
      );
    };
