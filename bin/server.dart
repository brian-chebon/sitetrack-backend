import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:sitetrack/src/app.dart';
import 'package:sitetrack/src/config.dart';
import 'package:sitetrack/src/db/database.dart';
import 'package:sitetrack/src/db/migrator.dart';

/// Starts the API: waits for Postgres, applies pending migrations, serves.
Future<void> main() async {
  final config = Config.fromEnvironment();

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
