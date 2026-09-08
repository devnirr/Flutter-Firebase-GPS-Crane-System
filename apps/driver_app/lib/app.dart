import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import 'router.dart';

class DriverApp extends ConsumerWidget {
  const DriverApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(appConfigProvider);

    return MaterialApp.router(
      title: '${config.flavor.appName} · Chofer',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.phone(),
      routerConfig: ref.watch(routerProvider),
      locale: GruaLocalization.spanishDominican,
      supportedLocales: GruaLocalization.supportedLocales,
      localizationsDelegates: GruaLocalization.delegates,
      localeListResolutionCallback: GruaLocalization.resolve,
      builder: (context, child) {
        // Clamped harder than the customer app: the chofer's action button and
        // the amount to collect must stay on one screen at any accessibility
        // setting, and this app is used one-handed at the roadside.
        final scale = MediaQuery.textScalerOf(context).clamp(
          minScaleFactor: 0.9,
          maxScaleFactor: 1.2,
        );
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: scale),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
