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
const PortDescriptor mismatchedPorts[] = {
    {"in", PortType::Audio, ChannelLayout::Mono, true},
    {"out", PortType::Audio, ChannelLayout::Mono, false},
};
const ModuleDescriptor kMismatchedDescriptor{"test.registry", 1, mismatchedPorts, 2, nullptr, 0};
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
class MismatchedProcessor final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kMismatchedDescriptor; }
    void process(const StereoProcessBlock&) noexcept override {}
};
ModuleProcessor* makeMismatched() noexcept { return new MismatchedProcessor(); }
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

TEST(module_registry_rejects_factory_with_mismatched_port_contract) {
    ModuleRegistry registry;
    CHECK(registry.add(kDescriptor, &makeMismatched));
    CHECK(registry.create("test.registry") == nullptr);
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

TEST(descriptor_json_replaces_invalid_utf8_and_keeps_valid_text) {
    // One component's bad text must not make the whole listing unreadable (the app decodes UTF-8).
    ModuleDescriptor d{"org.caw.tests.text", 1};
    d.name = "Caf\xE9 \xC3\xA9";  // a Latin-1 byte, then a valid UTF-8 e-acute
    const std::string json = moduleDescriptorJson(d);
    CHECK(json.find("\"name\":\"Caf\xEF\xBF\xBD \xC3\xA9\"") != std::string::npos);
    ParameterDescriptor p;
    p.id = "gain";
    p.maximum = 0.1;  // written shortest-round-trip, not 0.10000000000000001
    d.parameters = &p;
    d.parameterCount = 1;
    CHECK(moduleDescriptorJson(d).find("\"max\":0.1,") != std::string::npos);
}
