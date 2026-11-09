import 'dart:io';

/// Runtime settings, read once from the environment at startup.
class Config {
  Config({
    required this.port,
    required this.databaseUrl,
    required this.dbPoolSize,
    required this.migrationsDir,
  });

  factory Config.fromEnvironment([Map<String, String>? environment]) {
    final env = environment ?? Platform.environment;
    return Config(
      port: _int(env, 'PORT', 8080),
      databaseUrl:
          env['DATABASE_URL'] ??
          'postgres://sitetrack:sitetrack@localhost:5432/sitetrack?sslmode=disable',
      dbPoolSize: _int(env, 'DB_POOL_SIZE', 10),
      migrationsDir: env['MIGRATIONS_DIR'] ?? 'migrations',
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

  static int _int(Map<String, String> env, String name, int fallback) {
    final raw = env[name];
    if (raw == null || raw.isEmpty) return fallback;
    final value = int.tryParse(raw);
    if (value == null || value <= 0) {
      throw FormatException('$name must be a positive integer, got "$raw"');
    }
    return value;
  }
}
