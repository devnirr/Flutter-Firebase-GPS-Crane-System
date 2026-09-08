import 'package:grua_core/grua_core.dart';

import 'app.dart';
import 'firebase_options.dart';

/// Entry point for the customer app.
///
/// All initialization lives in `runGruaApp` so the three products cannot drift
/// in startup order, error capture or locale setup. Supplying
/// [DefaultFirebaseOptions] is the whole switch between Firestore and the
/// in-memory demo backend; if initialization fails, the app falls back rather
/// than showing a crash screen.
void main() => runGruaApp(
      appKind: AppKind.client,
      builder: ClientApp.new,
      firebaseOptions: DefaultFirebaseOptions.currentPlatform,
    );
