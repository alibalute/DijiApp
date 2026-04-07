#include <android/log.h>
#include <jni.h>

#include <cstdint>
#include <cstring>
#include <mutex>

#define TSF_IMPLEMENTATION
#include "third_party/tsf.h"

#define LOG_TAG "NativeUsbSynth"
#define ALOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define ALOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

std::mutex g_lock;
tsf* g_tsf = nullptr;
int g_sample_rate = 48000;

constexpr size_t kMidiRingSize = 65536;
uint8_t g_midi_ring[kMidiRingSize];
size_t g_midi_w = 0;
size_t g_midi_r = 0;

// MIDI stream parser (running status, voice messages; skip SysEx / real-time)
uint8_t g_running_status = 0;
int g_d0 = -1;
bool g_in_sysex = false;

inline bool midi_ring_push_byte(uint8_t b) {
    size_t nw = (g_midi_w + 1) % kMidiRingSize;
    if (nw == g_midi_r) {
        return false;
    }
    g_midi_ring[g_midi_w] = b;
    g_midi_w = nw;
    return true;
}

static void handle_voice_message(uint8_t status, int d1, int d2) {
    if (!g_tsf) {
        return;
    }
    const int ch = status & 0x0F;
    const int cmd = status & 0xF0;
    const int drums = (ch == 9) ? 1 : 0;
    switch (cmd) {
        case 0x80:
            tsf_channel_note_off(g_tsf, ch, d1);
            break;
        case 0x90: {
            const float v = d2 / 127.0f;
            if (d2 == 0) {
                tsf_channel_note_off(g_tsf, ch, d1);
            } else {
                tsf_channel_note_on(g_tsf, ch, d1, v);
            }
            break;
        }
        case 0xB0:
            tsf_channel_midi_control(g_tsf, ch, d1, d2);
            break;
        case 0xC0:
            tsf_channel_set_presetnumber(g_tsf, ch, d1, drums);
            break;
        case 0xD0:
            break;
        case 0xE0: {
            const int wheel = (d2 << 7) | d1;
            tsf_channel_set_pitchwheel(g_tsf, ch, wheel);
            break;
        }
        default:
            break;
    }
}

static void process_midi_byte(uint8_t b) {
    if (b >= 0xF8) {
        return;
    }
    if (g_in_sysex) {
        if (b == 0xF7) {
            g_in_sysex = false;
        }
        return;
    }
    if (b == 0xF0) {
        g_in_sysex = true;
        return;
    }
    if (b >= 0x80) {
        g_running_status = b;
        g_d0 = -1;
        return;
    }
    if (g_running_status == 0) {
        return;
    }
    const int cmd = g_running_status & 0xF0;
    if (cmd == 0xC0 || cmd == 0xD0) {
        if (g_d0 < 0) {
            handle_voice_message(g_running_status, b, 0);
        }
        return;
    }
    if (g_d0 < 0) {
        g_d0 = static_cast<int>(b);
        return;
    }
    handle_voice_message(g_running_status, g_d0, static_cast<int>(b));
    g_d0 = -1;
}

static void drain_midi_ring_locked() {
    while (g_midi_r != g_midi_w) {
        const uint8_t b = g_midi_ring[g_midi_r];
        g_midi_r = (g_midi_r + 1) % kMidiRingSize;
        process_midi_byte(b);
    }
}

}  // namespace

