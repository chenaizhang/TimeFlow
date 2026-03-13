import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/timeflow_repository.dart';
import '../models/models.dart';
import '../services/countdown_alert_service.dart';

class AppModel extends ChangeNotifier with WidgetsBindingObserver {
  AppModel({required TimeFlowRepository repository}) : _repository = repository;

  final TimeFlowRepository _repository;
  final CountdownAlertService _countdownAlertService =
      CountdownAlertService.instance;

  bool _initialized = false;
  bool _loading = false;
  String? _lastError;
  int _dataVersion = 0;

  List<ProjectGroupBundle> _bundles = <ProjectGroupBundle>[];
  RunningTimerInfo? _runningTimer;
  DateTime _now = DateTime.now();
  Timer? _ticker;
  bool _resyncingFromBackground = false;

  bool get initialized => _initialized;
  bool get loading => _loading;
  String? get lastError => _lastError;
  int get dataVersion => _dataVersion;
  bool get resyncingFromBackground => _resyncingFromBackground;

  List<ProjectGroupBundle> get bundles => _bundles;
  RunningTimerInfo? get runningTimer => _runningTimer;
  bool get hasRunningTimer => _runningTimer != null;

  Duration get runningDuration {
    if (_runningTimer == null) {
      return Duration.zero;
    }
    final CurrentTimer timer = _runningTimer!.timer;
    final Duration gross = _now.difference(timer.startTime);
    if (gross.isNegative) {
      return Duration.zero;
    }
    final int activeSeconds = gross.inSeconds - _pauseConsumedSeconds(timer);
    if (activeSeconds <= 0) {
      return Duration.zero;
    }
    return Duration(seconds: activeSeconds);
  }

  bool get isPauseActive => _runningTimer?.timer.isPaused ?? false;

  int get pauseRemainingSeconds {
    if (_runningTimer == null) {
      return 0;
    }
    final int remaining =
        RunningTimerInfo.pauseBudgetSeconds -
        _pauseConsumedSeconds(_runningTimer!.timer);
    return remaining <= 0 ? 0 : remaining;
  }

  Duration get pauseRemainingDuration =>
      Duration(seconds: pauseRemainingSeconds);

