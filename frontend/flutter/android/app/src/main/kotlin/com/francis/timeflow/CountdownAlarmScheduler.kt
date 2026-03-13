package com.francis.timeflow

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.graphics.drawable.IconCompat
import java.util.Locale

object CountdownAlarmScheduler {
  private const val ACTION_TIMER_ALERT =
    "com.francis.timeflow.action.TIMER_ALERT"
  private const val EXTRA_ALERT_KIND = "extra_alert_kind"
  private const val EXTRA_PROJECT_NAME = "extra_project_name"
  private const val EXTRA_ENABLE_RINGTONE = "extra_enable_ringtone"
  private const val EXTRA_ENABLE_VIBRATION = "extra_enable_vibration"
  private const val ALERT_KIND_COUNTDOWN_COMPLETE = "countdown_complete"
  private const val ALERT_KIND_PAUSE_ENDED = "pause_ended"
  private const val REQUEST_CODE_COUNTDOWN = 42011
  private const val REQUEST_CODE_PAUSE = 42012
  private const val COMPLETION_NOTIFICATION_ID = 42002
  private const val PAUSE_NOTIFICATION_ID = 42003
  private const val LEGACY_COUNTDOWN_NOTIFICATION_ID = 41001
  private const val LOG_TAG = "TimeFlowAlert"
  private const val SETTINGS_KIND_COUNTDOWN = "countdown"
  private const val SETTINGS_KIND_PAUSE = "pause"

  fun schedule(
    context: Context,
    endAtEpochMs: Long,
    projectName: String,
    enableRingtone: Boolean,
    enableVibration: Boolean,
  ) {
    val alarmManager = context.getSystemService(AlarmManager::class.java) ?: return
    val pendingIntent =
      buildPendingIntent(
        requestCode = REQUEST_CODE_COUNTDOWN,
        alertKind = ALERT_KIND_COUNTDOWN_COMPLETE,
        context = context,
        projectName = projectName,
        enableRingtone = enableRingtone,
        enableVibration = enableVibration,
        flags = PendingIntent.FLAG_UPDATE_CURRENT or pendingIntentMutableFlag(),
      ) ?: return

    scheduleAlarm(context, endAtEpochMs, pendingIntent)
  }

  fun schedulePauseEnded(
    context: Context,
    endAtEpochMs: Long,
    projectName: String,
  ) {
    val pendingIntent =
      buildPendingIntent(
        requestCode = REQUEST_CODE_PAUSE,
        alertKind = ALERT_KIND_PAUSE_ENDED,
        context = context,
        projectName = projectName,
        enableRingtone = true,
        enableVibration = true,
        flags = PendingIntent.FLAG_UPDATE_CURRENT or pendingIntentMutableFlag(),
      ) ?: return

    scheduleAlarm(context, endAtEpochMs, pendingIntent)
  }

  fun cancel(context: Context) {
    cancelAlarm(
      context = context,
      requestCode = REQUEST_CODE_COUNTDOWN,
      alertKind = ALERT_KIND_COUNTDOWN_COMPLETE,
    )
    NotificationManagerCompat.from(context).cancel(COMPLETION_NOTIFICATION_ID)
  }

  fun cancelPauseEnded(context: Context) {
    cancelAlarm(
      context = context,
      requestCode = REQUEST_CODE_PAUSE,
      alertKind = ALERT_KIND_PAUSE_ENDED,
    )
    NotificationManagerCompat.from(context).cancel(PAUSE_NOTIFICATION_ID)
  }

