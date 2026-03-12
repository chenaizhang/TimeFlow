import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import 'package:vibration/vibration.dart';

class CountdownAlertService {
  CountdownAlertService._();

  static final CountdownAlertService instance = CountdownAlertService._();

  static const int _countdownNotificationId = 41001;

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final FlutterRingtonePlayer _ringtonePlayer = FlutterRingtonePlayer();

  bool _initialized = false;
  bool _timezoneInitialized = false;
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

    await _ensureTimezoneInitialized();
    final tz.TZDateTime scheduled = tz.TZDateTime.from(endTime.toUtc(), tz.UTC);
    final tz.TZDateTime now = tz.TZDateTime.now(tz.UTC);
    if (!scheduled.isAfter(now.add(const Duration(seconds: 1)))) {
      await cancelBackgroundCountdownReminder();
      return;
    }

    final AndroidScheduleMode scheduleMode =
        await _resolveAndroidScheduleMode();
    final String channelId = _channelId(
      enableRingtone: enableRingtone,
      enableVibration: enableVibration,
    );
    final String channelName = _channelName(
      enableRingtone: enableRingtone,
      enableVibration: enableVibration,
    );
    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: '用于倒计时结束时的提醒通知',
          importance: Importance.max,
          priority: Priority.high,
          playSound: enableRingtone,
          enableVibration: enableVibration,
          vibrationPattern: enableVibration
              ? Int64List.fromList(<int>[0, 350, 120, 350])
              : null,
          category: AndroidNotificationCategory.alarm,
          ticker: '暂停结束',
          visibility: NotificationVisibility.public,
        );

    await _notifications.zonedSchedule(
      id: _countdownNotificationId,
      title: '暂停结束',
      body: '“$projectName”倒计时已结束',
      scheduledDate: scheduled,
      notificationDetails: NotificationDetails(android: androidDetails),
      androidScheduleMode: scheduleMode,
      payload: 'countdown_finished',
    );
  }

  Future<void> cancelBackgroundCountdownReminder() async {
    if (!_isAndroid || !_initialized) {
      return;
    }
    await _notifications.cancel(id: _countdownNotificationId);
  }

  Future<void> _ensureTimezoneInitialized() async {
    if (_timezoneInitialized) {
      return;
    }
    tz_data.initializeTimeZones();
    tz.setLocalLocation(tz.UTC);
    _timezoneInitialized = true;
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

  Future<AndroidScheduleMode> _resolveAndroidScheduleMode() async {
    final AndroidFlutterLocalNotificationsPlugin? androidPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (androidPlugin == null) {
      return AndroidScheduleMode.inexactAllowWhileIdle;
    }
    final bool canExact =
        await androidPlugin.canScheduleExactNotifications() ?? false;
    if (!canExact) {
      await androidPlugin.requestExactAlarmsPermission();
      final bool canExactAfterRequest =
          await androidPlugin.canScheduleExactNotifications() ?? false;
      if (!canExactAfterRequest) {
        return AndroidScheduleMode.inexactAllowWhileIdle;
      }
    }
    return AndroidScheduleMode.exactAllowWhileIdle;
  }

  String _channelId({
    required bool enableRingtone,
    required bool enableVibration,
  }) {
    final String ringtoneKey = enableRingtone ? '1' : '0';
    final String vibrationKey = enableVibration ? '1' : '0';
    return 'timeflow_countdown_alerts_$ringtoneKey$vibrationKey';
  }

  String _channelName({
    required bool enableRingtone,
    required bool enableVibration,
  }) {
    if (enableRingtone && enableVibration) {
      return '倒计时结束提醒(铃声+震动)';
    }
    if (enableRingtone) {
      return '倒计时结束提醒(铃声)';
    }
    return '倒计时结束提醒(震动)';
  }
}
