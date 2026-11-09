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
///
/// [tieBreaker] (a unique column) keeps paging stable when sort values
/// repeat, and sorts in the same direction so a two-column index can serve
/// both directions. No sortable column is nullable, so NULLS ordering is left
/// at its default, which is what lets those indexes be used.
String orderBy(
  String expression, {
  required bool descending,
  required String tieBreaker,
}) {
  final direction = descending ? 'DESC' : 'ASC';
  return 'ORDER BY $expression $direction, $tieBreaker $direction';
}