  fun notifyPauseEndedIfBackground(context: Context, projectName: String) {
    NotificationManagerCompat.from(context).cancel(PAUSE_NOTIFICATION_ID)
    if (AppVisibilityTracker.isActivityResumed) {
      Log.i(LOG_TAG, "skip pause background alert because activity is resumed")
      return
    }
    Log.i(LOG_TAG, "notify pause ended in background for project=$projectName")

    deliverBackgroundAlert(
      context = context,
      notificationId = PAUSE_NOTIFICATION_ID,
      title = "暂停结束",
      body = "“$projectName”暂停结束，继续专注吧",
      channelId = pauseChannelId(enableRingtone = true, enableVibration = true),
      channelName = pauseChannelName(enableRingtone = true, enableVibration = true),
      description = "用于暂停结束时的提醒通知",
      category = NotificationCompat.CATEGORY_ALARM,
      enableRingtone = true,
      enableVibration = true,
    )
  }

  fun dismissPresentedAlerts(context: Context) {
    Log.i(LOG_TAG, "dismiss presented alerts because app resumed")
    NotificationManagerCompat.from(context).cancel(COMPLETION_NOTIFICATION_ID)
    NotificationManagerCompat.from(context).cancel(PAUSE_NOTIFICATION_ID)
    NotificationManagerCompat.from(context).cancel(LEGACY_COUNTDOWN_NOTIFICATION_ID)
    AlertPlayback.stop()
  }