extern "C" {

JNIEXPORT jboolean JNICALL
Java_com_example_diji_1app_1flutter_NativeUsbSynthEngine_nativeInit(JNIEnv* env, jclass, jint sampleRate) {
    (void)env;
    std::lock_guard<std::mutex> lock(g_lock);
    g_sample_rate = sampleRate > 0 ? sampleRate : 48000;
    g_midi_w = g_midi_r = 0;
    g_running_status = 0;
    g_d0 = -1;
    g_in_sysex = false;
    return JNI_TRUE;
}

JNIEXPORT void JNICALL
Java_com_example_diji_1app_1flutter_NativeUsbSynthEngine_nativeShutdown(JNIEnv* env, jclass) {
    (void)env;
    std::lock_guard<std::mutex> lock(g_lock);
    if (g_tsf) {
        tsf_close(g_tsf);
        g_tsf = nullptr;
    }
    g_midi_w = g_midi_r = 0;
    g_running_status = 0;
    g_d0 = -1;
    g_in_sysex = false;
}

JNIEXPORT jboolean JNICALL
Java_com_example_diji_1app_1flutter_NativeUsbSynthEngine_nativeLoadSoundfont(JNIEnv* env, jclass, jbyteArray data) {
    if (!data) {
        return JNI_FALSE;
    }
    const jsize len = env->GetArrayLength(data);
    if (len <= 0) {
        return JNI_FALSE;
    }
    jbyte* bytes = env->GetByteArrayElements(data, nullptr);
    if (!bytes) {
        return JNI_FALSE;
    }
    std::lock_guard<std::mutex> lock(g_lock);
    if (g_tsf) {
        tsf_close(g_tsf);
        g_tsf = nullptr;
    }
    g_tsf = tsf_load_memory(bytes, len);
    env->ReleaseByteArrayElements(data, bytes, JNI_ABORT);
    if (!g_tsf) {
        ALOGE("tsf_load_memory failed");
        return JNI_FALSE;
    }
    tsf_set_output(g_tsf, TSF_STEREO_INTERLEAVED, g_sample_rate, 0.0f);
    tsf_set_volume(g_tsf, 0.55f);
    /* Was 2 for minimal RAM; strumming needs many simultaneous notes (Web FluidSynth has no such cap). */
    tsf_set_max_voices(g_tsf, 64);
    for (int c = 0; c < 16; c++) {
        tsf_channel_set_presetnumber(g_tsf, c, 0, c == 9 ? 1 : 0);
    }
    ALOGI("SoundFont loaded, sampleRate=%d", g_sample_rate);
    return JNI_TRUE;
}

JNIEXPORT void JNICALL
Java_com_example_diji_1app_1flutter_NativeUsbSynthEngine_nativeApplyInstrument(JNIEnv* env, jclass, jint bank,
                                                                               jint preset, jint sustainPedal) {
    (void)env;
    std::lock_guard<std::mutex> lock(g_lock);
    if (!g_tsf) {
        return;
    }
    const int b = bank < 0 ? 0 : bank;
    const int p = preset < 0 ? 0 : preset;
    for (int ch = 0; ch < 16; ch++) {
        tsf_channel_set_bank_preset(g_tsf, ch, b, p);
    }
    // sustainPedal: -1 = leave CC64 unchanged; 0 = off; 1 = on (CC64 = 127)
    if (sustainPedal == 0 || sustainPedal == 1) {
        const int cc64 = sustainPedal ? 127 : 0;
        for (int ch = 0; ch < 16; ch++) {
            tsf_channel_midi_control(g_tsf, ch, 64, cc64);
        }
    }
}

JNIEXPORT void JNICALL
Java_com_example_diji_1app_1flutter_NativeUsbSynthEngine_nativePushMidi(JNIEnv* env, jclass, jbyteArray data, jint offset,
                                                                        jint length) {
    if (!data || length <= 0) {
        return;
    }
    jbyte* bytes = env->GetByteArrayElements(data, nullptr);
    if (!bytes) {
        return;
    }
    std::lock_guard<std::mutex> lock(g_lock);
    const int end = offset + length;
    for (int i = offset; i < end; i++) {
        const auto b = static_cast<uint8_t>(bytes[i]);
        if (!midi_ring_push_byte(b)) {
            break;
        }
    }
    env->ReleaseByteArrayElements(data, bytes, JNI_ABORT);
}

JNIEXPORT jint JNICALL
Java_com_example_diji_1app_1flutter_NativeUsbSynthEngine_nativeRender(JNIEnv* env, jclass, jshortArray outPcm) {
    if (!outPcm) {
        return 0;
    }
    const jsize totalShorts = env->GetArrayLength(outPcm);
    if (totalShorts < 2) {
        return 0;
    }
    constexpr int kMaxRenderFrames = 64;
    int frames = static_cast<int>(totalShorts / 2);
    if (frames > kMaxRenderFrames) {
        frames = kMaxRenderFrames;
    }
    jshort tmp[kMaxRenderFrames * 2];
    std::lock_guard<std::mutex> lock(g_lock);
    if (!g_tsf) {
        std::memset(tmp, 0, sizeof(tmp[0]) * static_cast<size_t>(frames) * 2);
        env->SetShortArrayRegion(outPcm, 0, frames * 2, tmp);
        return frames;
    }
    drain_midi_ring_locked();
    tsf_render_short(g_tsf, reinterpret_cast<short*>(tmp), frames, 0);
    env->SetShortArrayRegion(outPcm, 0, frames * 2, tmp);
    return frames;
}

}  // extern "C"
