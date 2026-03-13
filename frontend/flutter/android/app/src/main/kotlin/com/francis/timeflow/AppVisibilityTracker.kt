package com.francis.timeflow

object AppVisibilityTracker {
  @Volatile
  var isActivityResumed: Boolean = false
}
