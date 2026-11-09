import 'dart:convert';

import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  final api = useTestApi();

  group('register', () {
    test(
      'creates the account, signs it in and never returns the password',
      () async {
        final response = await api().post(
          '/v1/auth/register',
          body: {
            'name': 'Amina Said',
            'email': '  Amina@Example.com ',
            'password': 'correct horse',
            'appRole': 'store_manager',
          },
        );
        expect(response.status, 201);
        final user = response.body['user']! as Map;
        expect(user['email'], 'amina@example.com');
        expect(user['appRole'], 'store_manager');
        expect(response.text, isNot(contains('correct horse')));
        expect(response.text, isNot(contains(r'$2a$')));
        expect(response.body['accessToken'], isA<String>());
        expect(response.body['refreshToken'], isA<String>());

        final me = await api().get(
          '/v1/me',
          token: response.body['accessToken']! as String,
        );
        expect(me.status, 200);
        expect(me.body['email'], 'amina@example.com');
        expect(me.body['unreadNotifications'], 0);
        expect(me.text, isNot(contains('password')));

        final stored = await api().db.query(
          "SELECT password_hash FROM users WHERE email = 'amina@example.com'",
        );
        expect(stored.single[0], startsWith(r'$2a$'));
      },
    );

    test('refuses a second account for the same email, in any case', () async {
      final user = await api().user();
      final response = await api().post(
        '/v1/auth/register',
        body: {
          'name': 'Copy',
          'email': user.email.toUpperCase(),
          'password': 'password-x',
          'appRole': 'user',
        },
      );
      expect(response.status, 409);
      expect(response.errorCode, 'email_taken');
    });

    test('reports every invalid field at once', () async {
      final response = await api().post(
        '/v1/auth/register',
        body: {
          'name': '',
          'email': 'nope',
          'password': 'short',
          'appRole': 'boss',
        },
      );
      expect(response.status, 400);
      final fields =
          ((response.body['error']! as Map)['details']! as Map)['fields']!
              as Map;
      expect(
        fields.keys,
        containsAll(['name', 'email', 'password', 'appRole']),
      );
    });
  });

  group('login', () {
    test('wrong password and unknown email fail identically', () async {
      final user = await api().user();
      final wrongPassword = await api().post(
        '/v1/auth/login',
        body: {'email': user.email, 'password': 'not-the-password'},
      );
      final unknownEmail = await api().post(
        '/v1/auth/login',
        body: {'email': 'nobody@example.com', 'password': 'not-the-password'},
      );
      expect(wrongPassword.status, 401);
      expect(unknownEmail.status, 401);
      expect(wrongPassword.text, unknownEmail.text);
    });

    test('locks an email after repeated failures, registered or not', () async {
      final user = await api().user();
      for (final email in [user.email, 'ghost@example.com']) {
        for (var i = 0; i < 10; i++) {
          await api().post(
            '/v1/auth/login',
            body: {'email': email, 'password': 'wrong-password'},
          );
        }
        final locked = await api().post(
          '/v1/auth/login',
          body: {'email': email, 'password': 'wrong-password'},
        );
        expect(locked.status, 429, reason: email);
      }
    });

    test('a correct login works and starts a separate session', () async {
      final user = await api().user();
      final n = user.email.substring(4, user.email.indexOf('-'));
      final response = await api().post(
        '/v1/auth/login',
        body: {'email': user.email, 'password': 'password-$n'},
      );
      expect(response.status, 200);
      expect(response.body['accessToken'], isNot(user.accessToken));
    });
  });

  group('sessions', () {
    test('refresh rotates the refresh token', () async {
      final user = await api().user();
      final first = await api().post(
        '/v1/auth/refresh',
        body: {'refreshToken': user.refreshToken},
      );
      expect(first.status, 200);
      final next = first.body['refreshToken']! as String;
      expect(next, isNot(user.refreshToken));

      final reused = await api().post(
        '/v1/auth/refresh',
        body: {'refreshToken': user.refreshToken},
      );
      expect(reused.status, 401);

      final again = await api().post(
        '/v1/auth/refresh',
        body: {'refreshToken': next},
      );
      expect(again.status, 200);
      final me = await api().get(
        '/v1/me',
        token: again.body['accessToken']! as String,
      );
      expect(me.status, 200);
    });

    test('two refreshes racing with one token: exactly one wins', () async {
      final user = await api().user();
      final results = await Future.wait([
        for (var i = 0; i < 5; i++)
          api().post(
            '/v1/auth/refresh',
            body: {'refreshToken': user.refreshToken},
          ),
      ]);
      expect(results.where((r) => r.status == 200), hasLength(1));
    });

    test('logout ends that session at once and only that session', () async {
      final user = await api().user();
      final n = user.email.substring(4, user.email.indexOf('-'));
      final other = await api().post(
        '/v1/auth/login',
        body: {'email': user.email, 'password': 'password-$n'},
      );

      expect((await api().post('/v1/auth/logout', as: user)).status, 204);

      final afterLogout = await api().get('/v1/me', as: user);
      expect(afterLogout.status, 401);
      expect(afterLogout.errorCode, 'session_ended');
      final refresh = await api().post(
        '/v1/auth/refresh',
        body: {'refreshToken': user.refreshToken},
      );
      expect(refresh.status, 401);

      final otherMe = await api().get(
        '/v1/me',
        token: other.body['accessToken']! as String,
      );
      expect(otherMe.status, 200);
    });

    test('rejects missing, garbled, tampered and unsigned tokens', () async {
      final user = await api().user();
      final parts = user.accessToken.split('.');
      final payload =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
              )
              as Map<String, Object?>;
      final forged = base64Url
          .encode(utf8.encode(jsonEncode({...payload, 'sub': '1'})))
          .replaceAll('=', '');
      final none = base64Url
          .encode(utf8.encode('{"alg":"none","typ":"JWT"}'))
          .replaceAll('=', '');

      for (final token in [
        null,
        'garbage',
        '${parts[0]}.$forged.${parts[2]}',
        '$none.${parts[1]}.',
      ]) {
        final response = await api().get('/v1/me', token: token);
        expect(response.status, 401, reason: token);
      }
    });
  });

  group('app roles', () {
    test(
      'a SuperAdmin can change a role and it applies on the next request',
      () async {
        final admin = await api().user(role: 'super_admin');
        final user = await api().user();
        expect(((await api().get('/v1/me', as: user)).body)['appRole'], 'user');

        final change = await api().patch(
          '/v1/users/${user.id}/role',
          body: {'appRole': 'store_manager'},
          as: admin,
        );
        expect(change.status, 200);

        // Same access token as before: the role comes from the database.
        final me = await api().get('/v1/me', as: user);
        expect(me.body['appRole'], 'store_manager');
      },
    );

    test('nobody else can change roles', () async {
      final manager = await api().user(role: 'store_manager');
      final user = await api().user();
      for (final caller in [manager, user]) {
        final response = await api().patch(
          '/v1/users/${user.id}/role',
          body: {'appRole': 'super_admin'},
          as: caller,
        );
        expect(response.status, 403);
      }
    });
  });

  test('the user directory needs a session and shows no secrets', () async {
    final user = await api().user(name: 'Directory Person');
    expect((await api().get('/v1/users?search=Directory')).status, 401);
    final found = await api().get('/v1/users?search=Directory', as: user);
    expect(found.status, 200);
    expect(found.items, hasLength(1));
    expect(found.text, isNot(contains('password')));
  });
}
