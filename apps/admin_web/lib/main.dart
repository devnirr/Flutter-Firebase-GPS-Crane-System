import 'package:grua_core/grua_core.dart';

import 'app.dart';

/// Entry point for the operations panel.
void main() => runGruaApp(
      appKind: AppKind.admin,
      demoRole: UserRole.admin,
      builder: AdminApp.new,
      backendOverrides: () => demoOverrides(
        role: UserRole.admin,
        actingAs: 'admin-1',
      ),
    );
