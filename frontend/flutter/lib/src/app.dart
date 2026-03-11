import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'data/timeflow_repository.dart';
import 'state/app_model.dart';
import 'ui/screens/shell_screen.dart';

class TimeFlowApp extends StatelessWidget {
  const TimeFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme =
        ColorScheme.fromSeed(
          seedColor: const Color(0xFF0D9488),
          brightness: Brightness.light,
        ).copyWith(
          primary: const Color(0xFF0B8A7E),
          onPrimary: Colors.white,
          secondary: const Color(0xFFCF6D19),
          onSecondary: Colors.white,
          surface: const Color(0xFFF7F4EE),
          onSurface: const Color(0xFF1F2937),
          outline: const Color(0xFF98AAA3),
          outlineVariant: const Color(0xFFD3DDD8),
        );

    return Provider<TimeFlowRepository>(
      create: (_) => TimeFlowRepository(),
      child: Builder(
        builder: (BuildContext context) {
          return ChangeNotifierProvider<AppModel>(
            create: (_) {
              final AppModel model = AppModel(
                repository: context.read<TimeFlowRepository>(),
              );
              unawaited(model.initialize());
              return model;
            },
            child: MaterialApp(
              title: '计流',
              debugShowCheckedModeBanner: false,
              locale: const Locale('zh'),
              supportedLocales: const <Locale>[Locale('zh'), Locale('en')],
              localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              theme: ThemeData(
                useMaterial3: true,
                colorScheme: scheme,
                scaffoldBackgroundColor: scheme.surface,
                appBarTheme: AppBarTheme(
                  centerTitle: false,
                  backgroundColor: scheme.surface,
                  foregroundColor: scheme.onSurface,
                  elevation: 0,
                ),
                cardTheme: CardThemeData(
                  elevation: 0,
                  color: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                    side: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: 0.75),
                    ),
                  ),
                ),
                navigationBarTheme: NavigationBarThemeData(
                  backgroundColor: Colors.white,
                  indicatorColor: scheme.primary.withValues(alpha: 0.15),
                  iconTheme: WidgetStateProperty.resolveWith((
                    Set<WidgetState> states,
                  ) {
                    final bool selected = states.contains(WidgetState.selected);
                    return IconThemeData(
                      color: selected
                          ? scheme.primary
                          : scheme.onSurface.withValues(alpha: 0.65),
                    );
                  }),
                  labelTextStyle: WidgetStateProperty.resolveWith((
                    Set<WidgetState> states,
                  ) {
                    final bool selected = states.contains(WidgetState.selected);
                    return TextStyle(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? scheme.primary
                          : scheme.onSurface.withValues(alpha: 0.72),
                    );
                  }),
                ),
                segmentedButtonTheme: SegmentedButtonThemeData(
                  style: ButtonStyle(
                    side: WidgetStatePropertyAll(
                      BorderSide(color: scheme.outlineVariant),
                    ),
                    visualDensity: const VisualDensity(
                      horizontal: -1,
                      vertical: -1,
                    ),
                  ),
                ),
                filledButtonTheme: FilledButtonThemeData(
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.primary,
                    foregroundColor: scheme.onPrimary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                outlinedButtonTheme: OutlinedButtonThemeData(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: scheme.onSurface,
                    side: BorderSide(color: scheme.outline),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
                inputDecorationTheme: InputDecorationTheme(
                  filled: true,
                  fillColor: Colors.white,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: scheme.outlineVariant),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
              ),
              home: const ShellScreen(),
            ),
          );
        },
      ),
    );
  }
}
