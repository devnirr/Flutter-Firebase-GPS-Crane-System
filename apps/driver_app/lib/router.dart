import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:grua_core/grua_core.dart';

import 'features/auth/blocked_screen.dart';
import 'features/auth/login_screen.dart';
import 'features/earnings/earnings_screen.dart';
import 'features/home/driver_home_screen.dart';
import 'features/service/active_service_screen.dart';

abstract final class Routes {
  static const login = '/entrar';
  static const blocked = '/cuenta-bloqueada';
  static const home = '/';
  static const activeService = '/servicio';
  static const earnings = '/ganancias';
}

/// Router for the chofer app.
///
/// There is deliberately no sign-up route anywhere in this table. Choferes are
/// created by an admin; a chofer who can register themselves is a chofer who
/// can work without documents on file, which is the thing the whole account
/// lifecycle exists to prevent.
///
/// The other rule is that an active job wins. If `currentServiceId` is set, the
/// chofer goes to the service screen no matter where they were headed — a
/// force-quit mid-tow reopens on the tow.
final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _RouterRefresh(ref);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    initialLocation: Routes.home,
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authStateProvider);
      if (auth.isLoading) return null;

      final location = state.matchedLocation;
      if (auth.value == null) {
        return location == Routes.login ? null : Routes.login;
      }

      final driver = ref.read(currentDriverProvider).value;
      // Hold still until the chofer record arrives; bouncing to the blocked
      // screen on a null we have not loaded yet reads as a suspension.
      if (driver == null) return location == Routes.login ? Routes.home : null;

      if (!driver.status.canWork) {
        return location == Routes.blocked ? null : Routes.blocked;
      }

      if (location == Routes.login || location == Routes.blocked) {
        return Routes.home;
      }

      final active = ref.read(activeDriverServiceProvider).value;
      if (active != null && location == Routes.home) return Routes.activeService;
      if (active == null && location == Routes.activeService) return Routes.home;

      return null;
    },
    routes: [
      GoRoute(path: Routes.login, builder: (_, _) => const LoginScreen()),
      GoRoute(path: Routes.blocked, builder: (_, _) => const BlockedScreen()),
      GoRoute(path: Routes.home, builder: (_, _) => const DriverHomeScreen()),
      GoRoute(
        path: Routes.activeService,
        builder: (_, _) => const ActiveServiceScreen(),
      ),
      GoRoute(path: Routes.earnings, builder: (_, _) => const EarningsScreen()),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: EmptyState(
        title: 'Página no encontrada',
        message: 'La dirección ${state.uri} no existe.',
        icon: Icons.error_outline,
        actionLabel: 'Ir al inicio',
        onAction: () => context.go(Routes.home),
      ),
    ),
  );
});

class _RouterRefresh extends ChangeNotifier {
  _RouterRefresh(Ref ref) {
    _subscriptions = [
      ref.listen(authStateProvider, (_, _) => notifyListeners()),
      ref.listen(currentDriverProvider, (_, _) => notifyListeners()),
      ref.listen(activeDriverServiceProvider, (_, _) => notifyListeners()),
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
