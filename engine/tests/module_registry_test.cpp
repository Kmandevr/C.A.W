#include "test.h"

#include "module_registry.h"

using namespace caw;

namespace {
const PortDescriptor ports[] = {
    {"in", PortType::Audio, ChannelLayout::Stereo, true},
    {"out", PortType::Audio, ChannelLayout::Stereo, false},
};
const ModuleDescriptor descriptor{"test.registry", 1, ports, 2, nullptr, 0};
class TestProcessor final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return ::caw::descriptor; }
    void process(const StereoProcessBlock& block) noexcept override {
        for (uint32_t i = 0; i < block.frames; ++i) {
            block.outputLeft[i] = block.inputLeft ? block.inputLeft[i] : 0.0f;
            block.outputRight[i] = block.inputRight ? block.inputRight[i] : 0.0f;
        }
    }
};
ModuleProcessor* makeTest() noexcept { return new TestProcessor(); }
}

TEST(module_registry_registers_and_creates_valid_processors) {
    ModuleRegistry registry;
    CHECK(registry.add(descriptor, &makeTest));
    CHECK_EQ(registry.size(), 1u);
    CHECK(registry.find("test.registry") == &descriptor);
    auto instance = registry.create("test.registry");
    CHECK(instance != nullptr);
    CHECK(instance->descriptor().id == descriptor.id);
}

TEST(module_registry_rejects_duplicate_and_unknown_modules) {
    ModuleRegistry registry;
    CHECK(registry.add(descriptor, &makeTest));
    CHECK(!registry.add(descriptor, &makeTest));
    CHECK(registry.create("missing") == nullptr);
}
