package com.francis.timeflow

import android.content.Context
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log

object AlertPlayback {
  private const val ALERT_PLAYBACK_MS = 4_000L
  private const val LOG_TAG = "TimeFlowAlert"
  private val mainHandler = Handler(Looper.getMainLooper())

  @Volatile private var activeRingtone: Ringtone? = null

  fun play(
    context: Context,
    enableRingtone: Boolean,
    enableVibration: Boolean,
  ) {
    Log.i(
      LOG_TAG,
      "play background alert ringtone=$enableRingtone vibration=$enableVibration",
    )
    if (enableRingtone) {
      playRingtone(context)
    } else {
      stopRingtone()
    }
  }

  fun stop() {
    Log.i(LOG_TAG, "stop background alert playback")
    stopRingtone()
  }

  private fun playRingtone(context: Context) {
    stopRingtone()

    val alertUri =
      RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
        ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        ?: return

    val ringtone = RingtoneManager.getRingtone(context.applicationContext, alertUri) ?: return
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
      ringtone.audioAttributes =
        AudioAttributes.Builder()
          .setUsage(AudioAttributes.USAGE_ALARM)
          .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
          .build()
    }

    activeRingtone = ringtone
    try {
      ringtone.play()
      mainHandler.postDelayed(
        {
          if (activeRingtone === ringtone) {
            stopRingtone()
          }
        },
        ALERT_PLAYBACK_MS,
      )
    } catch (_: Throwable) {
      if (activeRingtone === ringtone) {
        activeRingtone = null
      }
    }
  }

  private fun stopRingtone() {
    val ringtone = activeRingtone ?: return
    activeRingtone = null
    try {
      if (ringtone.isPlaying) {
        ringtone.stop()
      }
    } catch (_: Throwable) {}
  }

}
