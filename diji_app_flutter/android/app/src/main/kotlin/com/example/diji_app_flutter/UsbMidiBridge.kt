package com.example.diji_app_flutter

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbManager
import android.media.midi.MidiDevice
import android.media.midi.MidiDeviceInfo
import android.media.midi.MidiManager
import android.media.midi.MidiOutputPort
import android.media.midi.MidiReceiver
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayList
import java.util.concurrent.atomic.AtomicInteger

/**
 * Forwards class-compliant USB MIDI from [MidiManager] to Flutter via [EventChannel],
 * and (when [NativeUsbSynthEngine] is ready) to the native TinySoundFont + [AudioTrack] path exclusively.
 */
object UsbMidiBridge {
    private const val TAG = "UsbMidiBridge"
    private const val METHOD_CHANNEL = "com.example.diji_app_flutter/usb_midi"
    private const val EVENT_CHANNEL = "com.example.diji_app_flutter/usb_midi_stream"
    const val USB_PERMISSION_ACTION = "com.example.diji_app_flutter.USB_PERMISSION"

    private val mainHandler = Handler(Looper.getMainLooper())
    private var appContext: Context? = null
    private var midiManager: MidiManager? = null
    private var eventSink: EventChannel.EventSink? = null
    private var methodChannel: MethodChannel? = null

    private var running = false
    private var deviceCallback: MidiManager.DeviceCallback? = null
    private val openedDevices = mutableMapOf<Int, MidiDevice>()
    private val connectedPorts = mutableListOf<MidiOutputPortConn>()
    private var usbReceiverRegistered = false
    private var usbAttachRegistered = false
    private var portNotifyRunnable: Runnable? = null

    /** Log first few native RX batches to logcat (tag UsbMidiBridge) for debugging empty monitors. */
    private val midiRxLogRemaining = AtomicInteger(12)

    private data class MidiOutputPortConn(
        val deviceId: Int,
        val port: MidiOutputPort,
        val receiver: MidiReceiver,
    )

