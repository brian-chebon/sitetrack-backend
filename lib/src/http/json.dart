import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'api_error.dart';

const _jsonHeaders = {'content-type': 'application/json; charset=utf-8'};

/// A JSON response with [status] (200 by default).
Response jsonResponse(Object? body, {int status = 200}) =>
    Response(status, body: jsonEncode(body), headers: _jsonHeaders);

/// Reads the request body as a JSON object, or throws a 400.
Future<Map<String, Object?>> readJsonObject(Request request) async {
  final text = await request.readAsString();
  if (text.trim().isEmpty) {
    throw ApiError.badRequest('Request body must be a JSON object');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw ApiError.badRequest('Request body is not valid JSON');
  }
  if (decoded is! Map<String, Object?>) {
    throw ApiError.badRequest('Request body must be a JSON object');
  }
  return decoded;
}