  private fun scheduleAlarm(
    context: Context,
    endAtEpochMs: Long,
    pendingIntent: PendingIntent,
  ) {
    val alarmManager = context.getSystemService(AlarmManager::class.java) ?: return
    if (canScheduleExactAlarms(context)) {
      when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.M ->
          alarmManager.setExactAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            endAtEpochMs,
            pendingIntent,
          )
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT ->
          alarmManager.setExact(AlarmManager.RTC_WAKEUP, endAtEpochMs, pendingIntent)
        else -> alarmManager.set(AlarmManager.RTC_WAKEUP, endAtEpochMs, pendingIntent)
      }
      return
    }

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      alarmManager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, endAtEpochMs, pendingIntent)
    } else {
      alarmManager.set(AlarmManager.RTC_WAKEUP, endAtEpochMs, pendingIntent)
    }
  }

  private fun cancelAlarm(
    context: Context,
    requestCode: Int,
    alertKind: String,
  ) {
    val alarmManager = context.getSystemService(AlarmManager::class.java) ?: return
    val pendingIntent =
      buildPendingIntent(
        requestCode = requestCode,
        alertKind = alertKind,
        context = context,
        projectName = "",
        enableRingtone = false,
        enableVibration = false,
        flags =
          PendingIntent.FLAG_NO_CREATE or
            pendingIntentMutableFlag(),
      )
    if (pendingIntent != null) {
      alarmManager.cancel(pendingIntent)
      pendingIntent.cancel()
    }
  }

  fun canScheduleExactAlarms(context: Context): Boolean {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
      return true
    }
    val alarmManager = context.getSystemService(AlarmManager::class.java) ?: return false
    return alarmManager.canScheduleExactAlarms()
  }

  fun supportsExactAlarmSettings(): Boolean {
    return Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
  }

  fun openExactAlarmSettings(context: Context): Boolean {
    if (!supportsExactAlarmSettings()) {
      return false
    }

    val packageUri = Uri.parse("package:${context.packageName}")
    val primaryIntent =
      Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM).apply {
        data = packageUri
      }
    if (tryStartSettingsActivity(context, primaryIntent)) {
      return true
    }

    val fallbackIntent =
      Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
        data = packageUri
      }
    return tryStartSettingsActivity(context, fallbackIntent)
  }

  fun getBackgroundAlertSettingsStatus(context: Context): Map<String, Any?> {
    val notificationsEnabled = NotificationManagerCompat.from(context).areNotificationsEnabled()
    ensureRepresentativeAlertChannels(context)
    return mapOf(
      "notificationsEnabled" to notificationsEnabled,
      "channels" to
        listOf(
          buildAlertChannelStatus(
            context = context,
            alertKind = SETTINGS_KIND_COUNTDOWN,
            title = "倒计时结束提醒",
          ),
          buildAlertChannelStatus(
            context = context,
            alertKind = SETTINGS_KIND_PAUSE,
            title = "暂停结束提醒",
          ),
        ),
      "floatingStatusNote" to
        "悬浮通知状态按系统通知通道的重要程度检测，部分厂商可能还需要在系统页额外开启悬浮通知。",
    )
  }

  fun openBackgroundAlertSettings(context: Context, alertKind: String): Boolean {
    ensureRepresentativeAlertChannels(context)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      val channelIntent =
        Intent(Settings.ACTION_CHANNEL_NOTIFICATION_SETTINGS).apply {
          putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
          putExtra(Settings.EXTRA_CHANNEL_ID, representativeAlertChannelId(alertKind))
        }
      if (tryStartSettingsActivity(context, channelIntent)) {
        return true
      }
    }

    val fallbackIntent =
      Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
        putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
      }
    return tryStartSettingsActivity(context, fallbackIntent)
  }

  fun handleAlarm(context: Context, intent: Intent) {
    val alertKind =
      intent.getStringExtra(EXTRA_ALERT_KIND) ?: ALERT_KIND_COUNTDOWN_COMPLETE

    if (alertKind == ALERT_KIND_COUNTDOWN_COMPLETE) {
      context.stopService(Intent(context, TimerForegroundService::class.java))
      NotificationManagerCompat.from(context).cancel(TimerForegroundService.NOTIFICATION_ID)
      NotificationManagerCompat.from(context).cancel(COMPLETION_NOTIFICATION_ID)
    } else {
      NotificationManagerCompat.from(context).cancel(PAUSE_NOTIFICATION_ID)
    }

    if (AppVisibilityTracker.isActivityResumed) {
      Log.i(LOG_TAG, "skip timer alert kind=$alertKind because activity is resumed")
      return
    }

    val enableRingtone = intent.getBooleanExtra(EXTRA_ENABLE_RINGTONE, true)
    val enableVibration = intent.getBooleanExtra(EXTRA_ENABLE_VIBRATION, true)
    if (!enableRingtone && !enableVibration) {
      return
    }

    val projectName = intent.getStringExtra(EXTRA_PROJECT_NAME).orEmpty()
    when (alertKind) {
      ALERT_KIND_PAUSE_ENDED ->
        deliverBackgroundAlert(
          context = context,
          notificationId = PAUSE_NOTIFICATION_ID,
          title = "暂停结束",
          body = "“$projectName”暂停结束，继续专注吧",
          channelId = pauseChannelId(enableRingtone, enableVibration),
          channelName = pauseChannelName(enableRingtone, enableVibration),
          description = "用于暂停结束时的提醒通知",
          category = NotificationCompat.CATEGORY_ALARM,
          enableRingtone = enableRingtone,
          enableVibration = enableVibration,
        )
      else ->
        deliverBackgroundAlert(
          context = context,
          notificationId = COMPLETION_NOTIFICATION_ID,
          title = "倒计时结束",
          body = "“$projectName”倒计时已结束",
          channelId = completionChannelId(enableRingtone, enableVibration),
          channelName = completionChannelName(enableRingtone, enableVibration),
          description = "用于倒计时结束时的提醒通知",
          category = NotificationCompat.CATEGORY_ALARM,
          enableRingtone = enableRingtone,
          enableVibration = enableVibration,
        )
    }
  }

  private fun deliverBackgroundAlert(
    context: Context,
    notificationId: Int,
    title: String,
    body: String,
    channelId: String,
    channelName: String,
    description: String,
    category: String,
    enableRingtone: Boolean,
    enableVibration: Boolean,
  ) {
    Log.i(
      LOG_TAG,
      "deliver background alert notificationId=$notificationId channel=$channelId category=$category",
    )
    AlertPlayback.play(
      context = context,
      enableRingtone = enableRingtone,
      enableVibration = enableVibration,
    )
    showNotification(
      context = context,
      notificationId = notificationId,
      title = title,
      body = body,
      channelId = channelId,
      channelName = channelName,
      description = description,
      category = category,
      enableRingtone = enableRingtone,
      enableVibration = enableVibration,
    )
  }

  private fun buildPendingIntent(
    requestCode: Int,
    alertKind: String,
    context: Context,
    projectName: String,
    enableRingtone: Boolean,
    enableVibration: Boolean,
    flags: Int,
  ): PendingIntent? {
    val intent =
      Intent(context, CountdownAlarmReceiver::class.java).apply {
        action = ACTION_TIMER_ALERT
        putExtra(EXTRA_ALERT_KIND, alertKind)
        putExtra(EXTRA_PROJECT_NAME, projectName)
        putExtra(EXTRA_ENABLE_RINGTONE, enableRingtone)
        putExtra(EXTRA_ENABLE_VIBRATION, enableVibration)
      }
    return PendingIntent.getBroadcast(context, requestCode, intent, flags)
  }

  private fun pendingIntentMutableFlag(): Int {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
      PendingIntent.FLAG_IMMUTABLE
    } else {
      0
    }
  }

  private fun tryStartSettingsActivity(context: Context, intent: Intent): Boolean {
    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    val packageManager = context.packageManager
    if (intent.resolveActivity(packageManager) == null) {
      return false
    }

    return try {
      context.startActivity(intent)
      true
    } catch (_: Throwable) {
      false
    }
  }

  private fun ensureRepresentativeAlertChannels(context: Context) {
    ensureAlertChannel(
      context = context,
      channelId = representativeAlertChannelId(SETTINGS_KIND_COUNTDOWN),
      channelName = representativeAlertChannelName(),
      description = representativeAlertChannelDescription(),
      enableRingtone = true,
      enableVibration = true,
    )
    ensureAlertChannel(
      context = context,
      channelId = representativeAlertChannelId(SETTINGS_KIND_PAUSE),
      channelName = representativeAlertChannelName(),
      description = representativeAlertChannelDescription(),
      enableRingtone = true,
      enableVibration = true,
    )
  }

  private fun buildAlertChannelStatus(
    context: Context,
    alertKind: String,
    title: String,
  ): Map<String, Any?> {
    val notificationsEnabled = NotificationManagerCompat.from(context).areNotificationsEnabled()
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
      return mapOf(
        "kind" to alertKind,
        "title" to title,
        "channelId" to representativeAlertChannelId(alertKind),
        "floatingEnabled" to notificationsEnabled,
        "vibrationEnabled" to notificationsEnabled,
        "needsAttention" to !notificationsEnabled,
      )
    }

    val manager = context.getSystemService(NotificationManager::class.java)
    val channel = manager?.getNotificationChannel(representativeAlertChannelId(alertKind))
    val importance = channel?.importance ?: NotificationManager.IMPORTANCE_HIGH
    val floatingEnabled = notificationsEnabled && importance >= NotificationManager.IMPORTANCE_HIGH
    val vibrationEnabled = channel?.shouldVibrate() ?: true

    return mapOf(
      "kind" to alertKind,
      "title" to title,
      "channelId" to representativeAlertChannelId(alertKind),
      "floatingEnabled" to floatingEnabled,
      "vibrationEnabled" to vibrationEnabled,
      "needsAttention" to (!notificationsEnabled || !floatingEnabled || !vibrationEnabled),
    )
  }

  private fun representativeAlertChannelId(alertKind: String): String {
    return when (alertKind) {
      SETTINGS_KIND_PAUSE -> pauseChannelId(enableRingtone = true, enableVibration = true)
      else -> completionChannelId(enableRingtone = true, enableVibration = true)
    }
  }

  private fun representativeAlertChannelName(): String = "计时结束提醒"

  private fun representativeAlertChannelDescription(): String =
    "用于倒计时结束和暂停结束时的提醒通知"

  private fun completionChannelId(
    enableRingtone: Boolean,
    enableVibration: Boolean,
  ): String {
    val ringtoneKey = if (enableRingtone) "1" else "0"
    val vibrationKey = if (enableVibration) "1" else "0"
    return "timeflow_countdown_complete_${ringtoneKey}${vibrationKey}_v5"
  }

  private fun completionChannelName(
    enableRingtone: Boolean,
    enableVibration: Boolean,
  ): String {
    return when {
      enableRingtone && enableVibration -> "倒计时结束提醒(铃声+震动)"
      enableRingtone -> "倒计时结束提醒(铃声)"
      enableVibration -> "倒计时结束提醒(震动)"
      else -> "倒计时结束提醒"
    }
  }

  private fun pauseChannelId(
    enableRingtone: Boolean,
    enableVibration: Boolean,
  ): String {
    val ringtoneKey = if (enableRingtone) "1" else "0"
    val vibrationKey = if (enableVibration) "1" else "0"
    return "timeflow_pause_complete_${ringtoneKey}${vibrationKey}_v5"
  }

  private fun pauseChannelName(
    enableRingtone: Boolean,
    enableVibration: Boolean,
  ): String {
    return when {
      enableRingtone && enableVibration -> "暂停结束提醒(铃声+震动)"
      enableRingtone -> "暂停结束提醒(铃声)"
      enableVibration -> "暂停结束提醒(震动)"
      else -> "暂停结束提醒"
    }
  }

  private fun ensureAlertChannel(
    context: Context,
    channelId: String,
    channelName: String,
    description: String,
    enableRingtone: Boolean,
    enableVibration: Boolean,
  ) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
      return
    }

    val manager = context.getSystemService(NotificationManager::class.java) ?: return
    val channel =
      NotificationChannel(
        channelId,
        channelName,
        NotificationManager.IMPORTANCE_HIGH,
      ).apply {
        this.description = description
        setShowBadge(true)
        enableVibration(enableVibration)
        vibrationPattern =
          if (enableVibration) longArrayOf(0L, 350L, 120L, 350L) else null
        setSound(null, null)
      }
    manager.createNotificationChannel(channel)
  }

  private fun showNotification(
    context: Context,
    notificationId: Int,
    title: String,
    body: String,
    channelId: String,
    channelName: String,
    description: String,
    category: String,
    enableRingtone: Boolean,
    enableVibration: Boolean,
  ) {
    ensureAlertChannel(
      context = context,
      channelId = channelId,
      channelName = channelName,
      description = description,
      enableRingtone = enableRingtone,
      enableVibration = enableVibration,
    )

    val builder =
      NotificationCompat.Builder(context, channelId)
        .setSmallIcon(R.mipmap.ic_launcher)
        .setContentTitle(title)
        .setContentText(body)
        .setStyle(
          NotificationCompat.BigTextStyle()
            .setBigContentTitle(title)
            .bigText(body),
        )
        .setPriority(NotificationCompat.PRIORITY_MAX)
        .setCategory(category)
        .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        .setAutoCancel(true)
        .setContentIntent(buildContentIntent(context))
        .setTicker(title)
        .addAction(buildOpenAction(context))

    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
      builder.setSound(null)
      if (enableVibration) {
        builder.setVibrate(longArrayOf(0L, 350L, 120L, 350L))
      } else {
        builder.setVibrate(null)
      }
    }

    NotificationManagerCompat.from(context).notify(notificationId, builder.build())
  }

  private fun buildContentIntent(context: Context): PendingIntent {
    val launchIntent =
      context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
      } ?: Intent(context, MainActivity::class.java).apply {
        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
      }
    val pendingIntentFlags =
      PendingIntent.FLAG_UPDATE_CURRENT or
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE
        else 0
    return PendingIntent.getActivity(context, 0, launchIntent, pendingIntentFlags)
  }

  private fun buildOpenAction(context: Context): NotificationCompat.Action {
    return NotificationCompat.Action.Builder(
      IconCompat.createWithResource(context, R.mipmap.ic_launcher),
      "打开计流",
      buildContentIntent(context),
    ).build()
  }
}
