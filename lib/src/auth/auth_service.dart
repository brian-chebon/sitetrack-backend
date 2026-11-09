import 'package:postgres/postgres.dart';

import '../config.dart';
import '../db/database.dart';
import '../http/api_error.dart';
import 'caller.dart';
import 'login_throttle.dart';
import 'passwords.dart';
import 'tokens.dart';

/// A user as their own profile shows them. Never includes the password hash.
class UserProfile {
  UserProfile({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.createdAt,
  });

  factory UserProfile.fromRow(Map<String, dynamic> row) => UserProfile(
    id: row['id'] as int,
    name: row['name'] as String,
    email: row['email'] as String,
    role: AppRole.parse(row['app_role'] as String),
    createdAt: row['created_at'] as DateTime,
  );

  final int id;
  final String name;
  final String email;
  final AppRole role;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'email': email,
    'appRole': role.value,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };
}

/// The tokens handed out at login, registration and refresh.
class SessionTokens {
  SessionTokens({
    required this.accessToken,
    required this.accessTokenExpiresAt,
    required this.refreshToken,
    required this.refreshTokenExpiresAt,
  });

  final String accessToken;
  final DateTime accessTokenExpiresAt;
  final String refreshToken;
  final DateTime refreshTokenExpiresAt;

  Map<String, Object?> toJson() => {
    'accessToken': accessToken,
    'accessTokenExpiresAt': accessTokenExpiresAt.toUtc().toIso8601String(),
    'refreshToken': refreshToken,
    'refreshTokenExpiresAt': refreshTokenExpiresAt.toUtc().toIso8601String(),
  };
}

/// Accounts and sessions.
///
/// Sessions work like this: login creates a `sessions` row and returns a
/// 15-minute access JWT naming that session plus a refresh token. The client
/// sends the JWT on every request and swaps the refresh token for a new pair
/// before the JWT expires; each swap replaces the refresh token and extends the
/// session by the idle timeout (7 days), up to 30 days after login. So an
/// active user is never asked to log in again within that time, and logging
/// out revokes the row, which every later request checks.
class AuthService {
  AuthService(this._db, this._config, this._passwords, this._tokens);

  final Database _db;
  final Config _config;
  final PasswordHasher _passwords;
  final AccessTokens _tokens;
  final _limits = LoginLimits();

  static const invalidCredentials = 'invalid_credentials';

  /// Lower-cased and trimmed, as stored.
  static String normalizeEmail(String email) => email.trim().toLowerCase();

  Future<(UserProfile, SessionTokens)> register({
    required String name,
    required String email,
    required String password,
    required AppRole role,
  }) async {
    final hash = await _passwords.hash(password);
    return _db.transaction((tx) async {
      final Result rows;
      try {
        rows = await tx.execute(
          Sql.named('''
            INSERT INTO users (name, email, password_hash, app_role)
            VALUES (@name, @email, @hash, @role)
            RETURNING id, name, email, app_role, created_at'''),
          parameters: {
            'name': name,
            'email': normalizeEmail(email),
            'hash': hash,
            'role': role.value,
          },
        );
      } on ServerException catch (error) {
        if (error.code == '23505') {
          throw ApiError.conflict(
            'email_taken',
            'An account with this email already exists',
          );
        }
        rethrow;
      }
      final user = UserProfile.fromRow(rows.single.toColumnMap());
      return (user, await _startSession(tx, user.id));
    });
  }

  /// Logs in, or throws the same 401 whether the email is unknown or the
  /// password is wrong, after the same amount of bcrypt work. [address] is
  /// where the request came from, for [LoginLimits].
  Future<(UserProfile, SessionTokens)> login({
    required String email,
    required String password,
    required String address,
  }) async {
    final key = normalizeEmail(email);
    if (_limits.isLocked(key, address)) {
      throw ApiError(
        429,
        'too_many_attempts',
        'Too many failed logins; try again in a few minutes',
      );
    }
    final rows = await _db.query(
      '''SELECT id, name, email, app_role, created_at, password_hash
           FROM users WHERE email = @email''',
      {'email': key},
    );
    final row = rows.isEmpty ? null : rows.single.toColumnMap();
    final bool ok;
    if (row == null) {
      await _passwords.verifyDecoy(password);
      ok = false;
    } else {
      ok = await _passwords.verify(password, row['password_hash'] as String);
    }
    if (!ok) {
      _limits.recordFailure(key, address);
      throw ApiError(401, invalidCredentials, 'Email or password is incorrect');
    }
    _limits.recordSuccess(key, address);
    final user = UserProfile.fromRow(row!);
    final tokens = await _db.transaction((tx) => _startSession(tx, user.id));
    return (user, tokens);
  }

