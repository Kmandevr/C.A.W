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

TEST(module_descriptor_rejects_unknown_port_type_values) {
    const PortDescriptor ports[] = {
        {"out", static_cast<PortType>(0xFF), ChannelLayout::None, false},
    };
    const ModuleDescriptor d{"caw.test.invalid-type", 1, ports, 1, nullptr, 0};
    CHECK(validateModuleDescriptor(d) == ModuleValidation::InvalidPortType);
}

TEST(module_descriptor_rejects_unknown_channel_layout_values) {
    const PortDescriptor ports[] = {
        {"out", PortType::Audio, static_cast<ChannelLayout>(0xFF), false},
    };
    const ModuleDescriptor d{"caw.test.invalid-layout", 1, ports, 1, nullptr, 0};
    CHECK(validateModuleDescriptor(d) == ModuleValidation::InvalidPortLayout);
}

TEST(module_descriptor_matching_covers_parameters_and_ui_metadata) {
    const ParameterDescriptor parameters[] = {{"gain", 0.5, 0.0, 1.0, true}};
    const UiControlDescriptor controls[] = {
        {"gain-slider", "Gain", "gain", UiControlKind::Slider, 0.0, 1.0},
    };
    const ModuleDescriptor original{"caw.test.match", 1, nullptr, 0, parameters, 1,
                                    controls, 1, "caw.ui.gain"};
    const ParameterDescriptor changedParameters[] = {{"gain", 0.25, 0.0, 1.0, true}};
    const ModuleDescriptor changedParameter{"caw.test.match", 1, nullptr, 0,
                                            changedParameters, 1, controls, 1, "caw.ui.gain"};
    const UiControlDescriptor changedControls[] = {
        {"gain-slider", "Output gain", "gain", UiControlKind::Slider, 0.0, 1.0},
    };
    const ModuleDescriptor changedUi{"caw.test.match", 1, nullptr, 0, parameters, 1,
                                     changedControls, 1, "caw.ui.gain"};
    CHECK(moduleDescriptorsMatch(original, original));
    CHECK(!moduleDescriptorsMatch(original, changedParameter));
    CHECK(!moduleDescriptorsMatch(original, changedUi));
}

TEST(module_descriptor_rejects_unknown_ui_control_kinds) {
    const UiControlDescriptor controls[] = {
        {"unknown-kind", "Unknown", "", static_cast<UiControlKind>(0xFF), 0.0, 1.0},
    };
    const ModuleDescriptor d{"caw.test.invalid-ui-kind", 1, nullptr, 0, nullptr, 0,
                             controls, 1, ""};
    CHECK(validateModuleDescriptor(d) == ModuleValidation::InvalidUiControlKind);
}

