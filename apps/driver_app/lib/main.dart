import 'package:grua_core/grua_core.dart';

import 'app.dart';

/// Entry point for the chofer app.
///
/// Signs the demo session in as a seeded chofer rather than the customer, so
/// the same wiring drives an entirely different product.
void main() => runGruaApp(
      appKind: AppKind.driver,
      demoRole: UserRole.driver,
      builder: DriverApp.new,
      backendOverrides: () => demoOverrides(
        role: UserRole.driver,
        actingAs: 'driver-1',
      ),
    );
