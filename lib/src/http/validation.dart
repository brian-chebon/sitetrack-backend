import 'api_error.dart';

final _datePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$');
final _quantityPattern = RegExp(r'^\d{1,11}(\.\d{1,3})?$');

/// Parses a calendar date written `YYYY-MM-DD`, or returns null.
DateTime? parseDate(String text) {
  final match = _datePattern.firstMatch(text);
  if (match == null) return null;
  final year = int.parse(match.group(1)!);
  final month = int.parse(match.group(2)!);
  final day = int.parse(match.group(3)!);
  final date = DateTime.utc(year, month, day);
  // DateTime rolls 2026-02-30 over to March; reject instead.
  if (date.year != year || date.month != month || date.day != day) return null;
  return date;
}

/// `YYYY-MM-DD` for a date column value.
String formatDate(DateTime date) {
  final d = date.toUtc();
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// ISO 8601 in UTC for a timestamp column value.
String formatTimestamp(DateTime time) => time.toUtc().toIso8601String();

/// Normalises a quantity from JSON (a number or a decimal string) into the
/// exact decimal text Postgres stores in numeric(14,3), or returns null when it
/// is not a positive amount with at most three decimals.
String? parseQuantity(Object? raw, {bool allowZero = false}) {
  final String text;
  if (raw is int) {
    text = raw.toString();
  } else if (raw is double) {
    if (!raw.isFinite) return null;
    final fixed = raw.toStringAsFixed(3);
    // More than three decimals is refused, not rounded.
    if (double.parse(fixed) != raw) return null;
    text = fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  } else if (raw is String) {
    text = raw.trim();
  } else {
    return null;
  }
  if (!_quantityPattern.hasMatch(text)) return null;
  final isZero = RegExp(r'^0+(\.0+)?$').hasMatch(text);
  if (isZero && !allowZero) return null;
  return text;
}

/// Converts a numeric column value (decoded as text) to a JSON number.
num quantityToJson(Object? value) => num.parse(value! as String);

/// Reads fields of a JSON request body, collecting every problem so the client
/// gets all of them in one 400 response. Getters return a placeholder for an
/// invalid field; call [throwIfInvalid] before using any value.
class BodyReader {
  BodyReader(this._json);

  final Map<String, Object?> _json;
  final _errors = <String, String>{};

  bool has(String field) => _json.containsKey(field);

  Object? raw(String field) => _json[field];

  void error(String field, String message) =>
      _errors.putIfAbsent(field, () => message);

  String string(String field, {int maxLength = 200}) =>
      optionalString(field, maxLength: maxLength) ?? _required(field, '');

  String? optionalString(String field, {int maxLength = 200}) {
    final raw = _json[field];
    if (raw == null) return null;
    if (raw is! String) return _invalid(field, 'must be a string');
    final value = raw.trim();
    if (value.isEmpty) return _invalid(field, 'must not be empty');
    if (value.length > maxLength) {
      return _invalid(field, 'must be at most $maxLength characters');
    }
    return value;
  }

  /// A string used verbatim (passwords): not trimmed.
  String rawString(String field, {int maxLength = 200}) {
    final raw = _json[field];
    if (raw == null) return _required(field, '');
    if (raw is! String) return _invalid(field, 'must be a string') ?? '';
    if (raw.length > maxLength) {
      return _invalid(field, 'must be at most $maxLength characters') ?? '';
    }
    return raw;
  }

  DateTime date(String field) =>
      optionalDate(field) ?? _required(field, DateTime.utc(1970));

  DateTime? optionalDate(String field) {
    final raw = _json[field];
    if (raw == null) return null;
    final date = raw is String ? parseDate(raw) : null;
    return date ?? _invalid(field, 'must be a date written YYYY-MM-DD');
  }

  bool boolean(String field) {
    final raw = _json[field];
    if (raw == null) return _required(field, false);
    if (raw is! bool) return _invalid(field, 'must be true or false') ?? false;
    return raw;
  }

  int integer(String field) {
    final raw = _json[field];
    if (raw == null) return _required(field, 0);
    if (raw is! int) return _invalid(field, 'must be an integer') ?? 0;
    return raw;
  }

  /// One of [allowed]'s keys, mapped to its value.
  T choice<T>(String field, Map<String, T> allowed, {required T fallback}) {
    final raw = _json[field];
    if (raw == null) return _required(field, fallback);
    final value = raw is String ? allowed[raw] : null;
    return value ??
        _invalid(field, 'must be one of ${allowed.keys.join(', ')}') ??
        fallback;
  }

  List<Object?> list(String field, {int minLength = 1, int maxLength = 500}) {
    final raw = _json[field];
    if (raw == null) return _required(field, const <Object?>[]);
    if (raw is! List<Object?>) {
      return _invalid(field, 'must be an array') ?? const [];
    }
    if (raw.length < minLength || raw.length > maxLength) {
      return _invalid(
            field,
            'must hold between $minLength and $maxLength items',
          ) ??
          const [];
    }
    return raw;
  }

  void throwIfInvalid() {
    if (_errors.isNotEmpty) {
      throw ApiError.badRequest(
        'Some fields are invalid',
        details: {'fields': Map.of(_errors)},
      );
    }
  }

  T _required<T>(String field, T placeholder) {
    error(field, 'is required');
    return placeholder;
  }

  T? _invalid<T>(String field, String message) {
    error(field, message);
    return null;
  }
}

/// Reads list-screen query parameters: filters, search, sort and paging.
class QueryReader {
  QueryReader(this._params);

  final Map<String, String> _params;
  final _errors = <String, String>{};

  String? search([String name = 'search']) {
    final value = _params[name]?.trim();
    if (value == null || value.isEmpty) return null;
    if (value.length > 100) {
      _errors[name] = 'must be at most 100 characters';
      return null;
    }
    return value;
  }

  String? string(String name, {int maxLength = 100}) {
    final value = _params[name]?.trim();
    if (value == null || value.isEmpty) return null;
    if (value.length > maxLength) {
      _errors[name] = 'must be at most $maxLength characters';
      return null;
    }
    return value;
  }

  DateTime? date(String name) {
    final raw = _params[name];
    if (raw == null || raw.isEmpty) return null;
    final value = parseDate(raw);
    if (value == null) _errors[name] = 'must be a date written YYYY-MM-DD';
    return value;
  }

  bool? boolean(String name) {
    final raw = _params[name];
    if (raw == null || raw.isEmpty) return null;
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    _errors[name] = 'must be true or false';
    return null;
  }

  T? choice<T>(String name, Map<String, T> allowed) {
    final raw = _params[name];
    if (raw == null || raw.isEmpty) return null;
    final value = allowed[raw];
    if (value == null) {
      _errors[name] = 'must be one of ${allowed.keys.join(', ')}';
    }
    return value;
  }

  /// Several comma-separated values, each one of [allowed]'s keys.
  List<T>? choices<T>(String name, Map<String, T> allowed) {
    final raw = _params[name];
    if (raw == null || raw.isEmpty) return null;
    final values = <T>[];
    for (final part in raw.split(',')) {
      final value = allowed[part.trim()];
      if (value == null) {
        _errors[name] = 'must be one or more of ${allowed.keys.join(', ')}';
        return null;
      }
      values.add(value);
    }
    return values;
  }

  /// A sort key from [allowed]; `-key` sorts descending.
  ({T key, bool descending}) sort<T>(
    Map<String, T> allowed, {
    required T fallback,
    bool fallbackDescending = false,
  }) {
    final raw = _params['sort'];
    if (raw == null || raw.isEmpty) {
      return (key: fallback, descending: fallbackDescending);
    }
    final descending = raw.startsWith('-');
    final key = allowed[descending ? raw.substring(1) : raw];
    if (key == null) {
      _errors['sort'] =
          'must be one of ${allowed.keys.join(', ')}, '
          'optionally prefixed with - for descending';
      return (key: fallback, descending: fallbackDescending);
    }
    return (key: key, descending: descending);
  }

  int integer(String name, {required int fallback, int min = 0, int? max}) {
    final raw = _params[name];
    if (raw == null || raw.isEmpty) return fallback;
    final value = int.tryParse(raw);
    if (value == null || value < min || (max != null && value > max)) {
      _errors[name] = max == null
          ? 'must be an integer of at least $min'
          : 'must be an integer from $min to $max';
      return fallback;
    }
    return value;
  }

  /// `limit` (1-200, default [defaultLimit]) and `offset`.
  ({int limit, int offset}) page({int defaultLimit = 50}) => (
    limit: integer('limit', fallback: defaultLimit, min: 1, max: 200),
    offset: integer('offset', fallback: 0),
  );

  void error(String name, String message) =>
      _errors.putIfAbsent(name, () => message);

  void throwIfInvalid() {
    if (_errors.isNotEmpty) {
      throw ApiError.badRequest(
        'Some query parameters are invalid',
        details: {'fields': Map.of(_errors)},
      );
    }
  }
}

/// The envelope for offset-paged lists.
Map<String, Object?> pageJson(
  List<Object?> items, {
  required int total,
  required int limit,
  required int offset,
  Map<String, Object?>? extra,
}) => {
  'items': items,
  'total': total,
  'limit': limit,
  'offset': offset,
  ...?extra,
};
