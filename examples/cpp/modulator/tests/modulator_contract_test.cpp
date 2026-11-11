// Exercises the example modulator through the C interface: two modulation outputs, values 0..1, hits on the pattern.
#include <caw/component.hpp>

#include <cstring>

int main() {
    const CawComponentV3* component = caw_get_component_v3(0);
    if (!component || component->abi_version != CAW_COMPONENT_ABI_VERSION) return 1;
    const CawComponentDescriptor* d = component->descriptor;
    if (!d || std::strcmp(d->id, "org.caw.examples.euclid") != 0 || d->port_count != 2 ||
        d->ports[0].type != CAW_PORT_MODULATION || d->ports[0].is_input)
        return 2;
    const CawHost host{sizeof(CawHost), CAW_COMPONENT_ABI_VERSION, "test", "0", nullptr, nullptr};
    void* instance = component->create(&host);
    if (!instance || component->activate(instance, 48000.0, 16) != 1) return 3;
    float gate[16], ramp[16];
    float* outs[] = {gate, ramp};
    int hits = 0;
    bool inRange = true, wasOn = false;
    for (int block = 0; block < 12000; ++block) {  // four seconds at 120 BPM: two bars of 16 sixteenths, 5 hits each
        CawProcessBlock b{};
        b.struct_size = sizeof(CawProcessBlock);
        b.frames = 16;
        b.sample_rate = 48000.0;
        b.modulation_out = outs;
        b.modulation_out_count = 2;
        if (component->process(instance, &b) != 1) return 4;
        for (int i = 0; i < 16; ++i) {
            inRange = inRange && gate[i] >= 0.0f && gate[i] <= 1.0f && ramp[i] >= 0.0f && ramp[i] <= 1.0f;
            const bool on = gate[i] > 0.5f;
            hits += on && !wasOn;
            wasOn = on;
        }
    }
    component->deactivate(instance);
    component->destroy(instance);
    return inRange && hits >= 9 && hits <= 11 ? 0 : 5;  // 2 bars of 5 hits
}