TEST(channel_layouts_resolve_standard_and_discrete_counts) {
    CHECK_EQ(channelCountForLayout(ChannelLayout::Mono), 1u);
    CHECK_EQ(channelCountForLayout(ChannelLayout::Stereo), 2u);
    CHECK_EQ(channelCountForLayout(ChannelLayout::Quad), 4u);
    CHECK_EQ(channelCountForLayout(ChannelLayout::Surround51), 6u);
    CHECK_EQ(channelCountForLayout(ChannelLayout::Surround71), 8u);
    CHECK_EQ(channelCountForLayout(ChannelLayout::Discrete, 13), 13u);
    CHECK_EQ(channelCountForLayout(ChannelLayout::Discrete), 0u);
    CHECK_EQ(channelCountForLayout(ChannelLayout::None), 0u);
}
TEST(module_descriptor_accepts_discrete_audio_channel_count) {
    const PortDescriptor ports[] = {
        {"in", PortType::Audio, ChannelLayout::Discrete, true, 12},
        {"out", PortType::Audio, ChannelLayout::Discrete, false, 12},
    };
    const ModuleDescriptor d{"caw.test.discrete", 1, ports, 2, nullptr, 0};
    CHECK(validateModuleDescriptor(d) == ModuleValidation::Ok);
}
TEST(module_descriptor_rejects_discrete_audio_without_channel_count) {
    const PortDescriptor ports[] = {{"in", PortType::Audio, ChannelLayout::Discrete, true}};
    const ModuleDescriptor d{"caw.test.discrete.missing", 1, ports, 1, nullptr, 0};
    CHECK(validateModuleDescriptor(d) == ModuleValidation::InvalidPortLayout);
}
TEST(module_descriptor_rejects_channel_count_on_named_layout) {
    const PortDescriptor ports[] = {{"in", PortType::Audio, ChannelLayout::Stereo, true, 4}};
    const ModuleDescriptor d{"caw.test.named.count", 1, ports, 1, nullptr, 0};
    CHECK(validateModuleDescriptor(d) == ModuleValidation::InvalidPortLayout);
}
TEST(module_descriptor_matching_includes_discrete_channel_count) {
    const PortDescriptor aPorts[] = {{"in", PortType::Audio, ChannelLayout::Discrete, true, 4}};
    const PortDescriptor bPorts[] = {{"in", PortType::Audio, ChannelLayout::Discrete, true, 6}};
    const ModuleDescriptor a{"caw.test.match.discrete", 1, aPorts, 1, nullptr, 0};
    const ModuleDescriptor b{"caw.test.match.discrete", 1, bPorts, 1, nullptr, 0};
    CHECK(!moduleDescriptorsMatch(a, b));
}
TEST(channel_buffer_views_validate_planar_pointer_tables) {
    const float a[2] = {1.0f, 2.0f}, b[2] = {-1.0f, -2.0f};
    const float* inputs[] = {a, b};
    float outA[2] = {}, outB[2] = {};
    float* outputs[] = {outA, outB};
    CHECK((ConstChannelBufferView{inputs, 2, 2}.valid()));
    CHECK((ChannelBufferView{outputs, 2, 2}.valid()));
    CHECK((!ConstChannelBufferView{nullptr, 2, 2}.valid()));
    CHECK((!ChannelBufferView{nullptr, 1, 2}.valid()));
    const float* bad[] = {a, nullptr};
    CHECK((!ConstChannelBufferView{bad, 2, 2}.valid()));
}
TEST(generic_processor_contract_preserves_legacy_stereo_processors) {
    const PortDescriptor ports[] = {
        {"in", PortType::Audio, ChannelLayout::Stereo, true},
        {"out", PortType::Audio, ChannelLayout::Stereo, false},
    };
    const ModuleDescriptor descriptor{"caw.test.legacy.adapter", 1, ports, 2, nullptr, 0};
    class Legacy final : public ModuleProcessor {
    public:
        explicit Legacy(const ModuleDescriptor& d) : d_(d) {}
        const ModuleDescriptor& descriptor() const noexcept override { return d_; }
        void process(const StereoProcessBlock& block) noexcept override {
            for (uint32_t i = 0; i < block.frames; ++i) {
                block.outputLeft[i] = block.inputLeft[i] * 0.5f;
                block.outputRight[i] = block.inputRight[i] * 0.25f;
            }
        }
    private: const ModuleDescriptor& d_;
    } processor(descriptor);
    const float left[] = {2.0f, 4.0f}, right[] = {-4.0f, -8.0f};
    const float* inputs[] = {left, right};
    float outLeft[2] = {}, outRight[2] = {};
    float* outputs[] = {outLeft, outRight};
    const AudioProcessBlock block{{inputs, 2, 2}, {outputs, 2, 2}, 2, 48000.0};
    CHECK(processor.process(block));
    CHECK_NEAR(outLeft[0], 1.0, 1e-7);
    CHECK_NEAR(outRight[1], -2.0, 1e-7);
    const AudioProcessBlock unsupported{{inputs, 2, 2}, {outputs, 1, 2}, 2, 48000.0};
    CHECK(!processor.process(unsupported));
}
