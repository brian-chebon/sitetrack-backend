import 'dart:math';

/// How much data the seeder writes. [SeedPlan.scaled] with 1.0 matches the
/// brief's test volumes (and goes slightly over where rounding falls short,
/// since the brief says "at least").
class SeedPlan {
  SeedPlan({
    required this.users,
    required this.projects,
    required this.bigProjects,
    required this.bigProjectTasks,
    required this.tasks,
    required this.materials,
    required this.deliveriesOut,
    required this.deliveriesBack,
    required this.invitationsPerProject,
  });

  factory SeedPlan.scaled(double scale) {
    int at(num full, int minimum) => max(minimum, (full * scale).round());
    final projects = at(2000, 20);
    final bigProjects = min(projects ~/ 4, at(10, 1));
    return SeedPlan(
      users: at(5000, 120),
      projects: projects,
      bigProjects: bigProjects,
      bigProjectTasks: scale >= 1
          ? 3000
          : min(3000, max(60, (15000 * scale).round())),
      tasks: at(500000, 2000),
      materials: at(20000, 400),
      deliveriesOut: at(340000, 2000),
      deliveriesBack: at(60000, 300),
      invitationsPerProject: 25,
    );
  }

  /// Users; the first three are the demo accounts.
  final int users;
  final int projects;

  /// Projects with [bigProjectTasks] tasks each; the rest share the
  /// remaining tasks unevenly.
  final int bigProjects;
  final int bigProjectTasks;
  final int tasks;
  final int materials;

  /// Company store to project store.
  final int deliveriesOut;

  /// Returns to the company store, each mirroring a delivered one.
  final int deliveriesBack;
  final int invitationsPerProject;

  /// How many catalogue materials each project draws its deliveries from.
  int get materialsPerProject => min(300, materials);

  /// Members per project besides the creator: at most 47, so with the
  /// creator and a demo user a project never passes 50.
  int get maxExtraMembers => min(46, users - 4);

  @override
  String toString() =>
      '$users users, $projects projects ($bigProjects with $bigProjectTasks '
      'tasks), ~$tasks tasks, $materials materials, '
      '${deliveriesOut + deliveriesBack} deliveries';
}
