package com.francis.timeflow

import android.os.Build
import java.util.Locale

object PromotedNotificationSupport {
  fun supportsPromotedLiveUpdates(): Boolean {
    if (Build.VERSION.SDK_INT < 36) {
      return false
    }
    return isStockAndroidLikeDevice()
  }

  private fun isStockAndroidLikeDevice(): Boolean {
    val manufacturer = Build.MANUFACTURER.normalized()
    val brand = Build.BRAND.normalized()
    val device = Build.DEVICE.normalized()
    val product = Build.PRODUCT.normalized()
    val fingerprint = Build.FINGERPRINT.normalized()

    if (manufacturer == "google" || brand == "google") {
      return true
    }

    // Keep AOSP/generic emulator behavior aligned with Pixel devices in development.
    val genericMarkers = listOf("aosp", "generic", "sdk_gphone", "emulator")
    return genericMarkers.any { marker ->
      device.contains(marker) ||
        product.contains(marker) ||
        fingerprint.contains(marker)
    }
  }

  private fun String?.normalized(): String {
    return this?.trim()?.lowercase(Locale.US).orEmpty()
  }
}
