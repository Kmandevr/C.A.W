// A chosen audio device as the app names it to the platform layer (#242): AAudio's device ids, which the app reads from Android's AudioManager.
#pragma once

#include <cstdint>
#include <string_view>

namespace caw {

// The app names an Android device by its AudioDeviceInfo id as "aaudio:<id>": the id AAudioStreamBuilder_setDeviceId
// takes ([Fact, developer.android.com NDK AAudio reference, read 2026-11-18] "deviceId: device identifier or
// AAUDIO_UNSPECIFIED", the id of an android.media.AudioDeviceInfo; miniaudio 0.11.25 passes ma_device_id.aaudio to
// it). Ids are given per connection, so the app keeps its own key for a device and sends the id it has now.
inline constexpr std::string_view kAAudioIdPrefix = "aaudio:";

// The id in [text] (> 0), else 0: not an AAudio id, no digits, junk after them, or out of range (untrusted text from
// the settings file: digits only, at most 2^31 - 1).
inline int32_t aaudioDeviceId(std::string_view text) noexcept {
    if (text.substr(0, kAAudioIdPrefix.size()) != kAAudioIdPrefix) return 0;
    text.remove_prefix(kAAudioIdPrefix.size());
    if (text.empty() || text.size() > 10) return 0;
    int64_t v = 0;
    for (const char c : text) {
        if (c < '0' || c > '9') return 0;
        v = v * 10 + (c - '0');
    }
    return v > 0 && v <= INT32_MAX ? static_cast<int32_t>(v) : 0;
}

// Whether a stream opened for a chosen device runs on it: [routed] is the stream's own device id
// (AAudioStream_getDeviceId; 0 unknown). Android may open another device than the one asked (a route policy), and
// miniaudio reopens the default after a disconnect (0.11.25 ma_device_reinit__aaudio: "Only doing rerouting with
// default devices"), so the status compares them. Nothing chosen, or not known: true.
inline bool onChosenDevice(int32_t chosen, int32_t routed) noexcept { return chosen <= 0 || routed <= 0 || routed == chosen; }

}  // namespace caw
