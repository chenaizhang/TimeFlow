package com.francis.timeflow

import android.graphics.Bitmap
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.graphics.drawable.IconCompat
import java.util.Locale
import kotlin.math.max

class TimerForegroundService : Service() {
  companion object {
    const val ACTION_START_OR_UPDATE =
      "com.francis.timeflow.action.START_OR_UPDATE_ONGOING_PROGRESS"

    const val EXTRA_MODE = "extra_mode"
    const val EXTRA_PROJECT_NAME = "extra_project_name"
    const val EXTRA_END_AT_EPOCH_MS = "extra_end_at_epoch_ms"
    const val EXTRA_TOTAL_SECONDS = "extra_total_seconds"

    const val MODE_COUNTDOWN = "countdown"
    const val MODE_PAUSE = "pause"

    private const val CHANNEL_ID = "timeflow_ongoing_progress_v2"
    private const val CHANNEL_NAME = "实时计时进度"
    private const val NOTIFICATION_ID = 42001
  }

  private val handler = Handler(Looper.getMainLooper())
  private var tickerRunnable: Runnable? = null

  private var mode: String = MODE_COUNTDOWN
  private var projectName: String = ""
  private var endAtEpochMs: Long = 0L
  private var totalSeconds: Int = 1
  private var runningInForeground = false

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    when (intent?.action) {
      ACTION_START_OR_UPDATE -> {
        val nextEndAt = intent.getLongExtra(EXTRA_END_AT_EPOCH_MS, 0L)
        val nextTotal = intent.getIntExtra(EXTRA_TOTAL_SECONDS, 0)
        if (nextEndAt <= 0L || nextTotal <= 0) {
          stopTicker()
          stopForegroundAndSelf()
          return START_NOT_STICKY
        }

        mode = intent.getStringExtra(EXTRA_MODE) ?: MODE_COUNTDOWN
        projectName = intent.getStringExtra(EXTRA_PROJECT_NAME) ?: ""
        endAtEpochMs = nextEndAt
        totalSeconds = max(1, nextTotal)

        ensureChannel()
        updateNotification(forceStartForeground = !runningInForeground)
        scheduleTicker()
        return START_STICKY
      }

      else -> return START_STICKY
    }
  }

  override fun onDestroy() {
    stopTicker()
    super.onDestroy()
  }

  private fun scheduleTicker() {
    stopTicker()
    tickerRunnable =
      object : Runnable {
        override fun run() {
          updateNotification(forceStartForeground = false)
          if (remainingSeconds(nowEpochMs = System.currentTimeMillis()) > 0) {
            handler.postDelayed(this, 1_000L)
          }
        }
      }
    handler.post(tickerRunnable!!)
  }

  private fun stopTicker() {
    val runnable = tickerRunnable
    if (runnable != null) {
      handler.removeCallbacks(runnable)
      tickerRunnable = null
    }
  }

  private fun updateNotification(forceStartForeground: Boolean) {
    val notification = buildNotification()
    if (forceStartForeground || !runningInForeground) {
      startForegroundCompat(notification)
      runningInForeground = true
      return
    }
    NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, notification)
  }

  private fun startForegroundCompat(notification: android.app.Notification) {
    startForeground(NOTIFICATION_ID, notification)
  }

  private fun stopForegroundAndSelf() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
      stopForeground(STOP_FOREGROUND_REMOVE)
    } else {
      @Suppress("DEPRECATION")
      stopForeground(true)
    }
    runningInForeground = false
    stopSelf()
  }

  private fun buildNotification(): android.app.Notification {
    val now = System.currentTimeMillis()
    val remaining = remainingSeconds(nowEpochMs = now)
    val consumed = (totalSeconds - remaining).coerceIn(0, totalSeconds)
    val percent = if (totalSeconds <= 0) 0 else ((consumed * 100) / totalSeconds)

    val title = projectName.ifBlank { if (mode == MODE_PAUSE) "暂停倒计时中" else "倒计时进行中" }
    val statusText = if (mode == MODE_PAUSE) "暂停剩余 ${formatSeconds(remaining)}" else "倒计时剩余 ${formatSeconds(remaining)}"
    val percentText = "已完成 $percent%"

    val builder =
      NotificationCompat.Builder(this, CHANNEL_ID)
        .setSmallIcon(R.mipmap.ic_launcher)
        .setContentTitle(title)
        .setContentText("$statusText\n$percentText")
        .setLargeIcon(null as Bitmap?)
        .setOnlyAlertOnce(true)
        .setSilent(true)
        .setOngoing(true)
        .setCategory(NotificationCompat.CATEGORY_PROGRESS)
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        .setContentIntent(buildContentIntent())
        .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        .addAction(buildOpenAction())

    if (Build.VERSION.SDK_INT >= 36) {
      applyProgressStyle(
        builder = builder,
        consumed = consumed,
      )
      applyAndroid16LiveUpdateHints(builder, remainingText = formatSeconds(remaining))
    } else {
      builder.setProgress(totalSeconds, consumed, false)
      applyExpandedBody(
        builder = builder,
        title = title,
        statusText = statusText,
        percentText = percentText,
      )
    }
    return builder.build()
  }

  private fun applyExpandedBody(
    builder: NotificationCompat.Builder,
    title: String,
    statusText: String,
    percentText: String,
  ) {
    builder.setStyle(
      NotificationCompat.BigTextStyle()
        .setBigContentTitle(title)
        .bigText("$statusText\n$percentText"),
    )
  }

  private fun applyProgressStyle(
    builder: NotificationCompat.Builder,
    consumed: Int,
  ) {
    val progressStyle =
      NotificationCompat.ProgressStyle()
        .setStyledByProgress(true)
        .addProgressSegment(NotificationCompat.ProgressStyle.Segment(totalSeconds))
        .setProgress(consumed)
    builder.setStyle(progressStyle)
  }

  private fun applyAndroid16LiveUpdateHints(
    builder: NotificationCompat.Builder,
    remainingText: String,
  ) {
    builder.setShortCriticalText(remainingText)
    builder.setRequestPromotedOngoing(true)

    // Hint system UI to treat this as a promoted live/progress update when supported.
    val promotedExtraKey = resolvePromotedOngoingExtraKey()
    if (promotedExtraKey != null) {
      builder.addExtras(Bundle().apply { putBoolean(promotedExtraKey, true) })
    }
  }

  private fun resolvePromotedOngoingExtraKey(): String? {
    try {
      val field = android.app.Notification::class.java.getField("EXTRA_REQUEST_PROMOTED_ONGOING")
      return field.get(null) as? String
    } catch (_: Throwable) {
      // Fallback key used by current Android 16 previews.
      return "android.requestPromotedOngoing"
    }
  }

  private fun buildContentIntent(): PendingIntent {
    val launchIntent =
      packageManager.getLaunchIntentForPackage(packageName)?.apply {
        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
      } ?: Intent(this, MainActivity::class.java).apply {
        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
      }
    val pendingIntentFlags =
      PendingIntent.FLAG_UPDATE_CURRENT or
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE
        else 0
    return PendingIntent.getActivity(this, 0, launchIntent, pendingIntentFlags)
  }

  private fun buildOpenAction(): NotificationCompat.Action {
    return NotificationCompat.Action.Builder(
      IconCompat.createWithResource(this, R.mipmap.ic_launcher),
      "打开计流",
      buildContentIntent(),
    ).build()
  }

  private fun remainingSeconds(nowEpochMs: Long): Int {
    val diffMs = endAtEpochMs - nowEpochMs
    if (diffMs <= 0) {
      return 0
    }
    return ((diffMs + 999L) / 1000L).toInt()
  }

  private fun ensureChannel() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
      return
    }
    val manager = getSystemService(NotificationManager::class.java) ?: return
    val channel =
      NotificationChannel(
        CHANNEL_ID,
        CHANNEL_NAME,
        NotificationManager.IMPORTANCE_DEFAULT,
      ).apply {
        description = "倒计时与暂停倒计时的实时进度通知"
        setShowBadge(false)
        enableVibration(false)
        setSound(null, null)
      }
    manager.createNotificationChannel(channel)
  }

  private fun formatSeconds(totalSeconds: Int): String {
    val safeSeconds = max(0, totalSeconds)
    val minutes = safeSeconds / 60
    val seconds = safeSeconds % 60
    return String.format(Locale.US, "%02d:%02d", minutes, seconds)
  }
}
