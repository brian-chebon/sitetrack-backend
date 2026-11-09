import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import 'auth/auth_routes.dart';
import 'auth/auth_service.dart';
import 'auth/passwords.dart';
import 'auth/tokens.dart';
import 'config.dart';
import 'db/database.dart';
import 'http/api_error.dart';
import 'http/json.dart';
import 'http/middleware.dart';
import 'notifications/notification_routes.dart';
import 'projects/member_routes.dart';
import 'projects/project_routes.dart';
import 'stock/company_store_routes.dart';
import 'stock/material_routes.dart';
import 'stock/project_store_routes.dart';
import 'tasks/task_routes.dart';
import 'users/user_routes.dart';

/// Builds the API's request handler.
///
/// Everything under `/v1/` except register, login and refresh goes through
/// [authenticate], which resolves the caller from the database on every
/// request. Access to projects and stores is then checked by each handler.
Handler buildApp(Database db, Config config) {
  final passwords = PasswordHasher(cost: config.bcryptCost);
  final tokens = AccessTokens(config.jwtSecret, config.accessTokenTtl);
  final auth = AuthService(db, config, passwords, tokens);

  final authRoutes = AuthRoutes(auth);
  final users = UserRoutes(db);
  final projects = ProjectRoutes(db);
  final members = MemberRoutes(db);
  final notifications = NotificationRoutes(db);
  final tasks = TaskRoutes(db);
  final materials = MaterialRoutes(db);
  final companyStore = CompanyStoreRoutes(db);
  final projectStore = ProjectStoreRoutes(db);

  final protected = Router(notFoundHandler: _notFound)
    ..post('/auth/logout', authRoutes.logout)
    ..get('/me', users.me)
    ..get('/users', users.search)
    ..patch('/users/<userId>/role', users.changeRole)
    // Notifications and invitations addressed to the caller
    ..get('/notifications', notifications.list)
    ..get('/notifications/unread-count', notifications.unreadCount)
    ..post('/notifications/read', notifications.markRead)
    ..post('/invitations/<invitationId>/accept', notifications.accept)
    ..post('/invitations/<invitationId>/reject', notifications.reject)
    // Projects
    ..get('/projects', projects.list)
    ..post('/projects', projects.create)
    ..get('/projects/<projectId>', projects.get)
    ..patch('/projects/<projectId>', projects.update)
    ..delete('/projects/<projectId>', projects.remove)
    // Members and invitations
    ..get('/projects/<projectId>/members', members.list)
    ..patch('/projects/<projectId>/members/<userId>', members.update)
    ..delete('/projects/<projectId>/members/<userId>', members.remove)
    ..post('/projects/<projectId>/invitations', members.invite)
    ..delete(
      '/projects/<projectId>/invitations/<invitationId>',
      members.withdraw,
    )
    // Tasks, dependencies and status actions
    ..get('/projects/<projectId>/tasks', tasks.list)
    ..post('/projects/<projectId>/tasks', tasks.create)
    ..get('/projects/<projectId>/tasks/<taskId>', tasks.get)
    ..patch('/projects/<projectId>/tasks/<taskId>', tasks.update)
    ..delete('/projects/<projectId>/tasks/<taskId>', tasks.remove)
    ..post('/projects/<projectId>/tasks/<taskId>/start', tasks.start)
    ..post('/projects/<projectId>/tasks/<taskId>/complete', tasks.complete)
    ..post('/projects/<projectId>/tasks/<taskId>/reopen', tasks.reopen)
    ..put(
      '/projects/<projectId>/tasks/<taskId>/dependencies/<dependsOnId>',
      tasks.addDependency,
    )
    ..delete(
      '/projects/<projectId>/tasks/<taskId>/dependencies/<dependsOnId>',
      tasks.removeDependency,
    )
    // Project store and its deliveries
    ..get('/projects/<projectId>/store', projectStore.stock)
    ..get('/projects/<projectId>/deliveries', projectStore.deliveries)
    ..post('/projects/<projectId>/deliveries', projectStore.send)
    ..get(
      '/projects/<projectId>/deliveries/<deliveryId>',
      projectStore.delivery,
    )
    ..post(
      '/projects/<projectId>/deliveries/<deliveryId>/record',
      projectStore.record,
    )
    ..post(
      '/projects/<projectId>/deliveries/<deliveryId>/reject',
      projectStore.reject,
    )
    ..post(
      '/projects/<projectId>/deliveries/<deliveryId>/cancel',
      projectStore.cancel,
    )
    // Materials catalogue
    ..get('/materials', materials.list)
    ..get('/materials/categories', materials.categories)
    ..post('/materials', materials.create)
    ..get('/materials/<materialId>', materials.get)
    ..patch('/materials/<materialId>', materials.update)
    ..delete('/materials/<materialId>', materials.remove)
    // Company store
    ..get('/company-store/stock', companyStore.stock)
    ..patch('/company-store/stock/<materialId>', companyStore.setReorderPoint)
    ..post('/company-store/stock-additions', companyStore.addStock)
    ..get('/company-store/projects', companyStore.projects)
    ..get('/company-store/deliveries', companyStore.deliveries)
    ..post('/company-store/deliveries', companyStore.send)
    ..get('/company-store/deliveries/<deliveryId>', companyStore.delivery)
    ..post('/company-store/deliveries/<deliveryId>/record', companyStore.record)
    ..post('/company-store/deliveries/<deliveryId>/reject', companyStore.reject)
    ..post(
      '/company-store/deliveries/<deliveryId>/cancel',
      companyStore.cancel,
    );

  final root = Router(notFoundHandler: _notFound)
    ..get('/health', (Request request) async {
      await db.query('SELECT 1');
      return jsonResponse({'status': 'ok'});
    })
    ..post('/v1/auth/register', authRoutes.register)
    ..post('/v1/auth/login', authRoutes.login)
    ..post('/v1/auth/refresh', authRoutes.refresh)
    ..mount(
      '/v1/',
      const Pipeline()
          .addMiddleware(authenticate(auth))
          .addHandler(protected.call),
    );

  var pipeline = const Pipeline();
  if (config.logRequests) {
    pipeline = pipeline.addMiddleware(logRequestTimings());
  }
  return pipeline
      .addMiddleware(cors())
      .addMiddleware(handleErrors())
      .addHandler(root.call);
}

Response _notFound(Request request) =>
    jsonResponse(ApiError.notFound('No such endpoint').toJson(), status: 404);
