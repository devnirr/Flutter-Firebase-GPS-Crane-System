import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import 'features/auth/admin_login_screen.dart';
import 'features/cash/cash_screen.dart';
import 'features/clients/clients_screen.dart';
import 'features/drivers/drivers_screen.dart';
import 'features/operations/operations_screen.dart';
import 'features/reports/reports_screen.dart';
import 'features/services/services_screen.dart';
import 'features/shell/admin_shell.dart';
import 'features/trucks/trucks_screen.dart';

abstract final class Routes {
  static const login = '/entrar';
  static const operations = '/';
  static const services = '/servicios';
  static const clients = '/clientes';
  static const drivers = '/choferes';
  static const trucks = '/gruas';
  static const reports = '/reportes';
  static const cash = '/efectivo';

  /// The Servicios page with one service's record open.
  static String serviceDetail(String id) => '/servicios?id=$id';

  /// The map with one live service selected.
  static String operationsFor(String id) => '/?id=$id';

  /// The Servicios page with a search already typed in.
  static String servicesSearch(String query) =>
      Uri(path: services, queryParameters: {'q': query}).toString();
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

      // A session restored from a page refresh never passes through the login
      // screen, so the staff check has to live here too. Without it an account
      // with no role lands in the panel and every query fails with a
      // permission error that reads like an outage.
      final role = ref.read(currentRoleProvider);
      if (role.isLoading) return null;
      if (!(role.value ?? UserRole.unknown).isStaff) {
        return location == Routes.login ? null : Routes.login;
      }

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
            builder: (_, state) => OperationsScreen(
              selectedServiceId: state.uri.queryParameters['id'],
            ),
          ),
          GoRoute(
            path: Routes.services,
            builder: (_, state) => ServicesScreen(
              initialQuery: state.uri.queryParameters['q'],
              openServiceId: state.uri.queryParameters['id'],
            ),
          ),
          GoRoute(path: Routes.clients, builder: (_, _) => const ClientsScreen()),
          GoRoute(path: Routes.drivers, builder: (_, _) => const DriversScreen()),
          GoRoute(path: Routes.trucks, builder: (_, _) => const TrucksScreen()),
          GoRoute(path: Routes.reports, builder: (_, _) => const ReportsScreen()),
          GoRoute(path: Routes.cash, builder: (_, _) => const CashScreen()),
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
    // The role matters as much as the session: the redirect refuses anyone
    // without a staff claim, so it has to re-run when that claim arrives.
    _subscriptions = [
      ref.listen(authStateProvider, (_, _) => notifyListeners()),
      ref.listen(currentRoleProvider, (_, _) => notifyListeners()),
    ];
  }

  late final List<ProviderSubscription<Object?>> _subscriptions;

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.close();
    }
    super.dispose();
  }
}