    private val usbPermissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != USB_PERMISSION_ACTION) return
            val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
            Log.i(TAG, "USB permission broadcast: granted=$granted")
            if (granted && running) {
                rescanMidiDevices()
                schedulePortCountNotify(200)
            }
        }
    }

    private val usbAttachReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != UsbManager.ACTION_USB_DEVICE_ATTACHED) return
            Log.i(TAG, "USB_DEVICE_ATTACHED")
            if (!running) return
            requestUsbHostPermissionForAttachedDevices()
            mainHandler.postDelayed({
                if (running) rescanMidiDevices()
                schedulePortCountNotify(300)
            }, 250)
        }
    }

    fun register(messenger: io.flutter.plugin.common.BinaryMessenger, context: Context) {
        appContext = context.applicationContext

        methodChannel = MethodChannel(messenger, METHOD_CHANNEL).also { ch ->
            ch.setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
                when (call.method) {
                    "start" -> {
                        try {
                            val n = startInternal()
                            result.success(n)
                            schedulePortCountNotify(100)
                            scheduleDelayedRescans()
                        } catch (e: Exception) {
                            Log.e(TAG, "start failed", e)
                            result.error("USB_MIDI", e.message, null)
                        }
                    }
                    "stop" -> {
                        stopInternal()
                        result.success(null)
                    }
                    "portCount" -> {
                        val n = synchronized(connectedPorts) { connectedPorts.size }
                        result.success(n)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
                Log.i(TAG, "EventChannel onListen (sink set)")
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
                Log.i(TAG, "EventChannel onCancel (sink cleared)")
            }
        })

        ensureUsbPermissionReceiverRegistered()
        registerUsbAttachReceiver()
    }

    private fun ensureUsbPermissionReceiverRegistered() {
        val ctx = appContext ?: return
        if (usbReceiverRegistered) return
        val filter = IntentFilter(USB_PERMISSION_ACTION)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                ctx.registerReceiver(usbPermissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                ctx.registerReceiver(usbPermissionReceiver, filter)
            }
            usbReceiverRegistered = true
            Log.i(TAG, "USB permission receiver registered")
        } catch (e: Exception) {
            Log.e(TAG, "registerReceiver failed", e)
        }
    }

    private fun registerUsbAttachReceiver() {
        val ctx = appContext ?: return
        if (usbAttachRegistered) return
        val filter = IntentFilter(UsbManager.ACTION_USB_DEVICE_ATTACHED)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                ctx.registerReceiver(usbAttachReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("DEPRECATION")
                ctx.registerReceiver(usbAttachReceiver, filter)
            }
            usbAttachRegistered = true
            Log.i(TAG, "USB attach receiver registered")
        } catch (e: Exception) {
            Log.e(TAG, "USB attach registerReceiver failed", e)
        }
    }

    private fun requestUsbHostPermissionForAttachedDevices() {
        val ctx = appContext ?: return
        val usbManager = ctx.getSystemService(Context.USB_SERVICE) as? UsbManager ?: return
        ensureUsbPermissionReceiverRegistered()
        for (device in usbManager.deviceList.values) {
            if (usbManager.hasPermission(device)) continue
            Log.i(TAG, "Requesting USB permission for ${device.deviceName} (vid=${device.vendorId} pid=${device.productId})")
            // API 34+: FLAG_MUTABLE + implicit Intent is disallowed; package-scoped Intent is explicit.
            val permissionIntent = Intent(USB_PERMISSION_ACTION).setPackage(ctx.packageName)
            val piFlags = PendingIntent.FLAG_UPDATE_CURRENT or
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_MUTABLE
                } else {
                    0
                }
            val reqCode = device.hashCode() and 0x7FFF_FFFF
            val pending = PendingIntent.getBroadcast(
                ctx,
                reqCode,
                permissionIntent,
                piFlags,
            )
            try {
                usbManager.requestPermission(device, pending)
            } catch (e: Exception) {
                Log.e(TAG, "UsbManager.requestPermission failed", e)
            }
        }
    }

    /** True if the device can send MIDI into this app (Android “output” port = data out of peripheral). */
    private fun hasReceivableOutputs(info: MidiDeviceInfo): Boolean {
        if (info.outputPortCount > 0) return true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            for (p in info.ports) {
                if (p.type == MidiDeviceInfo.PortInfo.TYPE_OUTPUT) return true
            }
        }
        return false
    }

    private fun rescanMidiDevices() {
        val mm = midiManager ?: return
        Log.i(TAG, "Rescanning MIDI devices (${mm.devices.size} reported)")
        for (info in mm.devices) {
            openUsbDevice(info)
        }
    }

    private fun scheduleDelayedRescans() {
        mainHandler.postDelayed({
            if (running) {
                rescanMidiDevices()
                schedulePortCountNotify(50)
            }
        }, 500)
        mainHandler.postDelayed({
            if (running) {
                rescanMidiDevices()
                schedulePortCountNotify(50)
            }
        }, 1500)
        mainHandler.postDelayed({
            if (running) schedulePortCountNotify(50)
        }, 3500)
    }

    private fun schedulePortCountNotify(delayMs: Long) {
        portNotifyRunnable?.let { mainHandler.removeCallbacks(it) }
        val r = Runnable {
            portNotifyRunnable = null
            val ch = methodChannel ?: return@Runnable
            val n = synchronized(connectedPorts) { connectedPorts.size }
            try {
                ch.invokeMethod(
                    "usbMidiPortsUpdated",
                    n,
                    object : MethodChannel.Result {
                        override fun success(result: Any?) {}
                        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {}
                        override fun notImplemented() {}
                    },
                )
            } catch (e: Exception) {
                Log.e(TAG, "invokeMethod usbMidiPortsUpdated failed", e)
            }
        }
        portNotifyRunnable = r
        mainHandler.postDelayed(r, delayMs)
    }

    private fun startInternal(): Int {
        val ctx = appContext ?: throw IllegalStateException("No context")
        if (running) {
            return synchronized(connectedPorts) { connectedPorts.size }
        }
        running = true
        midiRxLogRemaining.set(12)
        NativeUsbSynthEngine.scheduleStart(ctx)
        val mm = ctx.getSystemService(Context.MIDI_SERVICE) as? MidiManager
            ?: throw IllegalStateException("MidiManager not available")
        midiManager = mm

        requestUsbHostPermissionForAttachedDevices()

        deviceCallback = object : MidiManager.DeviceCallback() {
            override fun onDeviceAdded(device: MidiDeviceInfo) {
                if (running) {
                    openUsbDevice(device)
                    schedulePortCountNotify(200)
                }
            }

            override fun onDeviceRemoved(device: MidiDeviceInfo) {
                closeDevice(device.id)
                schedulePortCountNotify(50)
            }
        }
        mm.registerDeviceCallback(deviceCallback!!, mainHandler)

        Log.i(TAG, "startInternal: ${mm.devices.size} MIDI device(s); (open is async — expect port updates shortly)")
        for (info in mm.devices) {
            logDeviceSummary(info)
            openUsbDevice(info)
        }
        return synchronized(connectedPorts) { connectedPorts.size }
    }

    private fun logDeviceSummary(info: MidiDeviceInfo) {
        val pi = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            " portInfos=${info.ports.size}"
        } else {
            ""
        }
        Log.i(
            TAG,
            "MIDI device id=${info.id} type=${info.type} outCount=${info.outputPortCount} inCount=${info.inputPortCount}$pi",
        )
    }

    private fun stopInternal() {
        if (!running) return
        running = false
        portNotifyRunnable?.let { mainHandler.removeCallbacks(it) }
        portNotifyRunnable = null
        midiManager?.let { mm ->
            deviceCallback?.let { mm.unregisterDeviceCallback(it) }
        }
        deviceCallback = null
        midiManager = null

        synchronized(openedDevices) {
            for (d in openedDevices.values) {
                try {
                    d.close()
                } catch (_: Exception) {
                }
            }
            openedDevices.clear()
        }
        synchronized(connectedPorts) {
            for (c in connectedPorts) {
                try {
                    c.port.disconnect(c.receiver)
                    c.port.close()
                } catch (_: Exception) {
                }
            }
            connectedPorts.clear()
        }
        NativeUsbSynthEngine.stop()
    }

    private fun openUsbDevice(info: MidiDeviceInfo) {
        // MidiManager lists USB, virtual, and Bluetooth MIDI devices. Virtual ports (often 2 on OEM builds)
        // open without a keyboard and confuse the “USB MIDI” UI — only class-compliant USB host devices here.
        if (info.type != MidiDeviceInfo.TYPE_USB) {
            Log.i(
                TAG,
                "skip id=${info.id} type=${info.type}: not TYPE_USB (virtual/Bluetooth MIDI ignored for this bridge)",
            )
            return
        }
        if (!hasReceivableOutputs(info)) {
            Log.w(
                TAG,
                "skip id=${info.id} type=${info.type}: no receivable outputs (outputPortCount=${info.outputPortCount})",
            )
            return
        }
        val mm = midiManager ?: return
        if (openedDevices.containsKey(info.id)) return

        Log.i(TAG, "openUsbDevice id=${info.id} type=${info.type} outputPortCount=${info.outputPortCount}")

        mm.openDevice(info, { device ->
            if (device == null) {
                Log.w(
                    TAG,
                    "openDevice(null) id=${info.id} — grant USB permission, OTG cable, or replug",
                )
                return@openDevice
            }
            synchronized(openedDevices) {
                if (!running) {
                    try {
                        device.close()
                    } catch (_: Exception) {
                    }
                    return@openDevice
                }
                openedDevices[info.id] = device
                val opened = connectAllReceivableOutputs(device, info)
                val totalConn = synchronized(connectedPorts) { connectedPorts.size }
                Log.i(TAG, "device id=${info.id} connected $opened output port(s), total=$totalConn")
                if (opened == 0) {
                    openedDevices.remove(info.id)
                    try {
                        device.close()
                    } catch (_: Exception) {
                    }
                } else {
                    schedulePortCountNotify(80)
                }
            }
        }, mainHandler)
    }

    private fun connectAllReceivableOutputs(device: MidiDevice, info: MidiDeviceInfo): Int {
        var opened = 0
        val openedPortNumbers = mutableSetOf<Int>()
        // Open by index first: some devices list extra TYPE_OUTPUT PortInfos that open successfully
        // but are not the jack that carries keyboard traffic; the old "PortInfo first, else index"
        // path could skip real ports entirely when opened > 0 from a dummy port.
        for (i in 0 until info.outputPortCount) {
            val out = try {
                device.openOutputPort(i)
            } catch (e: Exception) {
                Log.e(TAG, "openOutputPort($i) by index failed", e)
                null
            } ?: continue
            opened += attachMidiReceiver(info.id, out)
            openedPortNumbers.add(i)
        }
        // Devices that report outputPortCount=0 but still expose OUTPUT ports in PortInfo (API 29+).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && info.ports.isNotEmpty()) {
            for (portInfo in info.ports) {
                if (portInfo.type != MidiDeviceInfo.PortInfo.TYPE_OUTPUT) continue
                val n = portInfo.portNumber
                if (n in openedPortNumbers) continue
                val out = try {
                    device.openOutputPort(n)
                } catch (e: Exception) {
                    Log.e(TAG, "openOutputPort($n) from PortInfo supplement failed", e)
                    null
                } ?: continue
                opened += attachMidiReceiver(info.id, out)
                openedPortNumbers.add(n)
            }
        }
        return opened
    }

    private fun attachMidiReceiver(deviceId: Int, port: MidiOutputPort): Int {
        val recv = object : MidiReceiver() {
            override fun onSend(msg: ByteArray, offset: Int, count: Int, timestamp: Long) {
                if (count <= 0) return
                try {
                    Process.setThreadPriority(Process.THREAD_PRIORITY_MORE_FAVORABLE)
                } catch (_: Exception) {
                }
                val copy = msg.copyOfRange(offset, offset + count)
                if (midiRxLogRemaining.getAndDecrement() > 0) {
                    val preview = copy.take(8).joinToString(" ") { b -> "%02x".format(b.toInt() and 0xFF) }
                    Log.i(TAG, "MIDI RX $count B (preview: $preview${if (copy.size > 8) " …" else ""})")
                }
                forwardToFlutter(copy)
            }
        }
        return try {
            port.connect(recv)
            synchronized(connectedPorts) {
                connectedPorts.add(MidiOutputPortConn(deviceId, port, recv))
            }
            1
        } catch (e: Exception) {
            Log.e(TAG, "MidiOutputPort.connect failed", e)
            try {
                port.close()
            } catch (_: Exception) {
            }
            0
        }
    }

    private fun closeDevice(deviceId: Int) {
        synchronized(connectedPorts) {
            val iter = connectedPorts.iterator()
            while (iter.hasNext()) {
                val c = iter.next()
                if (c.deviceId == deviceId) {
                    try {
                        c.port.disconnect(c.receiver)
                        c.port.close()
                    } catch (_: Exception) {
                    }
                    iter.remove()
                }
            }
        }
        synchronized(openedDevices) {
            openedDevices.remove(deviceId)?.close()
        }
    }

    /**
     * Flutter’s Android embedder expects [EventChannel.EventSink.success] on the main looper;
     * calling it from the MIDI binder thread drops events (no packets in Dart / WebView).
     * Uses [Handler.postAtFrontOfQueue] so MIDI delivery runs before most other main-thread work.
     */
    private fun forwardToFlutter(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        if (NativeUsbSynthEngine.exclusiveUsbMidiReady()) {
            NativeUsbSynthEngine.pushMidi(bytes)
            return
        }
        val payload = ArrayList<Int>(bytes.size)
        for (b in bytes) {
            payload.add(b.toInt() and 0xFF)
        }
        mainHandler.postAtFrontOfQueue emit@{
            val sink = eventSink
            if (sink == null) {
                Log.w(TAG, "forwardToFlutter: no EventSink; dropped ${payload.size} ints")
                return@emit
            }
            try {
                sink.success(payload)
            } catch (e: Exception) {
                Log.e(TAG, "sink.success failed (${payload.size} ints)", e)
            }
        }
    }
}
