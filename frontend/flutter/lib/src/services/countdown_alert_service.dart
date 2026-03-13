import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:vibration/vibration.dart';

class BackgroundAlertChannelSettingsStatus {
  const BackgroundAlertChannelSettingsStatus({
    required this.kind,
    required this.title,
    required this.floatingEnabled,
    required this.vibrationEnabled,
    required this.needsAttention,
  });

  factory BackgroundAlertChannelSettingsStatus.fromMap(
    Map<Object?, Object?> map,
  ) {
    return BackgroundAlertChannelSettingsStatus(
      kind: map['kind'] as String? ?? 'countdown',
      title: map['title'] as String? ?? '提醒通知',
      floatingEnabled: map['floatingEnabled'] == true,
      vibrationEnabled: map['vibrationEnabled'] == true,
      needsAttention: map['needsAttention'] == true,
    );
  }

  final String kind;
  final String title;
  final bool floatingEnabled;
  final bool vibrationEnabled;
  final bool needsAttention;
}

class BackgroundAlertNotificationSettingsStatus {
  const BackgroundAlertNotificationSettingsStatus({
    required this.supported,
    required this.notificationsEnabled,
    required this.channels,
    required this.floatingStatusNote,
  });

  const BackgroundAlertNotificationSettingsStatus.unsupported()
    : supported = false,
      notificationsEnabled = false,
      channels = const <BackgroundAlertChannelSettingsStatus>[],
      floatingStatusNote = '';

  factory BackgroundAlertNotificationSettingsStatus.fromMap(
    Map<Object?, Object?> map,
  ) {
    final List<Object?> rawChannels =
        (map['channels'] as List<Object?>?) ?? const <Object?>[];
    return BackgroundAlertNotificationSettingsStatus(
      supported: true,
      notificationsEnabled: map['notificationsEnabled'] == true,
      channels: rawChannels
          .whereType<Map<Object?, Object?>>()
          .map(BackgroundAlertChannelSettingsStatus.fromMap)
          .toList(growable: false),
      floatingStatusNote: map['floatingStatusNote'] as String? ?? '',
    );
  }

  final bool supported;
  final bool notificationsEnabled;
  final List<BackgroundAlertChannelSettingsStatus> channels;
  final String floatingStatusNote;

  bool get needsAttention {
    if (!supported) {
      return false;
    }
    if (!notificationsEnabled) {
      return true;
    }
    return channels.any((BackgroundAlertChannelSettingsStatus item) {
      return item.needsAttention;
    });
  }
}

class CountdownAlertService {
  CountdownAlertService._();

  static final CountdownAlertService instance = CountdownAlertService._();
  static const MethodChannel _ongoingProgressChannel = MethodChannel(
    'com.francis.timeflow/ongoing_progress',
  );

  static const int _countdownNotificationId = 41001;
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final FlutterRingtonePlayer _ringtonePlayer = FlutterRingtonePlayer();

