package com.francis.timeflow

import android.app.NotificationManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  companion object {
    private const val CHANNEL = "com.francis.timeflow/ongoing_progress"
    private const val DEBUG_CHECK_EXTRA = "debug_check_promoted_notifications"
    private const val LOG_TAG = "TimeFlowPromoted"
  }

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    maybeRunDebugPromotedCheck(intent)
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    maybeRunDebugPromotedCheck(intent)
  }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "startOrUpdate" -> {
            val mode = call.argument<String>("mode")
            val projectName = call.argument<String>("projectName") ?: ""
            val endAtEpochMs = call.numberArg("endAtEpochMs")?.toLong()
            val totalSeconds = call.numberArg("totalSeconds")?.toInt()

            if (mode == null || endAtEpochMs == null || totalSeconds == null) {
              result.error("invalid_args", "Missing required ongoing progress args", null)
              return@setMethodCallHandler
            }

            startOrUpdateOngoingProgressService(
              mode = mode,
              projectName = projectName,
              endAtEpochMs = endAtEpochMs,
              totalSeconds = totalSeconds,
            )
            result.success(null)
          }

          "stop" -> {
            stopOngoingProgressService()
            result.success(null)
          }

          "getPromotedNotificationStatus" -> {
            result.success(getPromotedNotificationStatus())
          }

          "openPromotedNotificationSettings" -> {
            result.success(openPromotedNotificationSettings())
          }

          else -> result.notImplemented()
        }
      }
  }

  private fun startOrUpdateOngoingProgressService(
    mode: String,
    projectName: String,
    endAtEpochMs: Long,
    totalSeconds: Int,
  ) {
    val intent =
      Intent(applicationContext, TimerForegroundService::class.java).apply {
        action = TimerForegroundService.ACTION_START_OR_UPDATE
        putExtra(TimerForegroundService.EXTRA_MODE, mode)
        putExtra(TimerForegroundService.EXTRA_PROJECT_NAME, projectName)
        putExtra(TimerForegroundService.EXTRA_END_AT_EPOCH_MS, endAtEpochMs)
        putExtra(TimerForegroundService.EXTRA_TOTAL_SECONDS, totalSeconds)
      }

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      applicationContext.startForegroundService(intent)
    } else {
      applicationContext.startService(intent)
    }
  }

  private fun stopOngoingProgressService() {
    val intent = Intent(applicationContext, TimerForegroundService::class.java)
    applicationContext.stopService(intent)
  }

  private fun maybeRunDebugPromotedCheck(intent: Intent?) {
    if (intent?.getBooleanExtra(DEBUG_CHECK_EXTRA, false) != true) {
      return
    }

    val status = getPromotedNotificationStatus()
    Log.i(
      LOG_TAG,
      "sdkInt=${status["sdkInt"]} notificationsEnabled=${status["notificationsEnabled"]} " +
        "supportsPromoted=${status["supportsPromoted"]} promotedAllowed=${status["promotedAllowed"]}",
    )
  }

  private fun getPromotedNotificationStatus(): Map<String, Any?> {
    val notificationManager = getSystemService(NotificationManager::class.java)
    val supportsPromoted = Build.VERSION.SDK_INT >= 36
    return mapOf(
      "sdkInt" to Build.VERSION.SDK_INT,
      "notificationsEnabled" to NotificationManagerCompat.from(this).areNotificationsEnabled(),
      "supportsPromoted" to supportsPromoted,
      "promotedAllowed" to resolvePromotedNotificationPermission(notificationManager),
    )
  }

  private fun resolvePromotedNotificationPermission(
    notificationManager: NotificationManager?,
  ): Boolean? {
    if (notificationManager == null || Build.VERSION.SDK_INT < 36) {
      return null
    }

    return try {
      NotificationManager::class.java
        .getMethod("canPostPromotedNotifications")
        .invoke(notificationManager) as? Boolean
    } catch (_: Throwable) {
      null
    }
  }

  private fun openPromotedNotificationSettings(): Boolean {
    val primaryIntent =
      Intent(resolvePromotedSettingsAction()).apply {
        putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
      }
    if (tryStartSettingsActivity(primaryIntent)) {
      return true
    }

    val fallbackIntent =
      Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
        putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
      }
    return tryStartSettingsActivity(fallbackIntent)
  }

  private fun resolvePromotedSettingsAction(): String {
    return if (Build.VERSION.SDK_INT >= 36) {
      Settings.ACTION_APP_NOTIFICATION_PROMOTION_SETTINGS
    } else {
      "android.settings.APP_NOTIFICATION_PROMOTION_SETTINGS"
    }
  }

  private fun tryStartSettingsActivity(intent: Intent): Boolean {
    intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    val packageManager = applicationContext.packageManager
    if (intent.resolveActivity(packageManager) == null) {
      return false
    }

    return try {
      startActivity(intent)
      true
    } catch (_: Throwable) {
      false
    }
  }
}

private fun MethodCall.numberArg(key: String): Number? = argument<Number>(key)
