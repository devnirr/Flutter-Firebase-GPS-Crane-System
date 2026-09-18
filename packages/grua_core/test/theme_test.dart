import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grua_core/grua_core.dart';

void main() {
  group('palette', () {
    test('every theme carries one, matching its brightness', () {
      expect(
        AppTheme.admin().extension<BrandPalette>(),
        same(BrandPalette.light),
      );
      expect(
        AppTheme.adminDark().extension<BrandPalette>(),
        same(BrandPalette.dark),
      );
      expect(
        AppTheme.phone().extension<BrandPalette>(),
        same(BrandPalette.light),
      );
      expect(AppTheme.adminDark().brightness, Brightness.dark);
      expect(AppTheme.adminFor(Brightness.dark).brightness, Brightness.dark);
      expect(AppTheme.adminFor(Brightness.light).brightness, Brightness.light);
    });

    // The phone apps are light-only, so the light palette must stay exactly
    // the constants their screens were built against.
    test('the light palette is the old palette', () {
      expect(BrandPalette.light.surface, BrandColors.white);
      expect(BrandPalette.light.canvas, BrandColors.offWhite);
      expect(BrandPalette.light.text, BrandColors.ink);
      expect(BrandPalette.light.textMuted, BrandColors.grey600);
      expect(BrandPalette.light.border, BrandColors.grey200);
      expect(BrandPalette.light.brand, BrandColors.red);
    });

    test('the dark one is dark, and keeps white on red', () {
      expect(BrandPalette.dark.isDark, isTrue);
      expect(BrandPalette.dark.surface.computeLuminance(), lessThan(0.1));
      expect(BrandPalette.dark.text.computeLuminance(), greaterThan(0.8));
      expect(BrandPalette.dark.onBrand, BrandColors.white);
    });

    testWidgets('context.palette follows the theme', (tester) async {
      late BrandPalette seen;
      Widget page(ThemeData theme) => MaterialApp(
            theme: theme,
            home: Builder(
              builder: (context) {
                seen = context.palette;
                return const SizedBox();
              },
            ),
          );

      await tester.pumpWidget(page(AppTheme.admin()));
      expect(seen.isDark, isFalse);

      await tester.pumpWidget(page(AppTheme.adminDark()));
      // MaterialApp cross-fades between themes, so the dark palette only
      // lands once that animation is over.
      await tester.pumpAndSettle();
      expect(seen.isDark, isTrue);
    });

    testWidgets('a screen built without our theme still gets one',
        (tester) async {
      late BrandPalette seen;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              seen = context.palette;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(seen, same(BrandPalette.light));
    });
  });

  group('theme mode', () {
    test('starts from what was stored, and writes every change', () {
      final store = InMemoryThemeModeStore(ThemeMode.dark);
      final container = ProviderContainer(
        overrides: [themeModeStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);

      expect(container.read(themeModeProvider), ThemeMode.dark);

      container.read(themeModeProvider.notifier).set(ThemeMode.light);
      expect(container.read(themeModeProvider), ThemeMode.light);
      expect(store.read(), ThemeMode.light);
    });

    test('with nothing stored it follows the machine', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(themeModeProvider), ThemeMode.system);
    });

    test('the toggle goes to the opposite of what is on screen', () {
      final container = ProviderContainer(
        overrides: [
          themeModeStoreProvider.overrideWithValue(InMemoryThemeModeStore()),
        ],
      );
      addTearDown(container.dispose);

      // Following a dark machine: pressing it means "give me light".
      container.read(themeModeProvider.notifier).toggle(Brightness.dark);
      expect(container.read(themeModeProvider), ThemeMode.light);

      container.read(themeModeProvider.notifier).toggle(Brightness.light);
      expect(container.read(themeModeProvider), ThemeMode.dark);
    });

    test('names survive a round trip, and junk falls back', () {
      for (final mode in ThemeMode.values) {
        expect(themeModeFromStoredName(mode.storedName), mode);
      }
      expect(themeModeFromStoredName('sepia'), isNull);
      expect(themeModeFromStoredName(null), isNull);
    });

    test('a store that cannot remember anything is harmless', () {
      const store = NoThemeModeStore();
      store.write(ThemeMode.dark);
      expect(store.read(), isNull);
    });
  });

  group('RNC field', () {
    String typed(String input) => RncInputFormatter()
        .formatEditUpdate(
          TextEditingValue.empty,
          TextEditingValue(text: input),
        )
        .text;

    test('groups nine digits the way the DGII prints them', () {
      expect(typed('130000001'), '1-30-00000-1');
      expect(typed('1'), '1');
      expect(typed('130'), '1-30');
      expect(typed('13000'), '1-30-00');
    });

    test('leaves an eleven-digit number alone and refuses a longer one', () {
      expect(typed('00112345678'), '00112345678');
      expect(typed('0011234567890'), '00112345678');
    });

    test('drops anything that is not a digit', () {
      expect(typed('1-30-00000-1'), '1-30-00000-1');
      expect(typed('RNC 130000001'), '1-30-00000-1');
    });
  });
}