  bool _initialized = false;
  bool? _hasVibrator;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  Future<void> initialize() async {
    if (!_isAndroid || _initialized) {
      return;
    }

    await _notifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
    );
    _initialized = true;
    await _ensureNotificationsEnabled();
  }

  Future<void> notifyCountdownCompletedForeground({
    required bool enableRingtone,
    required bool enableVibration,
  }) async {
    if (!enableRingtone && !enableVibration) {
      return;
    }

    if (_isAndroid) {
      if (enableRingtone) {
        try {
          await _ringtonePlayer.playNotification();
        } catch (_) {}
      }
      if (enableVibration) {
        final bool canVibrate = await _canVibrate();
        if (canVibrate) {
          try {
            await Vibration.vibrate(duration: 520, amplitude: 190);
          } catch (_) {}
        }
      }
      return;
    }

    if (enableRingtone) {
      await SystemSound.play(SystemSoundType.alert);
    }
    if (enableVibration) {
      await HapticFeedback.mediumImpact();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await HapticFeedback.mediumImpact();
    }
  }

  Future<void> scheduleBackgroundCountdownReminder({
    required DateTime endTime,
    required String projectName,
    required bool enableRingtone,
    required bool enableVibration,
  }) async {
    if (!_isAndroid) {
      return;
    }
    if (!enableRingtone && !enableVibration) {
      await cancelBackgroundCountdownReminder();
      return;
    }

    await initialize();
    final bool notificationsEnabled = await _ensureNotificationsEnabled();
    if (!notificationsEnabled) {
      return;
    }

    if (!endTime.isAfter(DateTime.now().add(const Duration(seconds: 1)))) {
      await cancelBackgroundCountdownReminder();
      return;
    }

    await _notifications.cancel(id: _countdownNotificationId);

    try {
      await _ongoingProgressChannel.invokeMethod<void>(
        'scheduleBackgroundCountdownAlarm',
        <String, Object>{
          'projectName': projectName,
          'endAtEpochMs': endTime.millisecondsSinceEpoch,
          'enableRingtone': enableRingtone,
          'enableVibration': enableVibration,
        },
      );
    } catch (_) {}
  }

  Future<void> cancelBackgroundCountdownReminder() async {
    if (!_isAndroid) {
      return;
    }
    if (_initialized) {
      await _notifications.cancel(id: _countdownNotificationId);
    }
    try {
      await _ongoingProgressChannel.invokeMethod<void>(
        'cancelBackgroundCountdownAlarm',
      );
    } catch (_) {}
  }

  Future<void> notifyPauseEndedForeground() async {
    await notifyCountdownCompletedForeground(
      enableRingtone: true,
      enableVibration: true,
    );
  }

  Future<void> startOrUpdateOngoingProgress({
    required bool isPauseMode,
    required String projectName,
    required DateTime endTime,
    required int totalSeconds,
  }) async {
    if (!_isAndroid) {
      return;
    }
    if (totalSeconds <= 0) {
      await stopOngoingProgress();
      return;
    }

    try {
      await _ongoingProgressChannel
          .invokeMethod<void>('startOrUpdate', <String, Object>{
            'mode': isPauseMode ? 'pause' : 'countdown',
            'projectName': projectName,
            'endAtEpochMs': endTime.millisecondsSinceEpoch,
            'totalSeconds': totalSeconds,
          });
    } catch (_) {}
  }

  Future<void> stopOngoingProgress() async {
    if (!_isAndroid) {
      return;
    }
    try {
      await _ongoingProgressChannel.invokeMethod<void>('stop');
    } catch (_) {}
  }

  Future<bool> openPromotedNotificationSettings() async {
    if (!_isAndroid) {
      return false;
    }
    try {
      return await _ongoingProgressChannel.invokeMethod<bool>(
            'openPromotedNotificationSettings',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> supportsPromotedNotificationSettings() async {
    if (!_isAndroid) {
      return false;
    }
    try {
      final Map<Object?, Object?>? status = await _ongoingProgressChannel
          .invokeMethod<Map<Object?, Object?>>('getPromotedNotificationStatus');
      return status?['supportsPromoted'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> needsExactAlarmPermissionEntry() async {
    if (!_isAndroid) {
      return false;
    }
    try {
      final Map<Object?, Object?>? status = await _ongoingProgressChannel
          .invokeMethod<Map<Object?, Object?>>('getExactAlarmStatus');
      final bool supportsSettings =
          status?['supportsExactAlarmSettings'] == true;
      final bool exactAlarmAllowed = status?['exactAlarmAllowed'] == true;
      return supportsSettings && !exactAlarmAllowed;
    } catch (_) {
      return false;
    }
  }

  Future<bool> openExactAlarmSettings() async {
    if (!_isAndroid) {
      return false;
    }
    try {
      return await _ongoingProgressChannel.invokeMethod<bool>(
            'openExactAlarmSettings',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<BackgroundAlertNotificationSettingsStatus>
  getBackgroundAlertNotificationSettingsStatus() async {
    if (!_isAndroid) {
      return const BackgroundAlertNotificationSettingsStatus.unsupported();
    }
    try {
      final Map<Object?, Object?>? status = await _ongoingProgressChannel
          .invokeMethod<Map<Object?, Object?>>(
            'getBackgroundAlertNotificationSettingsStatus',
          );
      if (status == null) {
        return const BackgroundAlertNotificationSettingsStatus.unsupported();
      }
      return BackgroundAlertNotificationSettingsStatus.fromMap(status);
    } catch (_) {
      return const BackgroundAlertNotificationSettingsStatus.unsupported();
    }
  }

  Future<bool> openBackgroundAlertNotificationSettings({
    required String alertKind,
  }) async {
    if (!_isAndroid) {
      return false;
    }
    try {
      return await _ongoingProgressChannel.invokeMethod<bool>(
            'openBackgroundAlertNotificationSettings',
            <String, Object>{'alertKind': alertKind},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<void> scheduleBackgroundPauseReminder({
    required DateTime endTime,
    required String projectName,
  }) async {
    if (!_isAndroid) {
      return;
    }

    await initialize();
    final bool notificationsEnabled = await _ensureNotificationsEnabled();
    if (!notificationsEnabled) {
      return;
    }

    if (!endTime.isAfter(DateTime.now().add(const Duration(seconds: 1)))) {
      await cancelBackgroundPauseReminder();
      return;
    }

    try {
      await _ongoingProgressChannel.invokeMethod<void>(
        'scheduleBackgroundPauseAlarm',
        <String, Object>{
          'projectName': projectName,
          'endAtEpochMs': endTime.millisecondsSinceEpoch,
        },
      );
    } catch (_) {}
  }

  Future<void> cancelBackgroundPauseReminder() async {
    if (!_isAndroid) {
      return;
    }
    try {
      await _ongoingProgressChannel.invokeMethod<void>(
        'cancelBackgroundPauseAlarm',
      );
    } catch (_) {}
  }

  Future<bool> _canVibrate() async {
    if (_hasVibrator != null) {
      return _hasVibrator!;
    }
    try {
      _hasVibrator = await Vibration.hasVibrator();
    } catch (_) {
      _hasVibrator = false;
    }
    return _hasVibrator ?? false;
  }

  Future<bool> _ensureNotificationsEnabled() async {
    if (!_isAndroid) {
      return false;
    }
    final AndroidFlutterLocalNotificationsPlugin? androidPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidPlugin == null) {
      return false;
    }

    final bool enabledNow =
        await androidPlugin.areNotificationsEnabled() ?? true;
    if (enabledNow) {
      return true;
    }
    final bool? granted = await androidPlugin.requestNotificationsPermission();
    return granted ?? false;
  }

}
