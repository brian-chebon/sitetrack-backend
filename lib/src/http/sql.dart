/// An ILIKE pattern matching [search] anywhere, with `%`, `_` and `\` in the
/// search taken literally. Null when there is nothing to search for.
String? containsPattern(String? search) {
  if (search == null) return null;
  final escaped = search
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');
  return '%$escaped%';
}

/// An ORDER BY clause from a whitelisted expression, never from user input.
/// [tieBreaker] keeps paging stable when sort values repeat.
String orderBy(
  String expression, {
  required bool descending,
  required String tieBreaker,
}) =>
    'ORDER BY $expression ${descending ? 'DESC' : 'ASC'} NULLS LAST, $tieBreaker';
