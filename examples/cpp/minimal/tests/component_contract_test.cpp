// Exercises the component entry points and the shared stereo processor contract.
#include <caw/component.hpp>

extern "C" const caw::ModuleDescriptor* caw_component_descriptor() noexcept;
extern "C" caw::ModuleProcessor* caw_component_create() noexcept;

int main() {
    const caw::ModuleDescriptor* descriptor = caw_component_descriptor();
    if (!descriptor || descriptor->id != "org.caw.examples.minimal" ||
        descriptor->apiVersion != 1 || descriptor->portCount != 2)
        return 1;

    caw::ModuleProcessor* processor = caw_component_create();
    if (!processor || processor->descriptor().id != descriptor->id)
        return 2;

    const float leftIn[] = {0.25f, -0.5f};
    const float rightIn[] = {-0.75f, 1.0f};
    float leftOut[] = {0.0f, 0.0f};
    float rightOut[] = {0.0f, 0.0f};
    const caw::StereoProcessBlock block{
        leftIn, rightIn, leftOut, rightOut, 2, 48000.0
    };
    processor->process(block);
    const bool passed = leftOut[0] == leftIn[0] && leftOut[1] == leftIn[1] &&
                        rightOut[0] == rightIn[0] && rightOut[1] == rightIn[1];
    delete processor;
    return passed ? 0 : 3;
}
