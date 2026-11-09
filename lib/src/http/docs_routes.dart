import 'dart:io';

import 'package:shelf/shelf.dart';

import 'api_error.dart';
import 'json.dart';

/// Serves the OpenAPI description and a Redoc page that renders it.
class DocsRoutes {
  DocsRoutes(String specPath) : _spec = _read(specPath);

  final String? _spec;

  static String? _read(String path) {
    final file = File(path);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  /// `GET /openapi.yaml`
  Response spec(Request request) {
    final spec = _spec;
    if (spec == null) {
      return jsonResponse(
        ApiError.notFound('API description not bundled').toJson(),
        status: 404,
      );
    }
    return Response.ok(
      spec,
      headers: {'content-type': 'application/yaml; charset=utf-8'},
    );
  }

  /// `GET /docs`
  Response page(Request request) =>
      Response.ok(_page, headers: {'content-type': 'text/html; charset=utf-8'});

  static const _page = '''
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SiteTrack API</title>
  <style>body { margin: 0; }</style>
</head>
<body>
  <redoc spec-url="/openapi.yaml"></redoc>
  <script src="https://cdn.jsdelivr.net/npm/redoc@2.5.4/bundles/redoc.standalone.js"></script>
</body>
</html>
''';
}
