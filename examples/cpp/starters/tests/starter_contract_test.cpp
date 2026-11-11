// Plays one C++ starter through its exported entry point: an instrument sounds on its note and falls quiet after the off; an effect changes the sound only on the last 16th of each beat.
#include <caw/component.hpp>
#include <caw/instrument.hpp>

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#ifndef STARTER_ID
#error "STARTER_ID names the starter's component id"
#endif

namespace {

constexpr uint32_t kBlock = 64;
constexpr double kRate = 48000;

int fail(int code, const char* what) {
    std::fprintf(stderr, "%s: %s\n", STARTER_ID, what);
    return code;
}

struct Run {
    const CawComponentV3* c;
    void* instance;
    std::vector<float> left = std::vector<float>(kBlock), right = std::vector<float>(kBlock);
    std::vector<float> inL = std::vector<float>(kBlock), inR = std::vector<float>(kBlock);
    CawTransport transport{sizeof(CawTransport), CAW_TRANSPORT_PLAYING, 120.0, 0.0, 4, 0};

    // One block; `events` are written at their frames. False if the component refused it.
    bool block(const std::vector<caw::Event>& events, bool effect) {
        std::vector<CawEvent> raw(events.size());
        for (size_t k = 0; k < events.size(); ++k) std::memcpy(&raw[k], &events[k], sizeof(CawEvent));
        float* out[] = {left.data(), right.data()};
        const float* in[] = {inL.data(), inR.data()};
        const CawAudio audioOut{out, 2, kBlock};
        const CawConstAudio audioIn{in, 2, kBlock};
        CawEventInput input{raw.data(), static_cast<uint32_t>(raw.size())};
        CawProcessBlock b{};
        b.struct_size = sizeof(CawProcessBlock);
        b.frames = kBlock;
        b.sample_rate = kRate;
        b.audio_out = &audioOut;
        b.audio_out_count = 1;
        if (effect) {
            b.audio_in = &audioIn;
            b.audio_in_count = 1;
        } else {
            b.event_in = &input;
            b.event_in_count = 1;
        }
        b.transport = &transport;
        const bool ok = c->process(instance, &b) == 1;
        transport.beat += kBlock * transport.tempo / 60.0 / kRate;
        return ok;
    }
};

}  // namespace

int main() {
    const CawComponentV3* c = caw_get_component_v3(0);
    if (!c || c->abi_version != CAW_COMPONENT_ABI_VERSION) return fail(1, "no component");
    const CawComponentDescriptor* d = c->descriptor;
    if (!d || std::strcmp(d->id, STARTER_ID) != 0) return fail(2, "wrong id");
    const bool effect = d->role == CAW_ROLE_EFFECT;
    if (!effect && d->role != CAW_ROLE_INSTRUMENT) return fail(2, "neither an instrument nor an effect");
    const CawHost host{sizeof(CawHost), CAW_COMPONENT_ABI_VERSION, "test", "0", nullptr, nullptr};
    Run r{c, c->create(&host)};
    if (!r.instance || c->activate(r.instance, kRate, kBlock) != 1) return fail(3, "did not activate");

    if (effect) {
        // A sine through it for two beats: the output follows the input except on each beat's last 16th.
        double phase = 0, inside = 0, outside = 0;
        for (int k = 0; k < 2 * 24000 / static_cast<int>(kBlock); ++k) {
            const double beat = r.transport.beat;
            for (uint32_t i = 0; i < kBlock; ++i) {
                r.inL[i] = r.inR[i] = static_cast<float>(0.5 * std::sin(phase));
                phase += 2 * 3.14159265358979 * 220 / kRate;
            }
            if (!r.block({}, true)) return fail(4, "refused a block");
            for (uint32_t i = 0; i < kBlock; ++i) {
                if (!std::isfinite(r.left[i]) || std::fabs(r.left[i]) > 2) return fail(5, "not finite or too loud");
                const double b = beat + i * 120.0 / 60.0 / kRate;
                (b - std::floor(b) >= 0.75 ? inside : outside) += std::fabs(r.left[i] - r.inL[i]);
            }
        }
        if (!(outside == 0.0)) return fail(6, "changed the sound outside the glitch step");
        if (!(inside > 1.0)) return fail(7, "did not glitch");
    } else {
        // A note on frame 16 of the first block (the hats' open key, a pitch every starter plays), held 0.5 s.
        const caw::Event on = caw::notes::noteOn(16, 1, 46.0, 0.9);
        double energy = 0;
        if (!r.block({on}, false)) return fail(4, "refused a block");
        for (uint32_t i = 0; i < 16; ++i)
            if (r.left[i] != 0.0f) return fail(5, "sounded before its note");
        for (int k = 1; k < 24000 / static_cast<int>(kBlock); ++k) {
            if (!r.block({}, false)) return fail(4, "refused a block");
            for (uint32_t i = 0; i < kBlock; ++i) {
                if (!std::isfinite(r.left[i]) || std::fabs(r.left[i]) > 2) return fail(5, "not finite or too loud");
                energy += std::fabs(r.left[i]) + std::fabs(r.right[i]);
            }
        }
        if (!(energy > 10.0)) return fail(6, "silent");
        // The off; within 3 s it is silent.
        if (!r.block({caw::notes::noteOff(0, 1, 46)}, false)) return fail(4, "refused a block");
        float last = 1;
        for (int k = 0; k < 3 * 48000 / static_cast<int>(kBlock); ++k) {
            if (!r.block({}, false)) return fail(4, "refused a block");
            last = std::fabs(r.left[kBlock - 1]);
        }
        if (!(last < 1e-4f)) return fail(7, "still sounding 3 s after the off");
    }
    c->deactivate(r.instance);
    c->destroy(r.instance);
    return 0;
}
