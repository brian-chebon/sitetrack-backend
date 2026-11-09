// Times every screen's API calls against a running, seeded API.
//
//   docker compose up -d && docker compose run --rm seed
//   dart run tool/bench.dart            # BASE_URL defaults to localhost:8080
//
// Each call runs [_runs] times after a warm-up; the table shows the median
// and the slowest run, measured from this client, so it includes HTTP and
// JSON encoding as well as the database.
import 'dart:convert';
import 'dart:io';

const _runs = 15;
final _base = Uri.parse(
  Platform.environment['BASE_URL'] ?? 'http://localhost:8080',
);
final _client = HttpClient();

Future<void> main() async {
  final superAdmin = await _login('superadmin@sitetrack.test');
  final manager = await _login('manager@sitetrack.test');
  final user = await _login('user@sitetrack.test');

  // One of the ten 3,000-task projects, and an ordinary one.
  const big = 'PRJ-0200';
  const busy = 'PRJ-1001';
  final lastTask = '$big-T-3000';
  final firstTask = '$big-T-0001';
  final cursor = (await _get(
    '/v1/company-store/deliveries?limit=50',
    manager,
  ))['nextCursor'];

  final rows = <List<String>>[];
  Future<void> time(
    String screen,
    String call,
    String path,
    String token,
  ) async {
    await _get(path, token); // warm-up
    final samples = <int>[];
    for (var i = 0; i < _runs; i++) {
      final watch = Stopwatch()..start();
      await _get(path, token);
      samples.add(watch.elapsedMicroseconds);
    }
    samples.sort();
    String ms(int us) => (us / 1000).toStringAsFixed(1);
    rows.add([
      screen,
      call,
      ms(samples[samples.length ~/ 2]),
      ms(samples.last),
    ]);
    stdout.write('.');
  }

  await time('3 Notifications', 'list, as user', '/v1/notifications', user);
  await time(
    '3 Notifications',
    'unread count',
    '/v1/notifications/unread-count',
    user,
  );
  await time(
    '4 Projects',
    'all 2,000, as SuperAdmin, by name',
    '/v1/projects',
    superAdmin,
  );
  await time(
    '4 Projects',
    'all 2,000, by % done',
    '/v1/projects?sort=-percentDone',
    superAdmin,
  );
  await time(
    '4 Projects',
    'all 2,000, by late tasks',
    '/v1/projects?sort=-lateTasks',
    superAdmin,
  );
  await time(
    '4 Projects',
    'only with late tasks',
    '/v1/projects?hasLateTasks=true',
    superAdmin,
  );
  await time(
    '4 Projects',
    'search "Muscat"',
    '/v1/projects?search=Muscat',
    superAdmin,
  );
  await time(
    '4 Projects',
    'as user (40 projects)',
    '/v1/projects?sort=-lateTasks',
    user,
  );
  await time(
    '5 Tasks',
    '3,000-task project, by ID',
    '/v1/projects/$big/tasks',
    superAdmin,
  );
  await time(
    '5 Tasks',
    'by dependents count',
    '/v1/projects/$big/tasks?sort=-dependents',
    superAdmin,
  );
  await time(
    '5 Tasks',
    'late and blocked',
    '/v1/projects/$big/tasks?late=true&blocked=true',
    superAdmin,
  );
  await time(
    '5 Tasks',
    'date range + search',
    '/v1/projects/$big/tasks?from=2026-01-01&to=2026-03-31&search=slab',
    superAdmin,
  );
  await time(
    '6 Task details',
    'last task (~3,000 upstream)',
    '/v1/projects/$big/tasks/$lastTask',
    superAdmin,
  );
  await time(
    '6 Task details',
    'first task (~3,000 downstream)',
    '/v1/projects/$big/tasks/$firstTask',
    superAdmin,
  );
  await time(
    '6 Task details',
    'ordinary project, mid-graph',
    '/v1/projects/$busy/tasks/$busy-T-0120',
    superAdmin,
  );
  await time(
    '7 Project store',
    'by last delivery',
    '/v1/projects/$busy/store?sort=-lastDelivery',
    superAdmin,
  );
  await time(
    '7 Project store',
    'search + category',
    '/v1/projects/$busy/store?search=cement&category=Cement%20%26%20Concrete',
    superAdmin,
  );
  await time(
    '8 Project deliveries',
    'newest first',
    '/v1/projects/$busy/deliveries',
    superAdmin,
  );
  await time(
    '8 Project deliveries',
    'incoming, delivered, 2025',
    '/v1/projects/$busy/deliveries?direction=incoming&status=delivered&from=2025-01-01&to=2025-12-31',
    superAdmin,
  );
  await time(
    '9 Members',
    'members + invitations',
    '/v1/projects/$big/members',
    superAdmin,
  );
  await time(
    '10 Company stock',
    '20,000 materials by name',
    '/v1/company-store/stock',
    manager,
  );
  await time(
    '10 Company stock',
    'by status',
    '/v1/company-store/stock?sort=status',
    manager,
  );
  await time(
    '10 Company stock',
    'low stock in one category',
    '/v1/company-store/stock?status=low_stock&category=Roofing',
    manager,
  );
  await time(
    '10 Company stock',
    'search "rebar"',
    '/v1/company-store/stock?search=rebar',
    manager,
  );
  await time(
    '11 Company deliveries',
    'newest first (400,000)',
    '/v1/company-store/deliveries',
    manager,
  );
  await time(
    '11 Company deliveries',
    'next page by cursor',
    '/v1/company-store/deliveries?cursor=$cursor',
    manager,
  );
  await time(
    '11 Company deliveries',
    'in transit',
    '/v1/company-store/deliveries?status=in_transit',
    manager,
  );
  await time(
    '11 Company deliveries',
    'one project, incoming',
    '/v1/company-store/deliveries?projectId=$busy&direction=incoming',
    manager,
  );
  await time(
    '11 Company deliveries',
    'rejected, 2024',
    '/v1/company-store/deliveries?status=rejected&from=2024-01-01&to=2024-12-31',
    manager,
  );

  stdout.writeln(
    '\n\n| Screen | Call | Median ms | Slowest ms |\n|---|---|---:|---:|',
  );
  for (final row in rows) {
    stdout.writeln('| ${row.join(' | ')} |');
  }
  _client.close();
}

Future<String> _login(String email) async {
  final body = await _send('POST', '/v1/auth/login', null, {
    'email': email,
    'password': 'sitetrack-demo',
  });
  return body['accessToken']! as String;
}

Future<Map<String, Object?>> _get(String path, String token) =>
    _send('GET', path, token, null);

Future<Map<String, Object?>> _send(
  String method,
  String path,
  String? token,
  Object? body,
) async {
  final request = await _client.openUrl(method, _base.resolve(path));
  if (token != null) request.headers.set('authorization', 'Bearer $token');
  if (body != null) {
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
  }
  final response = await request.close();
  final text = await response.transform(utf8.decoder).join();
  if (response.statusCode != 200) {
    throw StateError('$method $path: ${response.statusCode} $text');
  }
  return jsonDecode(text) as Map<String, Object?>;
}
