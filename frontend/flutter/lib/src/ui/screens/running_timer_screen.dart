import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/timeflow_repository.dart';
import '../../models/models.dart';
import '../../state/app_model.dart';
import '../../utils/time_format.dart';

class RunningTimerScreen extends StatefulWidget {
  const RunningTimerScreen({super.key});

  @override
  State<RunningTimerScreen> createState() => _RunningTimerScreenState();
}

class _RunningTimerScreenState extends State<RunningTimerScreen> {
  bool _stopping = false;
  bool _autoStopTriggered = false;

  @override
  Widget build(BuildContext context) {
    final AppModel model = context.watch<AppModel>();
    final running = model.runningTimer;

    if (running == null) {
      return const Scaffold(body: Center(child: Text('当前没有进行中的计时')));
    }

    final Duration elapsed = model.runningDuration;
    final bool isCountdown = running.isCountdown;
    final int targetSeconds = running.countdownTargetSeconds;
    final Duration remaining = Duration(
      seconds: (targetSeconds - elapsed.inSeconds).clamp(0, targetSeconds),
    );

    if (isCountdown &&
        remaining.inSeconds == 0 &&
        !_stopping &&
        !_autoStopTriggered) {
      _autoStopTriggered = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        unawaited(_notifyCountdownCompleted(running.project));
        _stopTimer(context, model, skipShortConfirm: true);
      });
    }

    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: const Text('正在计时'),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SizedBox(height: 8),
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          formatClock(isCountdown ? remaining : elapsed),
                          style: Theme.of(context).textTheme.displaySmall
                              ?.copyWith(
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          running.project.name,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                fontSize: 13,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurface.withValues(alpha: 0.7),
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          isCountdown ? '倒计时中' : '正向计时中',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: null,
                        icon: const Icon(Icons.pause_outlined),
                        label: const Text('暂停 (v0.2)'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _stopping
                            ? null
                            : () => _stopTimer(
                                context,
                                model,
                                skipShortConfirm: false,
                              ),
                        icon: const Icon(Icons.stop_circle_outlined),
                        label: Text(_stopping ? '结束中...' : '结束计时'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _stopTimer(
    BuildContext context,
    AppModel model, {
    required bool skipShortConfirm,
  }) async {
    final Duration duration = model.runningDuration;
    final bool isShortSession =
        duration.inSeconds < TimeFlowRepository.minimumValidSessionSeconds;

    if (isShortSession && !skipShortConfirm) {
      final bool shouldStop = await _confirmShortSessionDialog(
        context,
        duration,
      );
      if (!mounted || !shouldStop) {
        return;
      }
    }

    setState(() {
      _stopping = true;
    });

    try {
      final bool saved = await model.stopTimer();
      if (!context.mounted) {
        return;
      }

      if (saved) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('记录已保存')));
      }
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('结束计时失败：$error')));
    } finally {
      _autoStopTriggered = false;
      if (mounted) {
        setState(() {
          _stopping = false;
        });
      }
    }
  }

  Future<void> _notifyCountdownCompleted(ProjectItem project) async {
    if (!project.enableVibration && !project.enableRingtone) {
      return;
    }

    if (project.enableRingtone) {
      await SystemSound.play(SystemSoundType.alert);
    }

    if (project.enableVibration) {
      await HapticFeedback.mediumImpact();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await HapticFeedback.mediumImpact();
    }
  }

  Future<bool> _confirmShortSessionDialog(
    BuildContext context,
    Duration duration,
  ) async {
    final bool? shouldStop = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('时长不足 1 分钟'),
          content: Text(
            '当前仅计时 ${formatClock(duration)}，小于 1 分钟不会纳入统计。是否结束本次计时？',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('继续计时'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('结束计时'),
            ),
          ],
        );
      },
    );

    return shouldStop ?? false;
  }
}
