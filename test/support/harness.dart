import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:sitetrack/src/app.dart';
import 'package:sitetrack/src/config.dart';
import 'package:sitetrack/src/db/database.dart';
import 'package:sitetrack/src/db/migrator.dart';
import 'package:test/test.dart';

/// Where tests find a Postgres server they may create databases on. Defaults
/// to the throwaway container described in the README (see "Tests").
final _serverUrl =
    Platform.environment['TEST_DATABASE_URL'] ??
    'postgres://sitetrack:sitetrack@127.0.0.1:55432/postgres?sslmode=disable';

/// A response from the in-process API.
class ApiResponse {
  ApiResponse(this.status, this.text, this.headers);

  final int status;
  final String text;
  final Map<String, String> headers;

  Object? get json => text.isEmpty ? null : jsonDecode(text);

  Map<String, Object?> get body => json! as Map<String, Object?>;

  List<Object?> get items => body['items']! as List<Object?>;

  String? get errorCode =>
      ((json as Map?)?['error'] as Map?)?['code'] as String?;

  @override
  String toString() => '$status $text';
}

/// A signed-in test user.
class TestUser {
  TestUser(this.id, this.email, this.accessToken, this.refreshToken);

  final int id;
  final String email;
  String accessToken;
  String refreshToken;
}

/// A fresh, migrated database plus the API handler bound to it.
///
/// Each test file gets its own database, so files can run in parallel.
class TestApi {
  TestApi._(this._admin, this.databaseName, this.db, this._handler);

  final Connection _admin;
  final String databaseName;
  final Database db;
  final Handler _handler;
  var _userCounter = 0;

  static Future<TestApi> start() async {
    final serverUri = Uri.parse(_serverUrl);
    final admin = await Connection.open(
      Endpoint(
        host: serverUri.host,
        port: serverUri.port,
        database: 'postgres',
        username: serverUri.userInfo.split(':').first,
        password: serverUri.userInfo.split(':').last,
      ),
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    final name =
        'sitetrack_test_${DateTime.now().millisecondsSinceEpoch}_'
        '${Random().nextInt(1 << 32)}';
    await admin.execute('CREATE DATABASE $name');

    final url = serverUri.replace(path: '/$name').toString();
    final config = Config.fromEnvironment({
      'DATABASE_URL': url,
      'BCRYPT_COST': '4',
      'DB_POOL_SIZE': '20',
      'LOG_REQUESTS': 'false',
    });
    final db = Database.open(url, maxConnections: config.dbPoolSize);
    await Migrator(db, Directory('migrations')).migrate();
    return TestApi._(admin, name, db, buildApp(db, config));
  }

  Future<void> stop() async {
    await db.close();
    await _admin.execute('DROP DATABASE IF EXISTS $databaseName WITH (FORCE)');
    await _admin.close();
  }

  Future<ApiResponse> call(
    String method,
    String path, {
    Object? body,
    String? token,
    TestUser? as,
    Map<String, String>? headers,
  }) async {
    final bearer = token ?? as?.accessToken;
    final request = Request(
      method,
      Uri.parse('http://localhost$path'),
      body: body == null ? null : jsonEncode(body),
      headers: {
        if (body != null) 'content-type': 'application/json',
        if (bearer != null) 'authorization': 'Bearer $bearer',
        ...?headers,
      },
    );
    final response = await _handler(request);
    return ApiResponse(
      response.statusCode,
      await response.readAsString(),
      response.headers,
    );
  }

  Future<ApiResponse> get(String path, {TestUser? as, String? token}) =>
      call('GET', path, as: as, token: token);

  Future<ApiResponse> post(
    String path, {
    Object? body,
    TestUser? as,
    String? token,
  }) => call('POST', path, body: body ?? const {}, as: as, token: token);

  Future<ApiResponse> patch(String path, {Object? body, TestUser? as}) =>
      call('PATCH', path, body: body ?? const {}, as: as);

  Future<ApiResponse> put(String path, {Object? body, TestUser? as}) =>
      call('PUT', path, body: body ?? const {}, as: as);

  Future<ApiResponse> delete(String path, {TestUser? as}) =>
      call('DELETE', path, as: as);

  /// Registers a new user with [role] and returns them signed in.
  Future<TestUser> user({String role = 'user', String? name}) async {
    final n = ++_userCounter;
    final email = 'user$n-${Random().nextInt(1 << 30)}@example.com';
    final response = await post(
      '/v1/auth/register',
      body: {
        'name': name ?? 'User $n',
        'email': email,
        'password': 'password-$n',
        'appRole': role,
      },
    );
    expect(response.status, 201, reason: '$response');
    final body = response.body;
    return TestUser(
      (body['user']! as Map)['id']! as int,
      email,
      body['accessToken']! as String,
      body['refreshToken']! as String,
    );
  }
}

/// Starts a [TestApi] for the enclosing test file and tears it down after.
TestApi Function() useTestApi() {
  late TestApi api;
  setUpAll(() async => api = await TestApi.start());
  tearDownAll(() async => api.stop());
  return () => api;
}
