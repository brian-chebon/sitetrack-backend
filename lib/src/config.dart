import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Runtime settings, read once from the environment at startup.
class Config {
  Config({
    required this.port,
    required this.databaseUrl,
    required this.dbPoolSize,
    required this.migrationsDir,
    required this.docsPath,
    required this.jwtSecret,
    required this.jwtSecretGenerated,
    required this.bcryptCost,
    required this.timeZone,
    this.logRequests = true,
    this.accessTokenTtl = const Duration(minutes: 15),
    this.sessionIdleTimeout = const Duration(days: 7),
    this.sessionMaxAge = const Duration(days: 30),
  });

  factory Config.fromEnvironment([Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;
    final secret = env['JWT_SECRET'];
    if (secret != null && secret.isNotEmpty && secret.length < 32) {
      throw const FormatException('JWT_SECRET must be at least 32 characters');
    }
    final bcryptCost = _int(env, 'BCRYPT_COST', 10);
    if (bcryptCost < 4 || bcryptCost > 15) {
      throw const FormatException('BCRYPT_COST must be between 4 and 15');
    }
    return Config(
      port: _int(env, 'PORT', 8080),
      databaseUrl:
          env['DATABASE_URL'] ??
          'postgres://sitetrack:sitetrack@localhost:5432/sitetrack?sslmode=disable',
      dbPoolSize: _int(env, 'DB_POOL_SIZE', 10),
      migrationsDir: env['MIGRATIONS_DIR'] ?? 'migrations',
      docsPath: env['OPENAPI_PATH'] ?? 'docs/openapi.yaml',
      jwtSecret: (secret == null || secret.isEmpty) ? _randomSecret() : secret,
      jwtSecretGenerated: secret == null || secret.isEmpty,
      bcryptCost: bcryptCost,
      timeZone: env['APP_TIMEZONE'] ?? 'UTC',
      logRequests: env['LOG_REQUESTS'] != 'false',
    );
  }

  /// Port the HTTP server listens on.
  final int port;

  /// `postgres://user:password@host:port/database?sslmode=...`
  final String databaseUrl;

  /// Upper bound on open database connections held by the API.
  final int dbPoolSize;

  /// Directory holding the numbered `.sql` migration files.
  final String migrationsDir;

  /// The OpenAPI description served at /openapi.yaml and rendered at /docs.
  final String docsPath;

  /// HMAC key for access tokens. When JWT_SECRET is not set, a random key is
  /// made at startup: access tokens then stop verifying after a restart, and
  /// clients get new ones with their refresh token, which lives in the
  /// database and does not depend on this key.
  final String jwtSecret;
  final bool jwtSecretGenerated;

  /// bcrypt work factor. 10 takes about 200 ms in pure Dart; tests use 4.
  final int bcryptCost;

  /// IANA zone whose calendar decides "today" for Late tasks (APP_TIMEZONE).
  final String timeZone;

  /// One log line per request (LOG_REQUESTS=false turns it off).
  final bool logRequests;

  /// Access tokens are short-lived; clients refresh them silently.
  final Duration accessTokenTtl;

  /// A session not refreshed for this long ends; using the app extends it.
  final Duration sessionIdleTimeout;

  /// A session ends this long after login, however active.
  final Duration sessionMaxAge;

  static int _int(Map<String, String> env, String name, int fallback) {
    final raw = env[name];
    if (raw == null || raw.isEmpty) return fallback;
    final value = int.tryParse(raw);
    if (value == null || value <= 0) {
      throw FormatException('$name must be a positive integer, got "$raw"');
    }
    return value;
  }

  static String _randomSecret() {
    final random = Random.secure();
    return base64UrlEncode(List.generate(48, (_) => random.nextInt(256)));
  }
}
