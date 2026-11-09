// Exercises the component through its one exported entry point, the C interface (caw_component.h).
#include <caw/component.hpp>

#include <cstring>

int main() {
    const CawComponentV3* component = caw_get_component_v3(0);
    if (caw_get_component_v3(1) != nullptr) return 5;  // one component: nothing past index 0
    if (!component || component->struct_size < sizeof(CawComponentV3) ||
        component->abi_version != CAW_COMPONENT_ABI_VERSION)
        return 1;
    const CawComponentDescriptor* d = component->descriptor;
    if (!d || std::strcmp(d->id, "org.caw.examples.minimal") != 0 || d->port_count != 2 ||
        d->ports[0].layout != CAW_LAYOUT_STEREO || !d->ports[0].is_input || d->ports[1].is_input)
        return 2;

    const CawHost host{sizeof(CawHost), CAW_COMPONENT_ABI_VERSION, "test", "0", nullptr, nullptr};
    void* instance = component->create(&host);
    if (!instance || component->activate(instance, 48000.0, 2) != 1) return 3;

    const float leftIn[] = {0.25f, -0.5f};
    const float rightIn[] = {-0.75f, 1.0f};
    float leftOut[] = {0.0f, 0.0f};
    float rightOut[] = {0.0f, 0.0f};
    const float* inChannels[] = {leftIn, rightIn};
    float* outChannels[] = {leftOut, rightOut};
    const CawConstAudio in{inChannels, 2, 2};
    const CawAudio out{outChannels, 2, 2};
    CawProcessBlock block{};
    block.struct_size = sizeof(CawProcessBlock);
    block.frames = 2;
    block.sample_rate = 48000.0;
    block.audio_in = &in;
    block.audio_in_count = 1;
    block.audio_out = &out;
    block.audio_out_count = 1;
    const bool processed = component->process(instance, &block) == 1;
    const bool passed = processed && leftOut[0] == leftIn[0] && leftOut[1] == leftIn[1] &&
                        rightOut[0] == rightIn[0] && rightOut[1] == rightIn[1];
    component->deactivate(instance);
    component->destroy(instance);
    return passed ? 0 : 4;
}
