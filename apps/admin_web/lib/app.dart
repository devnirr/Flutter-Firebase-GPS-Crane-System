import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:grua_core/grua_core.dart';

import 'router.dart';

class AdminApp extends ConsumerWidget {
  const AdminApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(appConfigProvider);

    return MaterialApp.router(
      title: '${config.flavor.appName} · Panel',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.admin(),
      darkTheme: AppTheme.adminDark(),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: ref.watch(routerProvider),
      locale: GruaLocalization.spanishDominican,
      supportedLocales: GruaLocalization.supportedLocales,
      localizationsDelegates: GruaLocalization.delegates,
      localeListResolutionCallback: GruaLocalization.resolve,
    );
  }
}
