import 'dart:convert';
import 'dart:isolate';

import 'package:bcrypt/bcrypt.dart';

/// bcrypt hashing, run on a short-lived worker isolate: one hash takes about
/// 200 ms of CPU at cost 10, which would otherwise stall every other request.
class PasswordHasher {
  PasswordHasher({required this.cost})
    // A real hash to check unknown emails against, so a login for an email
    // that is not registered takes as long as one with a wrong password.
    : _decoyHash = _hash('not a real password', cost);

  final int cost;
  final Future<String> _decoyHash;

  /// bcrypt reads at most 72 bytes; longer passwords are refused rather than
  /// silently truncated.
  static const maxBytes = 72;
  static const minLength = 8;

  /// Why [password] is unacceptable, or null when it is fine.
  static String? problem(String password) {
    if (password.length < minLength) {
      return 'must be at least $minLength characters';
    }
    if (utf8.encode(password).length > maxBytes) {
      return 'must be at most $maxBytes bytes';
    }
    return null;
  }

  Future<String> hash(String password) => _hash(password, cost);

  Future<bool> verify(String password, String hash) => _verify(password, hash);

  /// Burns the same time as [verify] for a login whose email is unknown.
  Future<void> verifyDecoy(String password) async {
    await _verify(password, await _decoyHash);
  }
}

// Top-level, so the isolate closures capture only their arguments.
Future<String> _hash(String password, int cost) =>
    Isolate.run(() => BCrypt.hashpw(password, BCrypt.gensalt(logRounds: cost)));

Future<bool> _verify(String password, String hash) =>
    Isolate.run(() => BCrypt.checkpw(password, hash));
