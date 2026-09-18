// TEMPORARY: renders the tariff page. Delete when done.
import 'dart:io';

import 'package:admin_web/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';
import 'package:intl/date_symbol_data_local.dart';

Future<void> loadFonts() async {
  final dir = Directory(
    r'C:\Users\Sven\develop\flutter\bin\cache\artifacts\material_fonts',
  );
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final file in files) {
      final f = File('${dir.path}/$file');
      if (f.existsSync()) {
        loader.addFont(Future.value(f.readAsBytesSync().buffer.asByteData()));
      }
    }
    await loader.load();
  }

  await load('Roboto', [
    'roboto-regular.ttf',
    'roboto-medium.ttf',
    'roboto-bold.ttf',
  ]);
  await load('MaterialIcons', ['materialicons-regular.otf']);
}

Future<void> main() async {
  setUpAll(() async {
    await initializeDateFormatting('es_DO');
    await loadFonts();
  });

  const config = AppConfig(
    flavor: Flavor.dev,
    appKind: AppKind.admin,
    firebaseProjectId: 'grua-rd-test',
    googleMapsApiKey: '',
    useEmulators: false,
    emulatorHost: 'localhost',
    functionsRegion: 'us-east1',
  );

  Future<void> openTariff(WidgetTester tester, Size size) async {
    tester.view
      ..devicePixelRatio = 1.0
      ..physicalSize = size;
    addTearDown(tester.view.reset);

    final backend = DemoBackend()..seed();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appConfigProvider.overrideWithValue(config),
          ...demoOverrides(
            backend: backend,
            role: UserRole.admin,
            actingAs: 'admin-1',
          ),
        ],
        child: const AdminApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'ops@gruasrd.do');
    await tester.enterText(find.byType(TextFormField).last, 'secret123');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entrar'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    await tester.tap(find.text('Aseguradoras'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-default-tariff')));
    await tester.pumpAndSettle();
  }

  testWidgets('tariff page, wide', (tester) async {
    await openTariff(tester, const Size(1720, 1000));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/tariff_wide.png'),
    );
  });

  testWidgets('tariff page, dark', (tester) async {
    await openTariff(tester, const Size(1440, 900));
    await tester.tap(find.byKey(const Key('theme-toggle')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/tariff_dark.png'),
    );
  });
}
