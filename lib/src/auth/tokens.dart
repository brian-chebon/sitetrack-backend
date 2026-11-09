import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

import '../http/api_error.dart';

/// What a verified access token says: who, and which session.
typedef AccessClaims = ({int userId, String sessionId});

/// Short-lived HS256 access tokens carrying the user and session IDs.
///
/// The token alone never grants access: every request also checks that its
/// session is live and reads the user's role from the database.
class AccessTokens {
  AccessTokens(String secret, this.ttl) : _key = SecretKey(secret);

  final SecretKey _key;
  final Duration ttl;

  static const _issuer = 'sitetrack';

  ({String token, DateTime expiresAt}) issue({
    required int userId,
    required String sessionId,
  }) {
    final now = DateTime.now().toUtc();
    final expiresAt = now.add(ttl);
    final token = JWT(
      {
        'sid': sessionId,
        'iat': now.millisecondsSinceEpoch ~/ 1000,
        'exp': expiresAt.millisecondsSinceEpoch ~/ 1000,
      },
      subject: '$userId',
      issuer: _issuer,
    ).sign(_key, algorithm: JWTAlgorithm.HS256);
    return (token: token, expiresAt: expiresAt);
  }

  /// Verifies [token], or throws a 401.
  AccessClaims verify(String token) {
    // The library takes the algorithm from the token's own header and skips
    // the expiry check when `exp` is absent, so pin both here.
    final parts = token.split('.');
    if (parts.length != 3 || _headerAlgorithm(parts[0]) != 'HS256') {
      throw ApiError.unauthenticated();
    }
    final JWT jwt;
    try {
      jwt = JWT.verify(token, _key, issuer: _issuer);
    } on JWTExpiredException {
      throw ApiError(
        401,
        'token_expired',
        'The access token has expired; refresh it',
      );
    } on JWTException {
      throw ApiError.unauthenticated();
    }
    final payload = jwt.payload;
    final userId = int.tryParse(jwt.subject ?? '');
    if (payload is! Map ||
        payload['exp'] is! num ||
        payload['sid'] is! String ||
        userId == null) {
      throw ApiError.unauthenticated();
    }
    return (userId: userId, sessionId: payload['sid'] as String);
  }

  static String? _headerAlgorithm(String encodedHeader) {
    try {
      final header = jsonDecode(
        utf8.decode(base64Url.decode(base64Url.normalize(encodedHeader))),
      );
      return header is Map ? header['alg'] as String? : null;
    } on Object {
      return null;
    }
  }
}

/// Opaque refresh tokens: `<session id>.<random secret>`. Only a SHA-256 of
/// the secret is stored, so a database leak does not leak usable tokens.
class RefreshTokens {
  static final _random = Random.secure();
  static final _uuidPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  /// A fresh random session ID (UUID v4).
  static String newSessionId() {
    final bytes = Uint8List.fromList(
      List.generate(16, (_) => _random.nextInt(256)),
    );
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// A new token for [sessionId] and the hash to store for it.
  static ({String token, Uint8List hash}) create(String sessionId) {
    final secret = base64UrlEncode(
      List.generate(32, (_) => _random.nextInt(256)),
    ).replaceAll('=', '');
    return (token: '$sessionId.$secret', hash: _hashSecret(secret));
  }

  /// Splits [token] into its session ID and the hash of its secret, or
  /// returns null when it is not shaped like a refresh token.
  static ({String sessionId, Uint8List hash})? parse(String token) {
    final dot = token.indexOf('.');
    if (dot <= 0) return null;
    final sessionId = token.substring(0, dot);
    final secret = token.substring(dot + 1);
    if (!_uuidPattern.hasMatch(sessionId) || secret.length < 40) return null;
    return (sessionId: sessionId, hash: _hashSecret(secret));
  }

  static bool isSessionId(String value) => _uuidPattern.hasMatch(value);

  static Uint8List _hashSecret(String secret) =>
      Uint8List.fromList(sha256.convert(utf8.encode(secret)).bytes);
}
