// Tests for the static native module registry, factory validation and processor state contract.
#include "test.h"

#include "module_registry.h"

using namespace caw;

namespace {
const PortDescriptor ports[] = {
    {"in", PortType::Audio, ChannelLayout::Stereo, true},
    {"out", PortType::Audio, ChannelLayout::Stereo, false},
};
const ModuleDescriptor kDescriptor{"test.registry", 1, ports, 2, nullptr, 0};
class TestProcessor final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
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
    CHECK(registry.add(kDescriptor, &makeTest));
    CHECK_EQ(registry.size(), 1u);
    CHECK(registry.find("test.registry") == &kDescriptor);
    auto instance = registry.create("test.registry");
    CHECK(instance != nullptr);
    CHECK(instance->descriptor().id == kDescriptor.id);
}

TEST(module_registry_rejects_duplicate_and_unknown_modules) {
    ModuleRegistry registry;
    CHECK(registry.add(kDescriptor, &makeTest));
    CHECK(!registry.add(kDescriptor, &makeTest));
    CHECK(registry.create("missing") == nullptr);
}


TEST(module_processor_default_state_contract_is_versioned_and_stateless) {
    TestProcessor processor;
    uint32_t written = 99;
    CHECK_EQ(processor.stateVersion(), 1u);
    CHECK(processor.saveState(nullptr, 0, written));
    CHECK_EQ(written, 0u);
    CHECK(processor.loadState(nullptr, 0, 1));
    CHECK(!processor.loadState(nullptr, 1, 1));
    CHECK(!processor.loadState(nullptr, 0, 2));
}
