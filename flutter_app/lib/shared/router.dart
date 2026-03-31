import 'package:go_router/go_router.dart';
import '../features/dashboard/dashboard_screen.dart';
import '../features/pr_detail/pr_detail_screen.dart';
import '../features/config/config_screen.dart';

GoRouter createRouter({String initialLocation = '/'}) => GoRouter(
  initialLocation: initialLocation,
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const DashboardScreen(),
    ),
    GoRoute(
      path: '/prs/:id',
      builder: (context, state) {
        final id = int.parse(state.pathParameters['id']!);
        return PRDetailScreen(prId: id);
      },
    ),
    GoRoute(
      path: '/config',
      builder: (context, state) => const ConfigScreen(),
    ),
  ],
);

// Kept for backwards compat with tests that use appRouter directly
final appRouter = createRouter();
