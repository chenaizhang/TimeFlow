import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/timeflow_repository.dart';
import '../models/models.dart';

class AppModel extends ChangeNotifier with WidgetsBindingObserver {
  AppModel({required TimeFlowRepository repository}) : _repository = repository;

  final TimeFlowRepository _repository;

  bool _initialized = false;
  bool _loading = false;
  String? _lastError;
  int _dataVersion = 0;

  List<ProjectGroupBundle> _bundles = <ProjectGroupBundle>[];
  RunningTimerInfo? _runningTimer;
  DateTime _now = DateTime.now();
  Timer? _ticker;

  bool get initialized => _initialized;
  bool get loading => _loading;
  String? get lastError => _lastError;
  int get dataVersion => _dataVersion;

  List<ProjectGroupBundle> get bundles => _bundles;
  RunningTimerInfo? get runningTimer => _runningTimer;
  bool get hasRunningTimer => _runningTimer != null;

  Duration get runningDuration {
    if (_runningTimer == null) {
      return Duration.zero;
    }
    final Duration diff = _now.difference(_runningTimer!.timer.startTime);
    return diff.isNegative ? Duration.zero : diff;
  }

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }

    WidgetsBinding.instance.addObserver(this);
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

  Future<void> startTimer(int projectId) async {
    await _runMutation(() => _repository.startTimer(projectId));
  }

  Future<bool> stopTimer() async {
    bool hasSavedRecord = false;
    await _runMutation(() async {
      final FocusSession? session = await _repository.stopTimer();
      hasSavedRecord = session != null;
    });
    return hasSavedRecord;
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
    if (state == AppLifecycleState.resumed) {
      unawaited(refreshAll());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }
}
