package com.francis.timeflow

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class CountdownAlarmReceiver : BroadcastReceiver() {
  override fun onReceive(context: Context, intent: Intent) {
    CountdownAlarmScheduler.handleAlarm(context, intent)
  }
}
