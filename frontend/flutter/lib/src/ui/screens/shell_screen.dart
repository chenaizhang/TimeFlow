import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_model.dart';
import 'running_timer_screen.dart';
import 'stats_screen.dart';
import 'timer_screen.dart';

class ShellScreen extends StatefulWidget {
  const ShellScreen({super.key});

  @override
  State<ShellScreen> createState() => _ShellScreenState();
}

class _ShellScreenState extends State<ShellScreen> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final AppModel model = context.watch<AppModel>();

    if (!model.initialized && model.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final Widget page = model.hasRunningTimer
        ? const RunningTimerScreen(key: ValueKey<String>('running'))
        : Scaffold(
            key: const ValueKey<String>('main'),
            body: IndexedStack(
              index: _currentIndex,
              children: const <Widget>[TimerScreen(), StatsScreen()],
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: (int index) {
                setState(() {
                  _currentIndex = index;
                });
              },
              destinations: const <NavigationDestination>[
                NavigationDestination(
                  icon: Icon(Icons.play_circle_outline),
                  selectedIcon: Icon(Icons.play_circle),
                  label: '计时',
                ),
                NavigationDestination(
                  icon: Icon(Icons.pie_chart_outline),
                  selectedIcon: Icon(Icons.pie_chart),
                  label: '统计',
                ),
              ],
            ),
          );

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 420),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (Widget child, Animation<double> animation) {
        final Animation<double> scale = Tween<double>(begin: 0.98, end: 1)
            .animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            );
        final Animation<Offset> slide =
            Tween<Offset>(
              begin: const Offset(0, 0.04),
              end: Offset.zero,
            ).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            );

        return FadeTransition(
          opacity: animation,
          child: SlideTransition(
            position: slide,
            child: ScaleTransition(scale: scale, child: child),
          ),
        );
      },
      child: page,
    );
  }
}
