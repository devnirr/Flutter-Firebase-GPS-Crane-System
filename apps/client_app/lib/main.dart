import 'package:grua_core/grua_core.dart';

import 'app.dart';

/// Entry point for the customer app.
///
/// All initialization lives in `runGruaApp` so the three products cannot drift
/// in startup order, error capture or locale setup.
void main() => runGruaApp(
      appKind: AppKind.client,
      builder: ClientApp.new,
    );
