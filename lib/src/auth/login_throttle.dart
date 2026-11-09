/// Slows password guessing: after [maxFailures] failed logins for one email
/// within [window], further attempts for that email are refused until the
/// oldest failure ages out.
///
/// Failures are counted per email whether or not it is registered, so the
/// lockout itself reveals nothing. Kept in memory: the API runs as one process
/// on one server; a fleet would keep this in Redis or Postgres.
class LoginThrottle {
  LoginThrottle({
    this.maxFailures = 10,
    this.window = const Duration(minutes: 15),
  });

  final int maxFailures;
  final Duration window;
  final _failures = <String, List<DateTime>>{};

  bool isLocked(String key) {
    final recent = _recent(key);
    return recent != null && recent.length >= maxFailures;
  }

  void recordFailure(String key) {
    (_recent(key) ?? (_failures[key] = [])).add(DateTime.now());
    if (_failures.length > 50000) _prune();
  }

  void reset(String key) => _failures.remove(key);

  List<DateTime>? _recent(String key) {
    final list = _failures[key];
    if (list == null) return null;
    final cutoff = DateTime.now().subtract(window);
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