  /// Swaps a refresh token for a new access token and refresh token.
  ///
  /// The old refresh token stops working at once. Two refreshes racing with
  /// the same token cannot both succeed: the update matches on the old hash.
  Future<(UserProfile, SessionTokens)> refresh(String refreshToken) async {
    final parsed = RefreshTokens.parse(refreshToken);
    if (parsed == null) throw _invalidRefresh();
    final next = RefreshTokens.create(parsed.sessionId);
    final rows = await _db.query(
      '''
      WITH renewed AS (
        UPDATE sessions
           SET refresh_token_hash = @newHash,
               last_used_at = now(),
               expires_at = least(now() + make_interval(secs => @idle),
                                  created_at + make_interval(secs => @maxAge))
         WHERE id = @sessionId::uuid
           AND refresh_token_hash = @oldHash
           AND revoked_at IS NULL
           AND expires_at > now()
        RETURNING user_id, expires_at
      )
      SELECT u.id, u.name, u.email, u.app_role, u.created_at, r.expires_at
        FROM renewed r JOIN users u ON u.id = r.user_id''',
      {
        'sessionId': parsed.sessionId,
        'oldHash': parsed.hash,
        'newHash': next.hash,
        'idle': _config.sessionIdleTimeout.inSeconds,
        'maxAge': _config.sessionMaxAge.inSeconds,
      },
    );
    if (rows.isEmpty) throw _invalidRefresh();
    final row = rows.single.toColumnMap();
    final user = UserProfile.fromRow(row);
    final access = _tokens.issue(userId: user.id, sessionId: parsed.sessionId);
    return (
      user,
      SessionTokens(
        accessToken: access.token,
        accessTokenExpiresAt: access.expiresAt,
        refreshToken: next.token,
        refreshTokenExpiresAt: row['expires_at'] as DateTime,
      ),
    );
  }

  /// Ends the caller's current session; other sessions stay signed in.
  Future<void> logout(Caller caller) => _db.query(
    '''UPDATE sessions SET revoked_at = now()
        WHERE id = @sessionId::uuid AND revoked_at IS NULL''',
    {'sessionId': caller.sessionId},
  );

  /// Resolves an access token to the caller, checking the session is still
  /// live and reading the current role, or throws a 401.
  Future<Caller> authenticate(String accessToken) async {
    final claims = _tokens.verify(accessToken);
    if (!RefreshTokens.isSessionId(claims.sessionId)) {
      throw ApiError.unauthenticated();
    }
    final rows = await _db.query(
      '''
      SELECT u.id, u.name, u.email, u.app_role
        FROM sessions s
        JOIN users u ON u.id = s.user_id
       WHERE s.id = @sessionId::uuid
         AND s.user_id = @userId
         AND s.revoked_at IS NULL
         AND s.expires_at > now()''',
      {'sessionId': claims.sessionId, 'userId': claims.userId},
    );
    if (rows.isEmpty) {
      throw ApiError(
        401,
        'session_ended',
        'This session has ended; log in again',
      );
    }
    final row = rows.single.toColumnMap();
    return Caller(
      id: row['id'] as int,
      name: row['name'] as String,
      email: row['email'] as String,
      role: AppRole.parse(row['app_role'] as String),
      sessionId: claims.sessionId,
    );
  }

  Future<SessionTokens> _startSession(TxSession tx, int userId) async {
    final sessionId = RefreshTokens.newSessionId();
    final refresh = RefreshTokens.create(sessionId);
    final rows = await tx.execute(
      Sql.named('''
        INSERT INTO sessions (id, user_id, refresh_token_hash, expires_at)
        VALUES (@id::uuid, @userId, @hash, now() + make_interval(secs => @idle))
        RETURNING expires_at'''),
      parameters: {
        'id': sessionId,
        'userId': userId,
        'hash': refresh.hash,
        'idle': _config.sessionIdleTimeout.inSeconds,
      },
    );
    final access = _tokens.issue(userId: userId, sessionId: sessionId);
    return SessionTokens(
      accessToken: access.token,
      accessTokenExpiresAt: access.expiresAt,
      refreshToken: refresh.token,
      refreshTokenExpiresAt: rows.single[0]! as DateTime,
    );
  }

  ApiError _invalidRefresh() => ApiError(
    401,
    'invalid_refresh_token',
    'This refresh token is not valid; log in again',
  );
}
