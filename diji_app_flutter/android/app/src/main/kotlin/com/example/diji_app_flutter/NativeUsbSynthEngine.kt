package com.example.diji_app_flutter

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Process
import android.util.Log
import io.flutter.FlutterInjector
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * USB MIDI → TinySoundFont (JNI) → [AudioTrack] on a high-priority thread.
 * When [exclusiveUsbMidiReady] is true, [UsbMidiBridge] skips the WebView/EventChannel path for USB bytes.
 */
object NativeUsbSynthEngine {
    private const val TAG = "NativeUsbSynth"
    private const val SAMPLE_RATE = 48_000
    /** Small render quantum (~2.7 ms @ 48 kHz) to reduce USB MIDI → speaker latency. */
    private const val FRAMES_PER_CHUNK = 64
    private const val BUNDLED_SF2 = "assets/synth/VintageDreamsWaves-v2.sf2"

    private val loadStarted = AtomicBoolean(false)
    private val audioRunning = AtomicBoolean(false)
    private val exclusiveReady = AtomicBoolean(false)
    private val nativeReady = AtomicBoolean(false)
    private val pendingUserSf2 = AtomicReference<ByteArray?>(null)
    private val sfLock = Any()

    @Volatile
    private var worker: Thread? = null

    init {
        System.loadLibrary("native_usb_synth")
    }

    @JvmStatic
    private external fun nativeInit(sampleRate: Int): Boolean

    @JvmStatic
    private external fun nativeShutdown()

    @JvmStatic
    private external fun nativeLoadSoundfont(data: ByteArray): Boolean

    @JvmStatic
    private external fun nativePushMidi(data: ByteArray, offset: Int, length: Int)

    @JvmStatic
    private external fun nativeApplyInstrument(bank: Int, preset: Int)

    @JvmStatic
    private external fun nativeRender(outPcm: ShortArray): Int

    fun exclusiveUsbMidiReady(): Boolean = exclusiveReady.get()

    fun pushMidi(bytes: ByteArray) {
        if (!exclusiveReady.get() || bytes.isEmpty()) return
        nativePushMidi(bytes, 0, bytes.size)
    }

    /** SF2 bank + MIDI program (preset number) for all 16 channels — used when WebView instrument list changes. */
    fun applyInstrument(bank: Int, preset: Int) {
        if (!nativeReady.get()) return
        try {
            nativeApplyInstrument(bank, preset)
        } catch (e: Exception) {
            Log.e(TAG, "applyInstrument", e)
        }
    }

    /**
     * Load a SoundFont from raw bytes. If the native engine is not up yet, stores bytes and applies
     * them when the USB synth thread starts (before bundled fallback).
     */
    fun loadUserSoundfont(data: ByteArray): Boolean {
        if (data.isEmpty()) return false
        synchronized(sfLock) {
            pendingUserSf2.set(data)
            if (nativeReady.get()) {
                return nativeLoadSoundfont(data)
            }
        }
        return true
    }

    fun scheduleStart(context: Context) {
        if (!loadStarted.compareAndSet(false, true)) return
        val app = context.applicationContext
        val t = Thread(
            {
                try {
                    if (!nativeInit(SAMPLE_RATE)) {
                        Log.e(TAG, "nativeInit failed")
                        return@Thread
                    }
                    val sf2Ok = synchronized(sfLock) {
                        val sf2 = pendingUserSf2.getAndSet(null) ?: loadBundledSoundfont(app)
                        if (sf2 == null || !nativeLoadSoundfont(sf2)) {
                            false
                        } else {
                            nativeReady.set(true)
                            true
                        }
                    }
                    if (!sf2Ok) {
                        Log.e(TAG, "SoundFont load failed")
                        nativeShutdown()
                        return@Thread
                    }
                    exclusiveReady.set(true)
                    runAudioLoop()
                } catch (e: Exception) {
                    Log.e(TAG, "native synth thread failed", e)
                    exclusiveReady.set(false)
                    try {
                        nativeShutdown()
                    } catch (_: Exception) {
                    }
                } finally {
                    exclusiveReady.set(false)
                    nativeReady.set(false)
                    audioRunning.set(false)
                    loadStarted.set(false)
                    worker = null
                }
            },
            "native-usb-synth",
        )
        t.priority = Thread.MAX_PRIORITY
        worker = t
        t.start()
    }

    fun stop() {
        exclusiveReady.set(false)
        nativeReady.set(false)
        audioRunning.set(false)
        worker?.interrupt()
        try {
            worker?.join(3000)
        } catch (_: InterruptedException) {
        }
        worker = null
        loadStarted.set(false)
        try {
            nativeShutdown()
        } catch (_: Exception) {
        }
    }

    private fun loadBundledSoundfont(context: Context): ByteArray? {
        return try {
            val loader = FlutterInjector.instance().flutterLoader()
            if (loader.initialized()) {
                try {
                    val key = loader.getLookupKeyForAsset(BUNDLED_SF2)
                    return context.assets.open(key).use { it.readBytes() }
                } catch (_: Exception) {
                    /* fall through to literal flutter_assets path */
                }
            } else {
                Log.w(TAG, "FlutterLoader not initialized; trying flutter_assets/ path")
            }
            context.assets.open("flutter_assets/$BUNDLED_SF2").use { it.readBytes() }
        } catch (e: Exception) {
            Log.e(TAG, "loadBundledSoundfont", e)
            null
        }
    }

    private fun runAudioLoop() {
        audioRunning.set(true)
        Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        val minBuf = AudioTrack.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) {
            Log.e(TAG, "getMinBufferSize failed")
            return
        }
        val bufBytes = minBuf.coerceAtLeast(FRAMES_PER_CHUNK * 2 * 2 * 2)
        val track = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val b = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setSampleRate(SAMPLE_RATE)
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                        .build(),
                )
                .setBufferSizeInBytes(bufBytes)
                .setTransferMode(AudioTrack.MODE_STREAM)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                b.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            }
            b.build()
        } else {
            @Suppress("DEPRECATION")
            AudioTrack(
                AudioManager.STREAM_MUSIC,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_OUT_STEREO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufBytes,
                AudioTrack.MODE_STREAM,
            )
        }
        val pcm = ShortArray(FRAMES_PER_CHUNK * 2)
        try {
            track.play()
            while (audioRunning.get() && !Thread.currentThread().isInterrupted) {
                val frames = nativeRender(pcm)
                if (frames <= 0) continue
                var off = 0
                val samples = frames * 2
                while (off < samples && audioRunning.get()) {
                    val w = track.write(pcm, off, samples - off)
                    if (w < 0) {
                        Log.w(TAG, "AudioTrack.write=$w")
                        break
                    }
                    off += w
                }
            }
        } finally {
            try {
                track.stop()
            } catch (_: Exception) {
            }
            track.release()
        }
    }
}
