import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:sitetrack/src/app.dart';
import 'package:sitetrack/src/config.dart';
import 'package:sitetrack/src/db/database.dart';
import 'package:sitetrack/src/db/migrator.dart';

/// Starts the API: waits for Postgres, applies pending migrations, serves.
///
/// `server healthcheck` instead probes a running server's /health and exits 0
/// when it answers, for the container health check (the image has no curl).
Future<void> main(List<String> args) async {
  final config = Config.fromEnvironment();
  if (args.firstOrNull == 'healthcheck') {
    exit(await _healthcheck(config.port));
  }

  final db = Database.open(
    config.databaseUrl,
    maxConnections: config.dbPoolSize,
  );
  await db.waitUntilReady();

  final applied = await Migrator(db, Directory(config.migrationsDir)).migrate();
  stdout.writeln(
    applied.isEmpty
        ? 'Schema is up to date'
        : 'Applied migrations: ${applied.join(', ')}',
  );

  final server = await shelf_io.serve(
    buildApp(db),
    InternetAddress.anyIPv4,
    config.port,
  );
  server.autoCompress = true;
  stdout.writeln('SiteTrack API listening on port ${server.port}');

  // Docker sends SIGTERM on `docker compose down`; finish in-flight requests
  // and close the pool instead of dropping connections.
  late final StreamSubscription<ProcessSignal> sigterm;
  late final StreamSubscription<ProcessSignal> sigint;
  Future<void> shutdown(ProcessSignal signal) async {
    stdout.writeln('Received $signal, shutting down');
    await sigterm.cancel();
    await sigint.cancel();
    await server.close();
    await db.close();
  }

  sigterm = ProcessSignal.sigterm.watch().listen(shutdown);
  sigint = ProcessSignal.sigint.watch().listen(shutdown);
}

Future<int> _healthcheck(int port) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final request = await client.get('127.0.0.1', port, '/health');
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode == HttpStatus.ok ? 0 : 1;
  } on Object {
    return 1;
  } finally {
    client.close(force: true);
  }
}
