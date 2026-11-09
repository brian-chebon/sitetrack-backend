import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:sitetrack/src/auth/passwords.dart';
import 'package:sitetrack/src/config.dart';
import 'package:sitetrack/src/db/database.dart';
import 'package:sitetrack/src/db/migrator.dart';
import 'package:sitetrack/src/seed/seed_plan.dart';
import 'package:sitetrack/src/seed/seeder.dart';

const _usage = '''
Fills the database with a large, realistic company history.

  seed [--scale <factor>] [--reset]

  --scale   1 (default) loads the brief's test volumes: 5,000 users, 2,000
            projects, 50,000 invitations, 500,000 tasks, 1,000,000
            dependencies, 20,000 materials and 400,000 deliveries with
            3,000,000 lines. 0.1 loads a tenth, for a quick look.
  --reset   Wipe existing data first. Without it, the seeder refuses to run
            on a database that already has users.
''';

/// Every seeded account's password.
const demoPassword = 'sitetrack-demo';

Future<void> main(List<String> args) async {
  var scale = 1.0;
  var reset = false;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--scale' when i + 1 < args.length:
        scale = double.tryParse(args[++i]) ?? -1;
      case '--reset':
        reset = true;
      case '--help' || '-h':
        stdout.write(_usage);
        return;
      default:
        stderr.write('Unknown argument ${args[i]}\n\n$_usage');
        exit(64);
    }
  }
  if (scale <= 0 || scale > 10) {
    stderr.writeln('--scale must be a number above 0 and at most 10');
    exit(64);
  }

  final config = Config.fromEnvironment();
  final db = Database.open(
    config.databaseUrl,
    maxConnections: 2,
    timeZone: config.timeZone,
  );
  await db.waitUntilReady();
  await Migrator(db, Directory(config.migrationsDir)).migrate();
  await db.close();

  final (endpoint, sslMode) = parseDatabaseUrl(config.databaseUrl);
  final connection = await Connection.open(
    endpoint,
    settings: ConnectionSettings(
      sslMode: sslMode,
      timeZone: config.timeZone,
      applicationName: 'sitetrack-seed',
      queryTimeout: const Duration(hours: 2),
    ),
  );
  try {
    final existing = await connection.execute('SELECT count(*) FROM users');
    if ((existing.single[0]! as int) > 0) {
      if (!reset) {
        stderr.writeln(
          'The database already has data. Run with --reset to wipe it and seed again.',
        );
        exit(1);
      }
      stdout.writeln('Wiping existing data');
      await connection.execute('''
        TRUNCATE users, sessions, projects, project_members, project_invitations, tasks,
                 task_dependencies, materials, company_stock, stock_additions, project_stock,
                 deliveries, delivery_lines
        RESTART IDENTITY CASCADE''');
      await connection.execute('UPDATE counters SET value = 0');
    }

    final hash = await PasswordHasher(
      cost: config.bcryptCost,
    ).hash(demoPassword);
    final seeder = Seeder(
      connection,
      SeedPlan.scaled(scale),
      log: stdout.writeln,
    );
    await seeder.run(hash);

    final summary = await seeder.summary();
    stdout.writeln('\nRows:');
    for (final MapEntry(:key, :value) in summary.entries) {
      stdout.writeln('  ${key.padRight(38)} ${value.toString().padLeft(9)}');
    }
    // The data must obey the API's own rules, or it proves nothing.
    for (final invariant in [
      'started_tasks_waiting_on_unfinished',
      'company_stock_mismatches',
    ]) {
      if (summary[invariant] != 0) {
        stderr.writeln('Seed check failed: $invariant = ${summary[invariant]}');
        exit(1);
      }
    }
    stdout.writeln(
      '''

Log in with any seeded account; the password is "$demoPassword". For example:
  superadmin@sitetrack.test   SuperAdmin: sees every project and the company store
  manager@sitetrack.test      Company store manager
  user@sitetrack.test         User: member of every 50th project, admin of every 100th''',
    );
  } finally {
    await connection.close();
  }
}
