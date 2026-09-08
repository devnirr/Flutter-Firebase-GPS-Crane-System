import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import 'router.dart';

class ClientApp extends ConsumerWidget {
  const ClientApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(appConfigProvider);

    return MaterialApp.router(
      title: config.flavor.appName,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.phone(),
      routerConfig: ref.watch(routerProvider),
      locale: GruaLocalization.spanishDominican,
      supportedLocales: GruaLocalization.supportedLocales,
      localizationsDelegates: GruaLocalization.delegates,
      localeListResolutionCallback: GruaLocalization.resolve,
      builder: (context, child) {
        // Clamp text scaling: the request and tracking screens carry an
        // address and a price that must stay readable together, and Android's
        // largest accessibility setting otherwise pushes the price off-screen.
        final scale = MediaQuery.textScalerOf(context).clamp(
          minScaleFactor: 0.9,
          maxScaleFactor: 1.3,
        );
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: scale),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
