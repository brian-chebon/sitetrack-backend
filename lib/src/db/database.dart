import 'dart:async';
import 'dart:io';

import 'package:postgres/postgres.dart';

/// The API's connection pool, plus the few helpers every repository uses.
///
/// Queries use named parameters (`@name`) through [Sql.named], so values are
/// always sent separately from the SQL text.
class Database {
  Database._(this.pool);

  /// Opens a pool for [url] holding at most [maxConnections] connections.
  ///
  /// Connections are opened lazily; call [waitUntilReady] to block until the
  /// server accepts them.
  factory Database.open(String url, {required int maxConnections}) {
    // Pool.withUrl cannot set a query timeout, so the URL is parsed here.
    final uri = Uri.parse(url);
    if (uri.scheme != 'postgres' && uri.scheme != 'postgresql') {
      throw FormatException('DATABASE_URL must start with postgres://');
    }
    final userInfo = uri.userInfo.split(':');
    final endpoint = Endpoint(
      host: uri.host,
      port: uri.hasPort ? uri.port : 5432,
      database: uri.pathSegments.isEmpty ? 'postgres' : uri.pathSegments.first,
      username: userInfo.isEmpty ? null : Uri.decodeComponent(userInfo.first),
      password: userInfo.length < 2 ? null : Uri.decodeComponent(userInfo[1]),
    );
    final sslMode = switch (uri.queryParameters['sslmode']) {
      'disable' => SslMode.disable,
      'verify-full' => SslMode.verifyFull,
      _ => SslMode.require,
    };
    return Database._(
      Pool<void>.withEndpoints(
        [endpoint],
        settings: PoolSettings(
          maxConnectionCount: maxConnections,
          sslMode: sslMode,
          applicationName: 'sitetrack-api',
          connectTimeout: const Duration(seconds: 5),
          // Every request is a handful of indexed queries; anything slower
          // than this is a bug, not a workload.
          queryTimeout: const Duration(seconds: 30),
        ),
      ),
    );
  }

  final Pool<void> pool;

  /// Runs one statement outside a transaction.
  Future<Result> query(String sql, [Map<String, Object?>? parameters]) =>
      pool.execute(Sql.named(sql), parameters: parameters);

  /// Runs [fn] in a transaction that commits when [fn] completes and rolls
  /// back when it throws.
  Future<R> transaction<R>(Future<R> Function(TxSession tx) fn) =>
      pool.runTx(fn);

  /// Retries a trivial query until the database answers, so the API can start
  /// before Postgres has finished booting.
  Future<void> waitUntilReady({
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      try {
        await pool.execute('SELECT 1');
        return;
      } on Object catch (error) {
        if (DateTime.now().isAfter(deadline)) rethrow;
        stderr.writeln('Database not ready yet ($error); retrying');
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  Future<void> close() => pool.close();
}
