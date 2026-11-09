/// Slows password guessing without letting a stranger lock someone out.
///
/// Failed logins are counted twice: for one email from one network address,
/// and for one address across every email. Ten failures for an email from
/// one address within 15 minutes refuse that email from that address; a
/// hundred from one address refuse that address whatever the email. So
/// guessing at one account and spraying many are both slowed, while the
/// account's owner, signing in from somewhere else, is not locked out.
///
/// Failures count whether or not the email is registered, so a lockout
/// reveals nothing. Kept in memory: the API runs as one process on one
/// server; a fleet would keep this in Redis or Postgres.
class LoginLimits {
  LoginLimits({
    int perAccount = 10,
    int perAddress = 100,
    Duration window = const Duration(minutes: 15),
    DateTime Function() clock = DateTime.now,
  }) : _accounts = LoginThrottle(
         maxFailures: perAccount,
         window: window,
         clock: clock,
       ),
       _addresses = LoginThrottle(
         maxFailures: perAddress,
         window: window,
         clock: clock,
       );

  final LoginThrottle _accounts;
  final LoginThrottle _addresses;

  bool isLocked(String email, String address) =>
      _accounts.isLocked(_account(email, address)) ||
      _addresses.isLocked(address);

  void recordFailure(String email, String address) {
    _accounts.recordFailure(_account(email, address));
    _addresses.recordFailure(address);
  }

  /// Clears the email's count from this address. The address's own count
  /// stays, or signing in to one's own account would wipe a spray.
  void recordSuccess(String email, String address) =>
      _accounts.reset(_account(email, address));

  static String _account(String email, String address) => '$address $email';
}

/// Counts failures per key: after [maxFailures] within [window], the key is
/// locked until its oldest failure ages out.
class LoginThrottle {
  LoginThrottle({
    this.maxFailures = 10,
    this.window = const Duration(minutes: 15),
    this.clock = DateTime.now,
  });

  final int maxFailures;
  final Duration window;
  final DateTime Function() clock;
  final _failures = <String, List<DateTime>>{};

  bool isLocked(String key) {
    final recent = _recent(key);
    return recent != null && recent.length >= maxFailures;
  }

  void recordFailure(String key) {
    (_recent(key) ?? (_failures[key] = [])).add(clock());
    if (_failures.length > 50000) _prune();
  }

  void reset(String key) => _failures.remove(key);

  List<DateTime>? _recent(String key) {
    final list = _failures[key];
    if (list == null) return null;
    final cutoff = clock().subtract(window);
    list.removeWhere((time) => time.isBefore(cutoff));
    if (list.isEmpty) {
      _failures.remove(key);
      return null;
    }
    return list;
  }

  void _prune() {
    for (final key in _failures.keys.toList()) {
      _recent(key);
    }
  }
}
