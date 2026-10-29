// Offscreen presentation and stereo output for Apple Vision Pro. The Vulkan presenter copies
// each frame into an exported image ring (video_core/offscreen_output.h); the app reads the
// newest one as an MTLTexture. Licensed under GPLv2 or any later version.

#include "az_internal.h"
#include "video_core/offscreen_output.h"

extern "C" void az_set_offscreen_output(bool enabled) {
    VideoCore::Offscreen::Get().requested = enabled;
}

extern "C" bool az_offscreen_acquire(AZOffscreenFrame* out) {
    if (!out) {
        return false;
    }
    const auto frame = VideoCore::Offscreen::Acquire();
    if (frame.slot < 0 || !frame.texture) {
        if (frame.slot >= 0) {
            VideoCore::Offscreen::Release(frame.slot);
        }
        return false;
    }
    out->texture = frame.texture;
    out->slot = frame.slot;
    out->frame = frame.frame;
    out->generation = frame.generation;
    out->width = static_cast<int>(frame.width);
    out->height = static_cast<int>(frame.height);
    return true;
}

extern "C" void az_offscreen_release(int slot) {
    VideoCore::Offscreen::Release(slot);
}

extern "C" void az_set_stereo(bool enabled, int depth_percent) {
    AzIOS::Config::SetStereoOverride(enabled, depth_percent);
}

// Live 3D slider: only the setting the HID pad update reads each poll (and the stored stereo
// depth, so a later config load keeps it). No config reload, no renderer, audio, input or timing
// re-init: games see the slider move as on a real 3DS.
#include <algorithm>
#include "common/settings.h"
extern "C" void az_set_3d_slider(int depth_percent) {
    const int d = std::clamp(depth_percent, 0, 100);
    AzIOS::Config::SetStereoOverride(true, d);
    Settings::values.factor_3d.SetValue(static_cast<u32>(d));
}

// Recorder audio tap (patch 0013): forwards the DSP's mixed output to the app's recorder.
#include "audio_core/audio_types.h"
#include "audio_core/dsp_interface.h"
extern "C" void az_set_audio_tap(void (*tap)(const int16_t*, size_t, void*), void* context) {
    AudioCore::DspInterface::SetAudioTap(tap, context);
}
extern "C" int az_audio_sample_rate(void) {
    return static_cast<int>(AudioCore::native_sample_rate);
}
