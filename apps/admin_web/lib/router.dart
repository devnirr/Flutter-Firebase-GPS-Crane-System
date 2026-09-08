import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import 'features/auth/admin_login_screen.dart';
import 'features/drivers/drivers_screen.dart';
import 'features/operations/operations_screen.dart';
import 'features/reports/reports_screen.dart';
import 'features/shell/admin_shell.dart';
import 'features/trucks/trucks_screen.dart';

abstract final class Routes {
  static const login = '/entrar';
  static const operations = '/';
  static const services = '/servicios';
  static const drivers = '/choferes';
  static const trucks = '/gruas';
  static const reports = '/reportes';

  static String serviceDetail(String id) => '/servicios?id=$id';
}

/// Router for the operations panel.
///
/// Every route is URL-addressable so a dispatcher can paste a link to a service
/// into WhatsApp and the person who opens it lands on that service, and so a
/// browser refresh does not throw away where they were.
///
/// Permissions are re-checked on the server for every callable regardless of
/// what this table allows. A route guard is a convenience for the person using
/// the panel, never a security boundary.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.operations,
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authStateProvider);
      if (auth.isLoading) return null;

      final signedIn = auth.value != null;
      final location = state.matchedLocation;

      if (!signedIn) return location == Routes.login ? null : Routes.login;
      if (location == Routes.login) return Routes.operations;
      return null;
    },
    routes: [
      GoRoute(path: Routes.login, builder: (_, _) => const AdminLoginScreen()),
      ShellRoute(
        builder: (context, state, child) => AdminShell(
          location: state.matchedLocation,
          child: child,
        ),
        routes: [
          GoRoute(
            path: Routes.operations,
            builder: (_, _) => const OperationsScreen(),
          ),
          GoRoute(
            path: Routes.services,
            builder: (_, state) => OperationsScreen(
              selectedServiceId: state.uri.queryParameters['id'],
            ),
          ),
          GoRoute(path: Routes.drivers, builder: (_, _) => const DriversScreen()),
          GoRoute(path: Routes.trucks, builder: (_, _) => const TrucksScreen()),
          GoRoute(path: Routes.reports, builder: (_, _) => const ReportsScreen()),
        ],
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: EmptyState(
        title: 'Página no encontrada',
        message: 'La dirección ${state.uri} no existe.',
        icon: Icons.error_outline,
        actionLabel: 'Ir a operaciones',
        onAction: () => context.go(Routes.operations),
      ),
    ),
  );
});

class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    _subscription = ref.listen(authStateProvider, (_, _) => notifyListeners());
  }

  late final ProviderSubscription<Object?> _subscription;

  @override
  void dispose() {
    _subscription.close();
    super.dispose();
  }
}
