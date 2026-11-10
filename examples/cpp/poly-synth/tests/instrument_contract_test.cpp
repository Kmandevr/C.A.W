// Plays the example instrument through its one exported entry point: a note on starts sound on its frame, an off releases it.
#include <caw/component.hpp>
#include <caw/instrument.hpp>

#include <cmath>
#include <cstring>

int main() {
    const CawComponentV3* component = caw_get_component_v3(0);
    if (!component || component->abi_version != CAW_COMPONENT_ABI_VERSION) return 1;
    const CawComponentDescriptor* d = component->descriptor;
    if (!d || std::strcmp(d->id, "org.caw.examples.poly-synth") != 0 || d->role != CAW_ROLE_INSTRUMENT ||
        d->port_count != 2 || d->ports[0].type != CAW_PORT_EVENT || !d->ports[0].is_input)
        return 2;
    const CawHost host{sizeof(CawHost), CAW_COMPONENT_ABI_VERSION, "test", "0", nullptr, nullptr};
    void* instance = component->create(&host);
    if (!instance || component->activate(instance, 48000.0, 64) != 1) return 3;

    float left[64], right[64];
    float* channels[] = {left, right};
    const CawAudio out{channels, 2, 64};
    const caw::Event on = caw::notes::noteOn(16, 1, 69.0, 1.0);  // A4 on frame 16
    CawEvent events[1];
    std::memcpy(&events[0], &on, sizeof on);
    CawEventInput input{events, 1};
    CawProcessBlock block{};
    block.struct_size = sizeof(CawProcessBlock);
    block.frames = 64;
    block.sample_rate = 48000.0;
    block.audio_out = &out;
    block.audio_out_count = 1;
    block.event_in = &input;
    block.event_in_count = 1;
    if (component->process(instance, &block) != 1) return 4;
    for (int i = 0; i < 16; ++i)
        if (left[i] != 0.0f) return 5;  // silent before its frame
    float energy = 0;
    for (int i = 16; i < 64; ++i) energy += std::fabs(left[i]);
    if (!(energy > 0.0f)) return 6;
    // An off: the release falls to silence within 0.3 s.
    const caw::Event off = caw::notes::noteOff(0, 1, 69);
    std::memcpy(&events[0], &off, sizeof off);
    for (int k = 0; k < 400; ++k) {
        if (component->process(instance, &block) != 1) return 7;
        input.count = 0;
    }
    if (left[63] != 0.0f) return 8;
    component->deactivate(instance);
    component->destroy(instance);
    return 0;
}
