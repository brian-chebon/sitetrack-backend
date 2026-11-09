import 'package:shelf/shelf.dart';

import '../http/api_error.dart';
import '../http/json.dart';
import '../http/validation.dart';
import 'auth_service.dart';
import 'caller.dart';
import 'passwords.dart';

final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

/// Register, log in, refresh, log out.
class AuthRoutes {
  AuthRoutes(this._auth);

  final AuthService _auth;

  /// `POST /v1/auth/register` with name, email, password and appRole.
  ///
  /// The brief has people choose their app role here, SuperAdmin included;
  /// see the README for why that is kept and how it would be locked down.
  Future<Response> register(Request request) async {
    final body = BodyReader(await readJsonObject(request));
    final name = body.string('name');
    final email = body.string('email', maxLength: 320);
    final password = body.rawString('password', maxLength: 200);
    final role = body.choice(
      'appRole',
      AppRole.byValue,
      fallback: AppRole.user,
    );
    if (body.has('email') && !_emailPattern.hasMatch(email)) {
      body.error('email', 'must be an email address');
    }
    if (body.has('password')) {
      final problem = PasswordHasher.problem(password);
      if (problem != null) body.error('password', problem);
    }
    body.throwIfInvalid();

    final (user, tokens) = await _auth.register(
      name: name,
      email: email,
      password: password,
      role: role,
    );
    return jsonResponse({
      'user': user.toJson(),
      ...tokens.toJson(),
    }, status: 201);
  }

  /// `POST /v1/auth/login` with email and password.
  Future<Response> login(Request request) async {
    final body = BodyReader(await readJsonObject(request));
    final email = body.string('email', maxLength: 320);
    final password = body.rawString('password', maxLength: 200);
    body.throwIfInvalid();

    final (user, tokens) = await _auth.login(email: email, password: password);
    return jsonResponse({'user': user.toJson(), ...tokens.toJson()});
  }

  /// `POST /v1/auth/refresh` with the refresh token from login.
  Future<Response> refresh(Request request) async {
    final body = BodyReader(await readJsonObject(request));
    final token = body.rawString('refreshToken', maxLength: 200);
    body.throwIfInvalid();

    final (user, tokens) = await _auth.refresh(token);
    return jsonResponse({'user': user.toJson(), ...tokens.toJson()});
  }

  /// `POST /v1/auth/logout`: ends the session the access token belongs to.
  Future<Response> logout(Request request) async {
    await _auth.logout(callerOf(request));
    return Response(204);
  }
}

/// Authenticates every request it wraps from its `Authorization: Bearer`
/// header and attaches the [Caller].
Middleware authenticate(AuthService auth) =>
    (inner) => (request) async {
      final header = request.headers['authorization'];
      if (header == null || !header.startsWith('Bearer ')) {
        throw ApiError.unauthenticated();
      }
      final caller = await auth.authenticate(header.substring(7).trim());
      return inner(attachCaller(request, caller));
    };