  bool get canPause =>
      _runningTimer != null && !isPauseActive && pauseRemainingSeconds > 0;

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    WidgetsBinding.instance.addObserver(this);
    await _countdownAlertService.initialize();
    await refreshAll();
    _initialized = true;
  }

  Future<void> refreshAll() async {
    _setLoading(true);
    try {
      final List<ProjectGroupBundle> bundles = await _repository
          .fetchProjectBundles();
      final RunningTimerInfo? runningTimer = await _repository
          .getRunningTimer();

      _bundles = bundles;
      _runningTimer = runningTimer;
      _lastError = null;
      _updateTickerStatus();
      unawaited(_syncBackgroundReminders());
      notifyListeners();
    } catch (error) {
      _lastError = error.toString();
      notifyListeners();
    } finally {
      _setLoading(false);
    }
  }

  Future<void> createGroup(String name) async {
    await _runMutation(() => _repository.createGroup(name));
  }

  Future<void> updateGroup({required int groupId, required String name}) async {
    await _runMutation(
      () => _repository.updateGroup(groupId: groupId, name: name),
    );
  }

  Future<void> deleteGroup(int groupId) async {
    await _runMutation(() => _repository.deleteGroup(groupId));
  }

  Future<void> createProject({
    required String name,
    required int groupId,
    required String timerMode,
    required int countdownSeconds,
    required bool enableVibration,
    required bool enableRingtone,
  }) async {
    await _runMutation(
      () => _repository.createProject(
        name: name,
        groupId: groupId,
        timerMode: timerMode,
        countdownSeconds: countdownSeconds,
        enableVibration: enableVibration,
        enableRingtone: enableRingtone,
      ),
    );
  }

  Future<void> updateProject({
    required int projectId,
    required String name,
    required int groupId,
    required String timerMode,
    required int countdownSeconds,
    required bool enableVibration,
    required bool enableRingtone,
  }) async {
    await _runMutation(
      () => _repository.updateProject(
        projectId: projectId,
        name: name,
        groupId: groupId,
        timerMode: timerMode,
        countdownSeconds: countdownSeconds,
        enableVibration: enableVibration,
        enableRingtone: enableRingtone,
      ),
    );
  }

  Future<void> deleteProject(int projectId) async {
    await _runMutation(() => _repository.deleteProject(projectId));
  }

  Future<void> deleteFocusSession(int sessionId) async {
    await _runMutation(() => _repository.deleteFocusSession(sessionId));
  }

  Future<String?> updateFocusSessionNote({
    required int sessionId,
    required String note,
  }) async {
    String? normalizedNote;
    await _runMutation(() async {
      normalizedNote = await _repository.updateFocusSessionNote(
        sessionId: sessionId,
        note: note,
      );
    });
    return normalizedNote;
  }

  Future<void> startTimer(int projectId) async {
    await _runMutation(() => _repository.startTimer(projectId));
  }

  Future<FocusSession?> stopTimer() async {
    FocusSession? savedSession;
    await _runMutation(() async {
      final FocusSession? session = await _repository.stopTimer();
      savedSession = session;
    });
    return savedSession;
  }

  Future<void> startPause() async {
    await _runMutation(() => _repository.startPause());
  }

  Future<void> endPause() async {
    await _runMutation(() => _repository.endPause());
  }

  Future<void> _runMutation(Future<void> Function() action) async {
    _setLoading(true);
    try {
      await action();
      _lastError = null;
      _dataVersion += 1;
      _bundles = await _repository.fetchProjectBundles();
      _runningTimer = await _repository.getRunningTimer();
      _updateTickerStatus();
      unawaited(_syncBackgroundReminders());
      notifyListeners();
    } catch (error) {
      _lastError = error.toString();
      rethrow;
    } finally {
      _setLoading(false);
    }
  }

  void _setLoading(bool value) {
    if (_loading == value) {
      return;
    }
    _loading = value;
    notifyListeners();
  }

  void _updateTickerStatus() {
    if (_runningTimer == null) {
      _ticker?.cancel();
      _ticker = null;
      return;
    }

    _ticker ??= Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      _now = DateTime.now();
      notifyListeners();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _resyncingFromBackground = true;
        notifyListeners();
        unawaited(_handleResumeRefresh());
        break;
      case AppLifecycleState.inactive:
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(_syncBackgroundReminders());
        break;
    }
  }

  Future<void> _handleResumeRefresh() async {
    try {
      await _syncBackgroundReminders();
      await refreshAll();
    } finally {
      _resyncingFromBackground = false;
      notifyListeners();
    }
  }

  int _pauseConsumedSeconds(CurrentTimer timer) {
    int consumed = timer.pausedSecondsTotal;
    final DateTime? pauseStartedAt = timer.pauseStartedAt;
    if (pauseStartedAt != null) {
      final int runningPauseSeconds = _now.difference(pauseStartedAt).inSeconds;
      if (runningPauseSeconds > 0) {
        final int remainingForThisSession =
            RunningTimerInfo.pauseBudgetSeconds - consumed;
        final int capped = remainingForThisSession <= 0
            ? 0
            : (runningPauseSeconds > remainingForThisSession
                  ? remainingForThisSession
                  : runningPauseSeconds);
        consumed += capped;
      }
    }
    if (consumed <= 0) {
      return 0;
    }
    if (consumed >= RunningTimerInfo.pauseBudgetSeconds) {
      return RunningTimerInfo.pauseBudgetSeconds;
    }
    return consumed;
  }

  Future<void> _syncBackgroundReminders() async {
    final RunningTimerInfo? running = _runningTimer;
    await _syncOngoingProgressNotification(running);
    if (running == null) {
      await _countdownAlertService.cancelBackgroundCountdownReminder();
      await _countdownAlertService.cancelBackgroundPauseReminder();
      return;
    }

    if (running.timer.isPaused) {
      final int consumed = running.timer.pausedSecondsTotal.clamp(
        0,
        RunningTimerInfo.pauseBudgetSeconds,
      );
      final int remaining = RunningTimerInfo.pauseBudgetSeconds - consumed;
      final DateTime? pauseStartedAt = running.timer.pauseStartedAt;
      if (pauseStartedAt == null || remaining <= 0) {
        await _countdownAlertService.cancelBackgroundCountdownReminder();
        await _countdownAlertService.cancelBackgroundPauseReminder();
        return;
      }
      final DateTime pauseEndsAt = pauseStartedAt.add(
        Duration(seconds: remaining),
      );
      if (!pauseEndsAt.isAfter(DateTime.now())) {
        await _countdownAlertService.cancelBackgroundCountdownReminder();
        await _countdownAlertService.cancelBackgroundPauseReminder();
        return;
      }

      if (running.isCountdown) {
        final ProjectItem project = running.project;
        if (!project.enableRingtone && !project.enableVibration) {
          await _countdownAlertService.cancelBackgroundCountdownReminder();
        } else {
          final DateTime countdownEndsAt = running.timer.startTime.add(
            Duration(
              seconds:
                  running.countdownTargetSeconds +
                  RunningTimerInfo.pauseBudgetSeconds,
            ),
          );
          if (!countdownEndsAt.isAfter(DateTime.now())) {
            await _countdownAlertService.cancelBackgroundCountdownReminder();
          } else {
            await _countdownAlertService.scheduleBackgroundCountdownReminder(
              endTime: countdownEndsAt,
              projectName: project.name,
              enableRingtone: project.enableRingtone,
              enableVibration: project.enableVibration,
            );
          }
        }
      } else {
        await _countdownAlertService.cancelBackgroundCountdownReminder();
      }

      await _countdownAlertService.cancelBackgroundPauseReminder();
      return;
    }

    await _countdownAlertService.cancelBackgroundPauseReminder();

    final ProjectItem project = running.project;
    if (!project.enableRingtone && !project.enableVibration) {
      await _countdownAlertService.cancelBackgroundCountdownReminder();
      return;
    }

    if (!running.isCountdown) {
      await _countdownAlertService.cancelBackgroundCountdownReminder();
      return;
    }

    final int consumedPauseSeconds = running.timer.pausedSecondsTotal.clamp(
      0,
      RunningTimerInfo.pauseBudgetSeconds,
    );
    final DateTime endTime = running.timer.startTime.add(
      Duration(seconds: running.countdownTargetSeconds + consumedPauseSeconds),
    );
    if (!endTime.isAfter(DateTime.now())) {
      await _countdownAlertService.cancelBackgroundCountdownReminder();
      return;
    }

    await _countdownAlertService.scheduleBackgroundCountdownReminder(
      endTime: endTime,
      projectName: project.name,
      enableRingtone: project.enableRingtone,
      enableVibration: project.enableVibration,
    );
  }

  Future<void> _syncOngoingProgressNotification(
    RunningTimerInfo? running,
  ) async {
    if (running == null) {
      await _countdownAlertService.stopOngoingProgress();
      return;
    }

    final DateTime now = DateTime.now();
    if (running.timer.isPaused) {
      final int consumed = running.timer.pausedSecondsTotal.clamp(
        0,
        RunningTimerInfo.pauseBudgetSeconds,
      );
      final int remaining = RunningTimerInfo.pauseBudgetSeconds - consumed;
      final DateTime? pauseStartedAt = running.timer.pauseStartedAt;
      if (pauseStartedAt == null || remaining <= 0) {
        await _countdownAlertService.stopOngoingProgress();
        return;
      }

      final DateTime pauseEndsAt = pauseStartedAt.add(
        Duration(seconds: remaining),
      );
      if (!pauseEndsAt.isAfter(now)) {
        await _countdownAlertService.stopOngoingProgress();
        return;
      }

      await _countdownAlertService.startOrUpdateOngoingProgress(
        isPauseMode: true,
        projectName: running.project.name,
        endTime: pauseEndsAt,
        totalSeconds: remaining,
      );
      return;
    }

    if (!running.isCountdown) {
      await _countdownAlertService.stopOngoingProgress();
      return;
    }

    final int consumedPauseSeconds = running.timer.pausedSecondsTotal.clamp(
      0,
      RunningTimerInfo.pauseBudgetSeconds,
    );
    final DateTime countdownEndsAt = running.timer.startTime.add(
      Duration(seconds: running.countdownTargetSeconds + consumedPauseSeconds),
    );
    if (!countdownEndsAt.isAfter(now)) {
      await _countdownAlertService.stopOngoingProgress();
      return;
    }

    await _countdownAlertService.startOrUpdateOngoingProgress(
      isPauseMode: false,
      projectName: running.project.name,
      endTime: countdownEndsAt,
      totalSeconds: running.countdownTargetSeconds,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }
}
