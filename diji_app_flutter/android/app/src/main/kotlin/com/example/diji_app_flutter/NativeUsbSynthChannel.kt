package com.example.diji_app_flutter

import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter → native USB synth: load a user [.sf2] into TinySoundFont (same engine as bundled font).
 */
object NativeUsbSynthChannel {
    private const val CHANNEL = "com.example.diji_app_flutter/native_usb_synth"

    fun register(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(::onMethodCall)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "loadSoundfont" -> {
                val args = call.arguments
                val bytes = args as? ByteArray
                if (bytes == null || bytes.isEmpty()) {
                    result.error("BAD_ARGS", "Expected non-empty Uint8List (sf2 bytes)", null)
                    return
                }
                val ok = NativeUsbSynthEngine.loadUserSoundfont(bytes)
                result.success(ok)
            }
            "applyInstrument" -> {
                @Suppress("UNCHECKED_CAST")
                val map = call.arguments as? Map<String, Any?>
                val bank = when (val b = map?.get("bank")) {
                    is Int -> b
                    is Number -> b.toInt()
                    else -> 0
                }
                val preset = when (val p = map?.get("preset")) {
                    is Int -> p
                    is Number -> p.toInt()
                    else -> 0
                }
                val sustainPedal = when (val s = map?.get("sustainPedal")) {
                    is Int -> s.coerceIn(0, 1)
                    is Number -> s.toInt().coerceIn(0, 1)
                    else -> null
                }
                NativeUsbSynthEngine.applyInstrument(bank, preset, sustainPedal)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
