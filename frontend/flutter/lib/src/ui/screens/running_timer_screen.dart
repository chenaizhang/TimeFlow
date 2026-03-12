import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/timeflow_repository.dart';
import '../../models/models.dart';
import '../../services/countdown_alert_service.dart';
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
  bool _pauseDialogVisible = false;
  bool _pauseActioning = false;
  bool _pauseLimitAutoEnding = false;

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
    final bool isPaused = model.isPauseActive;
    final Duration pauseRemaining = model.pauseRemainingDuration;
    final Duration remaining = Duration(
      seconds: (targetSeconds - elapsed.inSeconds).clamp(0, targetSeconds),
    );

    if (!isPaused) {
      _pauseLimitAutoEnding = false;
    }

    if (isPaused && !_pauseDialogVisible) {
      _pauseDialogVisible = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        unawaited(_showPauseDialog(context, model));
      });
    }

    if (isPaused &&
        pauseRemaining.inSeconds == 0 &&
        !_pauseLimitAutoEnding &&
        !_stopping) {
      _pauseLimitAutoEnding = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        unawaited(_endPause(model));
      });
    }

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
                      child: OutlinedButton(
                        onPressed:
                            _pauseActioning ||
                                _stopping ||
                                isPaused ||
                                !model.canPause
                            ? null
                            : () => _startPause(model),
                        child: const Text('暂停'),
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

  Future<void> _startPause(AppModel model) async {
    if (_pauseActioning) {
      return;
    }
    setState(() {
      _pauseActioning = true;
    });
    try {
      await model.startPause();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('暂停失败：$error')));
    } finally {
      if (mounted) {
        setState(() {
          _pauseActioning = false;
        });
      }
    }
  }

  Future<void> _endPause(AppModel model) async {
    if (_pauseActioning || !model.isPauseActive) {
      return;
    }
    setState(() {
      _pauseActioning = true;
    });
    try {
      await model.endPause();
      await CountdownAlertService.instance.notifyPauseEndedForeground();
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('结束暂停失败：$error')));
    } finally {
      if (mounted) {
        setState(() {
          _pauseActioning = false;
        });
      }
    }
  }

  Future<void> _showPauseDialog(BuildContext context, AppModel model) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return PopScope(
          canPop: false,
          child: Consumer<AppModel>(
            builder: (BuildContext context, AppModel state, Widget? child) {
              if (!state.isPauseActive) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (dialogContext.mounted &&
                      Navigator.of(dialogContext).canPop()) {
                    Navigator.of(dialogContext).pop();
                  }
                });
                return const SizedBox.shrink();
              }
              final Duration remaining = state.pauseRemainingDuration;
              final String message = '为避免暂停过长时间打断专注，单次计时最多暂停 3 分钟';
              return AlertDialog(
                title: const Text('已暂停'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Center(
                      child: Text(
                        formatClock(remaining),
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      message,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(height: 1.4),
                    ),
                  ],
                ),
                actions: <Widget>[
                  FilledButton(
                    onPressed: _pauseActioning
                        ? null
                        : () async {
                            await _endPause(state);
                            if (!dialogContext.mounted) {
                              return;
                            }
                            Navigator.of(dialogContext).pop();
                          },
                    child: Text(_pauseActioning ? '处理中...' : '结束暂停'),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
    if (mounted) {
      setState(() {
        _pauseDialogVisible = false;
      });
    } else {
      _pauseDialogVisible = false;
    }
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
      final FocusSession? savedSession = await model.stopTimer();
      if (!context.mounted) {
        return;
      }

      if (savedSession != null) {
        await _showPostTimerReflectionDialog(model, savedSession);
      }
      if (!context.mounted) {
        return;
      }

      if (savedSession != null) {
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

  Future<void> _showPostTimerReflectionDialog(
    AppModel model,
    FocusSession session,
  ) async {
    final _TimerReflectionResult? result =
        await showDialog<_TimerReflectionResult>(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext dialogContext) {
            return const _TimerReflectionDialog();
          },
        );
    if (!mounted || result == null) {
      return;
    }
    if (!result.saveNow) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已标记为待补心得，可在专注记录里补填')));
      return;
    }
    try {
      await model.updateFocusSessionNote(
        sessionId: session.id,
        note: result.note,
      );
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('心得已保存')));
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('心得保存失败：$error')));
    }
  }

  Future<void> _notifyCountdownCompleted(ProjectItem project) async {
    await CountdownAlertService.instance.notifyCountdownCompletedForeground(
      enableRingtone: project.enableRingtone,
      enableVibration: project.enableVibration,
    );
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

class _TimerReflectionResult {
  const _TimerReflectionResult({required this.saveNow, required this.note});

  final bool saveNow;
  final String note;
}

class _TimerReflectionDialog extends StatefulWidget {
  const _TimerReflectionDialog();

  @override
  State<_TimerReflectionDialog> createState() => _TimerReflectionDialogState();
}

class _TimerReflectionDialogState extends State<_TimerReflectionDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('本次计时结束'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('记录一下心得，帮助后续复盘。'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _controller,
            maxLines: 4,
            minLines: 3,
            maxLength: 50,
            autofocus: true,
            decoration: const InputDecoration(hintText: '可留空，稍后也可补填'),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(const _TimerReflectionResult(saveNow: false, note: '')),
          child: const Text('稍后再填'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(_TimerReflectionResult(saveNow: true, note: _controller.text)),
          child: const Text('填写并保存'),
        ),
      ],
    );
  }
}
