// Contract tests for first-class native modules and typed stereo ports.
#include "test.h"

#include "module.h"

using namespace caw;

TEST(module_descriptor_accepts_stereo_audio_and_typed_control) {
    const PortDescriptor ports[] = {
        {"in", PortType::Audio, ChannelLayout::Stereo, true},
        {"cutoff", PortType::Control, ChannelLayout::None, true},
        {"out", PortType::Audio, ChannelLayout::Stereo, false},
        {"mod", PortType::Modulation, ChannelLayout::None, true},
        {"events", PortType::Event, ChannelLayout::None, true},
    };
    const ParameterDescriptor params[] = {{"gain", 0.5, 0.0, 1.0, true}};
    const ModuleDescriptor d{"caw.test.stereo", 1, ports, 5, params, 1};
    CHECK(validateModuleDescriptor(d) == ModuleValidation::Ok);
}

TEST(module_descriptor_rejects_duplicate_port_ids) {
    const PortDescriptor ports[] = {
        {"signal", PortType::Audio, ChannelLayout::Mono, true},
        {"signal", PortType::Audio, ChannelLayout::Stereo, false},
    };
    const ModuleDescriptor d{"caw.test.duplicate", 1, ports, 2, nullptr, 0};
    CHECK(validateModuleDescriptor(d) == ModuleValidation::DuplicatePortId);
}

TEST(module_descriptor_rejects_audio_without_explicit_layout) {
    const PortDescriptor ports[] = {{"in", PortType::Audio, ChannelLayout::None, true}};
    const ModuleDescriptor d{"caw.test.layout", 1, ports, 1, nullptr, 0};
    CHECK(validateModuleDescriptor(d) == ModuleValidation::InvalidPortLayout);
}

TEST(module_descriptor_rejects_invalid_parameter_ranges) {
    const ParameterDescriptor params[] = {{"frequency", 100.0, 200.0, 20.0, true}};
    const ModuleDescriptor d{"caw.test.range", 1, nullptr, 0, params, 1};
    CHECK(validateModuleDescriptor(d) == ModuleValidation::InvalidParameterRange);
}

TEST(module_descriptor_rejects_default_outside_range) {
    const ParameterDescriptor params[] = {{"gain", 2.0, 0.0, 1.0, true}};
    const ModuleDescriptor d{"caw.test.default", 1, nullptr, 0, params, 1};
    CHECK(validateModuleDescriptor(d) == ModuleValidation::DefaultOutsideRange);
}

TEST(module_descriptor_accepts_generated_and_custom_ui_contracts) {
    const ParameterDescriptor params[] = {{"cutoff", 1200, 20, 20000, true}};
    const UiControlDescriptor controls[] = {
        {"cutoff-slider", "Cutoff", "cutoff", UiControlKind::Slider, 20, 20000},
        {"custom-action", "Randomize", "", UiControlKind::Button, 0, 1},
    };
    ModuleDescriptor d{"caw.test.ui", 1, nullptr, 0, params, 1, controls, 2, "caw.ui.synth"};
    CHECK(validateModuleDescriptor(d) == ModuleValidation::Ok);
}

TEST(module_descriptor_rejects_ui_controls_without_parameters) {
    const UiControlDescriptor controls[] = {
        {"unknown", "Unknown", "missing", UiControlKind::Slider, 0, 1},
    };
    ModuleDescriptor d{"caw.test.bad-ui", 1, nullptr, 0, nullptr, 0, controls, 1, ""};
    CHECK(validateModuleDescriptor(d) == ModuleValidation::UiControlMissingParameter);
}

TEST(module_descriptor_rejects_ui_ranges_outside_parameter_contract) {
    const ParameterDescriptor params[] = {{"gain", 0.5, 0, 1, true}};
    const UiControlDescriptor controls[] = {
        {"gain-slider", "Gain", "gain", UiControlKind::Slider, -1, 2},
    };
    ModuleDescriptor d{"caw.test.bad-range", 1, nullptr, 0, params, 1, controls, 1, ""};
    CHECK(validateModuleDescriptor(d) == ModuleValidation::InvalidUiControlRange);
}
