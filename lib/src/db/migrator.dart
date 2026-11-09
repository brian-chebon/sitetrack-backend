import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:postgres/postgres.dart';

import 'database.dart';

/// Applies the numbered SQL files in a directory, in order, exactly once.
///
/// Each file is plain SQL named `NNNN_description.sql`. Applied versions and a
/// checksum of their contents are recorded in `schema_migrations`. A migration
/// that was edited after it ran stops startup instead of drifting silently:
/// schema changes go in a new file.
///
/// All pending files run in one transaction under an advisory lock, so two API
/// processes starting together cannot both apply them, and a failing file
/// leaves the database as it was.
class Migrator {
  Migrator(this._db, this._directory);

  final Database _db;
  final Directory _directory;

  /// Arbitrary constant shared by every process that migrates this database.
  static const _lockKey = 5174872026;

  /// Applies pending migrations and returns the versions it applied.
  Future<List<String>> migrate() async {
    final files = await _migrationFiles();
    return _db.transaction((tx) async {
      await tx.execute(
        Sql.named('SELECT pg_advisory_xact_lock(@key)'),
        parameters: {'key': _lockKey},
      );
      await tx.execute('''
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version    text PRIMARY KEY,
          checksum   text NOT NULL,
          applied_at timestamptz NOT NULL DEFAULT now()
        )''');

      final applied = <String, String>{
        for (final row in await tx.execute(
          'SELECT version, checksum FROM schema_migrations',
        ))
          row[0]! as String: row[1]! as String,
      };

      final unknown = applied.keys.toSet().difference(files.keys.toSet());
      if (unknown.isNotEmpty) {
        throw StateError(
          'The database has migrations this build does not know: '
          '${unknown.join(', ')}. Is an older API image running?',
        );
      }

      final ran = <String>[];
      for (final MapEntry(key: version, value: sql) in files.entries) {
        final checksum = sha256.convert(utf8.encode(sql)).toString();
        final previous = applied[version];
        if (previous != null) {
          if (previous != checksum) {
            throw StateError(
              'Migration $version changed after it was applied. '
              'Put schema changes in a new migration file.',
            );
          }
          continue;
        }
        // The simple query protocol accepts a whole file of statements.
        await tx.execute(sql, queryMode: QueryMode.simple);
        await tx.execute(
          Sql.named(
            'INSERT INTO schema_migrations (version, checksum) '
            'VALUES (@version, @checksum)',
          ),
          parameters: {'version': version, 'checksum': checksum},
        );
        ran.add(version);
      }
      return ran;
    });
  }

  /// Reads `NNNN_*.sql` files, keyed by version and sorted by version.
  Future<Map<String, String>> _migrationFiles() async {
    if (!await _directory.exists()) {
      throw StateError('Migrations directory ${_directory.path} not found');
    }
    final pattern = RegExp(r'^(\d{4}_[a-z0-9_]+)\.sql$');
    final entries = <String, String>{};
    await for (final entity in _directory.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      final match = pattern.firstMatch(name);
      if (match == null) {
        throw StateError('Unexpected file in migrations directory: $name');
      }
      entries[match.group(1)!] = await entity.readAsString();
    }
    final versions = entries.keys.toList()..sort();
    return {for (final version in versions) version: entries[version]!};
  }
}
