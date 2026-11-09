/// One project's dependency edges, for walking upstream and downstream.
///
/// Task details need every task a task waits on (and every task waiting on
/// it) with its distance in steps. A recursive SQL query can find who is
/// reachable in linear time, but not each one's shortest distance without
/// revisiting nodes once per path, which explodes on dense graphs. A project
/// holds at most a few thousand tasks, so its edges are loaded and walked
/// breadth-first here, visiting each task once.
class TaskGraph {
  TaskGraph(Iterable<(int task, int dependsOn)> edges) {
    for (final (task, dependsOn) in edges) {
      (_dependsOn[task] ??= []).add(dependsOn);
      (_dependents[dependsOn] ??= []).add(task);
    }
  }

  final _dependsOn = <int, List<int>>{};
  final _dependents = <int, List<int>>{};

  /// Every task [task] waits on, directly or not, mapped to its distance.
  Map<int, int> upstream(int task) => _walk(task, _dependsOn);

  /// Every task waiting on [task], directly or not, mapped to its distance.
  Map<int, int> downstream(int task) => _walk(task, _dependents);

  static Map<int, int> _walk(int start, Map<int, List<int>> next) {
    final distance = <int, int>{};
    var frontier = [start];
    for (var step = 1; frontier.isNotEmpty; step++) {
      final following = <int>[];
      for (final node in frontier) {
        for (final neighbour in next[node] ?? const <int>[]) {
          if (neighbour != start && !distance.containsKey(neighbour)) {
            distance[neighbour] = step;
            following.add(neighbour);
          }
        }
      }
      frontier = following;
    }
    return distance;
  }
}
