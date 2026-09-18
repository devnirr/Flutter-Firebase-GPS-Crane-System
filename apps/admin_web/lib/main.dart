import 'package:grua_core/grua_core.dart';

import 'app.dart';
import 'features/shell/theme_store.dart';
import 'firebase_options.dart';

/// Entry point for the operations panel.
///
/// `demoRole` only applies to the offline fallback; a real session's access is
/// decided by the `role` custom claim, and re-checked server-side in every
/// callable regardless of what the panel allows.
void main() => runGruaApp(
      appKind: AppKind.admin,
      demoRole: UserRole.admin,
      builder: AdminApp.new,
      firebaseOptions: DefaultFirebaseOptions.currentPlatform,
      appOverrides: [
        // Light or dark is remembered per workstation, in the browser.
        themeModeStoreProvider.overrideWithValue(const BrowserThemeModeStore()),
      ],
    );
