import 'package:grua_core/grua_core.dart';

import 'app.dart';
import 'firebase_options.dart';

/// Entry point for the chofer app.
///
/// `demoRole` only matters when Firebase is unavailable and the app falls back
/// to the in-memory backend; against Firestore the role comes from the signed-in
/// user's custom claims.
void main() => runGruaApp(
      appKind: AppKind.driver,
      demoRole: UserRole.driver,
      builder: DriverApp.new,
      firebaseOptions: DefaultFirebaseOptions.currentPlatform,
    );
