import 'package:admin_web/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Panel tests.
///
/// The panel is a desktop tool, so these run at a desktop size; the
/// too-small-screen path gets its own test rather than being an accident of the
/// default 800x600 test window.
Future<void> main() async {
  setUpAll(() => initializeDateFormatting('es_DO'));

  const config = AppConfig(
    flavor: Flavor.dev,
    appKind: AppKind.admin,
    firebaseProjectId: 'grua-rd-test',
    googleMapsApiKey: '',
    stripePublishableKey: '',
    useEmulators: false,
    emulatorHost: 'localhost',
    functionsRegion: 'us-east1',
  );

  Widget harness(DemoBackend backend) => ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(
            backend: backend,
            role: UserRole.admin,
            actingAs: 'admin-1',
          ),
        ],
        child: const AdminApp(),
      );

  /// Sets a logical window size.
  ///
  /// `physicalSize` is in device pixels and the test view defaults to a device
  /// pixel ratio of 3, so setting 1440 there actually yields a 480-px logical
  /// window — which silently put every test on the too-small-screen path.
  void setWindow(WidgetTester tester, Size logical) {
    tester.view
      ..devicePixelRatio = 1.0
      ..physicalSize = logical;
    addTearDown(tester.view.reset);
  }

  void setDesktopSize(WidgetTester tester) =>
      setWindow(tester, const Size(1440, 900));

  Future<void> signIn(WidgetTester tester) async {
    await tester.enterText(find.byType(TextFormField).first, 'ops@gruasrd.do');
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  testWidgets('a signed-out visitor gets the login card', (tester) async {
    setDesktopSize(tester);
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();

    expect(find.text('Panel de operaciones'), findsOneWidget);
  });

  testWidgets('signing in lands on operations with the sidebar',
      (tester) async {
    setDesktopSize(tester);
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();

    await signIn(tester);

    expect(find.text('Operaciones'), findsOneWidget);
    expect(find.text('Choferes'), findsWidgets);
    expect(find.text('Servicios activos'), findsOneWidget);
    // FieldLabel uppercases, so the legend renders as 'FLOTA EN LÍNEA'.
    expect(find.text('FLOTA EN LÍNEA'), findsOneWidget);
  });

  testWidgets('the drivers screen lists the seeded fleet', (tester) async {
    setDesktopSize(tester);
    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();
    await signIn(tester);

    await tester.tap(find.text('Choferes').last);
    await tester.pumpAndSettle();

    expect(find.text('Luis Fernández'), findsOneWidget);
    expect(find.text('Pedro Aybar'), findsOneWidget);
    // Cédulas render in the form printed on the card.
    expect(find.text('001-1234567-8'), findsOneWidget);
  });

  testWidgets('a narrow window says so instead of reflowing', (tester) async {
    setWindow(tester, const Size(760, 900));

    await tester.pumpWidget(harness(DemoBackend()..seed()));
    await tester.pumpAndSettle();
    await signIn(tester);

    expect(find.text('Pantalla muy pequeña'), findsOneWidget);
  });
}
