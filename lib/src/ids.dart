/// Display IDs. They mirror project_code() and task_code() in the schema:
/// PRJ- plus at least four digits, so PRJ-9999 is followed by PRJ-10000.
library;

final _projectPattern = RegExp(r'^PRJ-(\d{4,9})$');
final _taskPattern = RegExp(r'^PRJ-(\d{4,9})-T-(\d{4,9})$');

String projectCode(int projectId) =>
    'PRJ-${projectId.toString().padLeft(4, '0')}';

String taskCode(int projectId, int taskNumber) =>
    '${projectCode(projectId)}-T-${taskNumber.toString().padLeft(4, '0')}';

/// The project number in [code], or null unless [code] is a canonical
/// project ID (case-insensitive).
int? parseProjectCode(String code) {
  final upper = code.toUpperCase();
  final match = _projectPattern.firstMatch(upper);
  if (match == null) return null;
  final id = int.parse(match.group(1)!);
  return id > 0 && projectCode(id) == upper ? id : null;
}

/// The project and task numbers in [code], or null unless [code] is a
/// canonical task ID (case-insensitive).
({int projectId, int number})? parseTaskCode(String code) {
  final upper = code.toUpperCase();
  final match = _taskPattern.firstMatch(upper);
  if (match == null) return null;
  final projectId = int.parse(match.group(1)!);
  final number = int.parse(match.group(2)!);
  if (projectId < 1 || number < 1 || taskCode(projectId, number) != upper) {
    return null;
  }
  return (projectId: projectId, number: number);
}
