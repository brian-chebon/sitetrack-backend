import 'package:test/test.dart';

import 'support/harness.dart';

void main() {
  final api = useTestApi();

  Future<String> newProject(TestUser owner, {String name = 'Site'}) async {
    final response = await api().post(
      '/v1/projects',
      body: {
        'name': name,
        'plannedStart': '2026-01-01',
        'plannedEnd': '2026-12-31',
      },
      as: owner,
    );
    expect(response.status, 201, reason: '$response');
    return response.body['id']! as String;
  }

  /// Invites [user] to [projectId] and has them accept.
  Future<void> addMember(
    TestUser admin,
    String projectId,
    TestUser user,
  ) async {
    final invite = await api().post(
      '/v1/projects/$projectId/invitations',
      body: {'email': user.email},
      as: admin,
    );
    expect(invite.status, 201, reason: '$invite');
    final accept = await api().post(
      '/v1/invitations/${invite.body['id']}/accept',
      as: user,
    );
    expect(accept.status, 200, reason: '$accept');
  }

  group('IDs', () {
    test(
      'projects are numbered PRJ-0001 upwards, uniquely under load',
      () async {
        final owner = await api().user();
        final responses = await Future.wait([
          for (var i = 0; i < 25; i++)
            api().post(
              '/v1/projects',
              body: {
                'name': 'Parallel $i',
                'plannedStart': '2026-01-01',
                'plannedEnd': '2026-02-01',
              },
              as: owner,
            ),
        ]);
        final ids = responses.map((r) => r.body['id']! as String).toList();
        expect(ids.toSet(), hasLength(25));
        expect(ids.every(RegExp(r'^PRJ-\d{4}$').hasMatch), isTrue);
        final numbers = ids.map((id) => int.parse(id.substring(4))).toList()
          ..sort();
        // No gaps: each create took the next number.
        expect(numbers.last - numbers.first, 24);
      },
    );

    test('a removed project number is never handed out again', () async {
      final owner = await api().user();
      final first = await newProject(owner);
      expect(
        (await api().delete('/v1/projects/$first', as: owner)).status,
        204,
      );
      final second = await newProject(owner);
      expect(int.parse(second.substring(4)), int.parse(first.substring(4)) + 1);
      expect((await api().get('/v1/projects/$first', as: owner)).status, 404);
    });
  });

  group('visibility', () {
    test(
      'a non-member gets the same 404 as for a project that does not exist',
      () async {
        final owner = await api().user();
        final outsider = await api().user();
        final manager = await api().user(role: 'store_manager');
        final id = await newProject(owner, name: 'Secret tower');

        for (final caller in [outsider, manager]) {
          final real = await api().get('/v1/projects/$id', as: caller);
          final fake = await api().get('/v1/projects/PRJ-9999', as: caller);
          final junk = await api().get('/v1/projects/not-an-id', as: caller);
          expect(real.status, 404);
          expect(real.text, fake.text);
          expect(real.text, junk.text);
          for (final path in ['members']) {
            expect(
              (await api().get('/v1/projects/$id/$path', as: caller)).status,
              404,
            );
          }
          expect(
            (await api().patch(
              '/v1/projects/$id',
              body: {'name': 'x'},
              as: caller,
            )).status,
            404,
          );
          expect(
            (await api().delete('/v1/projects/$id', as: caller)).status,
            404,
          );
          expect(
            (await api().post(
              '/v1/projects/$id/invitations',
              body: {'userId': caller.id},
              as: caller,
            )).status,
            404,
          );
          final listed = await api().get(
            '/v1/projects?search=Secret',
            as: caller,
          );
          expect(listed.items, isEmpty);
          expect(listed.body['total'], 0);
        }
      },
    );

    test('a SuperAdmin sees every project but is not its admin', () async {
      final owner = await api().user();
      final superAdmin = await api().user(role: 'super_admin');
      final id = await newProject(owner, name: 'Visible to SuperAdmin');

      final project = await api().get('/v1/projects/$id', as: superAdmin);
      expect(project.status, 200);
      expect(project.body['isMember'], isFalse);
      expect(project.body['isAdmin'], isFalse);
      final listed = await api().get(
        '/v1/projects?search=Visible to SuperAdmin',
        as: superAdmin,
      );
      expect(listed.items, hasLength(1));

      expect(
        (await api().get('/v1/projects/$id/members', as: superAdmin)).status,
        200,
      );
      final invite = await api().post(
        '/v1/projects/$id/invitations',
        body: {'userId': superAdmin.id},
        as: superAdmin,
      );
      expect(invite.status, 403);
    });

    test('removal takes effect on the very next request', () async {
      final owner = await api().user();
      final member = await api().user();
      final id = await newProject(owner);
      await addMember(owner, id, member);
      expect((await api().get('/v1/projects/$id', as: member)).status, 200);

      expect(
        (await api().delete(
          '/v1/projects/$id/members/${member.id}',
          as: owner,
        )).status,
        204,
      );
      // Same access token, still logged in.
      expect((await api().get('/v1/projects/$id', as: member)).status, 404);
      expect((await api().get('/v1/projects', as: member)).items, isEmpty);
    });
  });

  group('projects', () {
    test(
      'the creator is its admin and the list shows the screen fields',
      () async {
        final owner = await api().user();
        final id = await newProject(owner, name: 'Harbour wall');
        final listed = await api().get('/v1/projects', as: owner);
        expect(listed.status, 200);
        final project = listed.items.single! as Map;
        expect(project['id'], id);
        expect(project['isAdmin'], isTrue);
        expect(project['memberCount'], 1);
        expect(project['taskCounts'], {
          'notStarted': 0,
          'inProgress': 0,
          'done': 0,
          'total': 0,
        });
        expect(project['percentDone'], 0);
        expect(project['lateTasks'], 0);
        expect(project['blockedTasks'], 0);
      },
    );

    test('search matches names and IDs, and sorts apply', () async {
      final owner = await api().user();
      final a = await newProject(owner, name: 'Bravo bridge');
      await newProject(owner, name: 'Alpha annex');
      final byName = await api().get('/v1/projects?sort=name', as: owner);
      expect(byName.items.map((p) => (p! as Map)['name']), [
        'Alpha annex',
        'Bravo bridge',
      ]);
      final desc = await api().get('/v1/projects?sort=-name', as: owner);
      expect((desc.items.first! as Map)['name'], 'Bravo bridge');
      final byId = await api().get(
        '/v1/projects?search=${a.substring(4)}',
        as: owner,
      );
      expect(byId.items.map((p) => (p! as Map)['id']), [a]);
      final literal = await api().get('/v1/projects?search=%25', as: owner);
      expect(literal.items, isEmpty);
      final badSort = await api().get('/v1/projects?sort=secret', as: owner);
      expect(badSort.status, 400);
    });

    test('only admins edit; dates are validated', () async {
      final owner = await api().user();
      final member = await api().user();
      final id = await newProject(owner);
      await addMember(owner, id, member);

      expect(
        (await api().patch(
          '/v1/projects/$id',
          body: {'name': 'New'},
          as: member,
        )).status,
        403,
      );
      final bad = await api().patch(
        '/v1/projects/$id',
        body: {'plannedEnd': '2025-01-01'},
        as: owner,
      );
      expect(bad.status, 400);
      final ok = await api().patch(
        '/v1/projects/$id',
        body: {'name': 'Renamed', 'plannedEnd': '2027-06-30'},
        as: owner,
      );
      expect(ok.status, 200);
      expect(ok.body['name'], 'Renamed');
      expect(ok.body['plannedEnd'], '2027-06-30');
    });
  });

  group('members and invitations', () {
    test(
      'an invitation shows in notifications and only the invitee answers it',
      () async {
        final owner = await api().user();
        final invitee = await api().user();
        final stranger = await api().user();
        final id = await newProject(owner, name: 'Invite me');

        final invite = await api().post(
          '/v1/projects/$id/invitations',
          body: {'email': invitee.email.toUpperCase()},
          as: owner,
        );
        expect(invite.status, 201);
        final invitationId = invite.body['id'];

        expect(
          (await api().get('/v1/me', as: invitee)).body['unreadNotifications'],
          1,
        );
        final notifications = await api().get('/v1/notifications', as: invitee);
        final item = notifications.items.single! as Map;
        expect(item['project'], {'id': id, 'name': 'Invite me'});
        expect(item['actions'], ['accept', 'reject']);
        expect(notifications.body['unreadCount'], 1);

        // Not a member until they accept.
        expect((await api().get('/v1/projects/$id', as: invitee)).status, 404);
        // Nobody else can answer it, and they cannot tell it exists.
        for (final caller in [stranger, owner]) {
          final response = await api().post(
            '/v1/invitations/$invitationId/accept',
            as: caller,
          );
          expect(response.status, 404);
        }

        final members = await api().get('/v1/projects/$id/members', as: owner);
        expect(members.body['pendingInvitations'], hasLength(1));

        final accepted = await api().post(
          '/v1/invitations/$invitationId/accept',
          as: invitee,
        );
        expect(accepted.status, 200);
        expect(accepted.body['status'], 'accepted');
        expect(accepted.body['actions'], isEmpty);
        expect((await api().get('/v1/projects/$id', as: invitee)).status, 200);
        expect(
          (await api().get('/v1/me', as: invitee)).body['unreadNotifications'],
          0,
        );
        final again = await api().post(
          '/v1/invitations/$invitationId/reject',
          as: invitee,
        );
        expect(again.status, 409);

        final after = await api().get('/v1/projects/$id/members', as: owner);
        expect(after.body['members'], hasLength(2));
        expect(after.body['pendingInvitations'], isEmpty);
        expect(
          (await api().get('/v1/projects/$id', as: owner)).body['memberCount'],
          2,
        );
      },
    );

    test(
      'marking read clears the badge; withdrawn invitations stop counting',
      () async {
        final owner = await api().user();
        final invitee = await api().user();
        final first = await newProject(owner);
        final second = await newProject(owner);
        for (final id in [first, second]) {
          await api().post(
            '/v1/projects/$id/invitations',
            body: {'email': invitee.email},
            as: owner,
          );
        }
        expect(
          (await api().get(
            '/v1/notifications/unread-count',
            as: invitee,
          )).body['unreadCount'],
          2,
        );

        final members = await api().get(
          '/v1/projects/$second/members',
          as: owner,
        );
        final pending =
            (members.body['pendingInvitations']! as List).single! as Map;
        expect(
          (await api().delete(
            '/v1/projects/$second/invitations/${pending['id']}',
            as: owner,
          )).status,
          204,
        );
        expect(
          (await api().get(
            '/v1/notifications/unread-count',
            as: invitee,
          )).body['unreadCount'],
          1,
        );
        final accept = await api().post(
          '/v1/invitations/${pending['id']}/accept',
          as: invitee,
        );
        expect(accept.status, 409);

        final read = await api().post('/v1/notifications/read', as: invitee);
        expect(read.body['unreadCount'], 0);
        final list = await api().get('/v1/notifications', as: invitee);
        expect(list.items.map((n) => (n! as Map)['status']), [
          'withdrawn',
          'pending',
        ]);
      },
    );

    test('only admins manage members, and duplicates are refused', () async {
      final owner = await api().user();
      final member = await api().user();
      final other = await api().user();
      final id = await newProject(owner);
      await addMember(owner, id, member);

      final byMember = await api().post(
        '/v1/projects/$id/invitations',
        body: {'userId': other.id},
        as: member,
      );
      expect(byMember.status, 403);
      expect(
        (await api().patch(
          '/v1/projects/$id/members/${member.id}',
          body: {'isAdmin': true},
          as: member,
        )).status,
        403,
      );
      expect(
        (await api().delete(
          '/v1/projects/$id/members/${owner.id}',
          as: member,
        )).status,
        403,
      );

      final existing = await api().post(
        '/v1/projects/$id/invitations',
        body: {'userId': member.id},
        as: owner,
      );
      expect(existing.errorCode, 'already_member');
      // A stranger's user ID finds no one, exactly like an unknown ID, so
      // inviting IDs one by one cannot reveal people's emails. Their email
      // still reaches them.
      final strangerById = await api().post(
        '/v1/projects/$id/invitations',
        body: {'userId': other.id},
        as: owner,
      );
      expect(strangerById.status, 400);
      final unknownId = await api().post(
        '/v1/projects/$id/invitations',
        body: {'userId': 999999},
        as: owner,
      );
      expect(strangerById.text, unknownId.text);
      final byEmail = await api().post(
        '/v1/projects/$id/invitations',
        body: {'email': other.email},
        as: owner,
      );
      expect(byEmail.status, 201, reason: '$byEmail');
      final twice = await api().post(
        '/v1/projects/$id/invitations',
        body: {'email': other.email},
        as: owner,
      );
      expect(twice.errorCode, 'already_invited');
    });

    test('a project always keeps at least one admin', () async {
      final owner = await api().user();
      final member = await api().user();
      final id = await newProject(owner);
      await addMember(owner, id, member);

      final demoteSelf = await api().patch(
        '/v1/projects/$id/members/${owner.id}',
        body: {'isAdmin': false},
        as: owner,
      );
      expect(demoteSelf.errorCode, 'last_admin');
      final leave = await api().delete(
        '/v1/projects/$id/members/${owner.id}',
        as: owner,
      );
      expect(leave.errorCode, 'last_admin');

      final promote = await api().patch(
        '/v1/projects/$id/members/${member.id}',
        body: {'isAdmin': true},
        as: owner,
      );
      expect(promote.status, 200);
      expect(promote.body['isAdmin'], isTrue);

      // Two admins demoting each other at the same moment: one must lose.
      final results = await Future.wait([
        api().patch(
          '/v1/projects/$id/members/${member.id}',
          body: {'isAdmin': false},
          as: owner,
        ),
        api().patch(
          '/v1/projects/$id/members/${owner.id}',
          body: {'isAdmin': false},
          as: member,
        ),
      ]);
      // The loser is refused either as no longer an admin (403) or as the
      // last admin (409), depending on which request took the lock first.
      final statuses = results.map((r) => r.status).toList()..sort();
      expect(statuses.first, 200);
      expect(statuses.last, anyOf(403, 409));
      final admins =
          (await api().get(
                '/v1/projects/$id/members',
                as: owner,
              )).body['members']!
              as List;
      expect(admins.where((m) => (m! as Map)['isAdmin'] == true), hasLength(1));
    });

    test('a member can leave on their own', () async {
      final owner = await api().user();
      final member = await api().user();
      final id = await newProject(owner);
      await addMember(owner, id, member);
      expect(
        (await api().delete(
          '/v1/projects/$id/members/${member.id}',
          as: member,
        )).status,
        204,
      );
      expect((await api().get('/v1/projects/$id', as: member)).status, 404);
    });
  });
}
