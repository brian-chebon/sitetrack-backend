import 'package:sitetrack/src/auth/login_throttle.dart';
import 'package:test/test.dart';

void main() {
  var now = DateTime.utc(2026, 11, 10, 9);
  LoginLimits limits() => LoginLimits(clock: () => now);

  setUp(() => now = DateTime.utc(2026, 11, 10, 9));

  test('ten failures lock an email from that address only', () {
    final l = limits();
    for (var i = 0; i < 9; i++) {
      l.recordFailure('amina@example.com', '203.0.113.7');
    }
    expect(l.isLocked('amina@example.com', '203.0.113.7'), isFalse);
    l.recordFailure('amina@example.com', '203.0.113.7');
    expect(l.isLocked('amina@example.com', '203.0.113.7'), isTrue);

    // The owner, signing in from elsewhere, is not locked out.
    expect(l.isLocked('amina@example.com', '198.51.100.20'), isFalse);
    // Nor is anyone else from the guessing address, yet.
    expect(l.isLocked('omar@example.com', '203.0.113.7'), isFalse);
  });

  test('a hundred failures across emails lock the address', () {
    final l = limits();
    for (var i = 0; i < 100; i++) {
      l.recordFailure('person$i@example.com', '203.0.113.7');
    }
    expect(l.isLocked('new@example.com', '203.0.113.7'), isTrue);
    expect(l.isLocked('new@example.com', '198.51.100.20'), isFalse);
  });

  test('a success clears the account count, not the address count', () {
    final l = limits();
    for (var i = 0; i < 9; i++) {
      l.recordFailure('me@example.com', '203.0.113.7');
    }
    l.recordSuccess('me@example.com', '203.0.113.7');
    for (var i = 0; i < 9; i++) {
      l.recordFailure('me@example.com', '203.0.113.7');
    }
    // Nine failures since the success: still allowed.
    expect(l.isLocked('me@example.com', '203.0.113.7'), isFalse);

    // The address keeps all 18, so 82 more on other emails make 100.
    for (var i = 0; i < 82; i++) {
      l.recordFailure('person$i@example.com', '203.0.113.7');
    }
    expect(l.isLocked('someone@example.com', '203.0.113.7'), isTrue);
  });

  test('a lock lifts once the oldest failure is 15 minutes old', () {
    final l = limits();
    for (var i = 0; i < 10; i++) {
      l.recordFailure('amina@example.com', '203.0.113.7');
      now = now.add(const Duration(minutes: 1));
    }
    expect(l.isLocked('amina@example.com', '203.0.113.7'), isTrue);
    // The first failure was at 09:00; at 09:15:01 only nine remain.
    now = DateTime.utc(2026, 11, 10, 9, 15, 1);
    expect(l.isLocked('amina@example.com', '203.0.113.7'), isFalse);
  });
}
