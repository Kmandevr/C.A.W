// The layout rules (#120): mono into stereo duplicated, stereo into mono refused without org.caw.downmix, dual mono.
#include <cmath>
#include <limits>
#include <memory>
#include <vector>

#include "builtin_components.h"
#include "graph.h"
#include "module_registry.h"
#include "test.h"

using namespace caw;

namespace {
constexpr GraphResourceBudget kBudget{std::numeric_limits<std::size_t>::max(), std::numeric_limits<std::size_t>::max(),
                                      64u * 1024u * 1024u};

float tone(uint32_t channel, uint32_t frame) noexcept {
    return static_cast<float>(std::sin(0.01 * frame * (channel + 1)) * 0.5 + 0.125 * channel);
}

// Writes tone(c, i) to each output channel.
class Source final : public ModuleProcessor {
public:
    explicit Source(const ModuleDescriptor& d) : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    bool process(const AudioProcessBlock& b) noexcept override {
        for (uint32_t c = 0; c < b.output.channelCount; ++c)
            for (uint32_t i = 0; i < b.frames; ++i) b.output.channels[c][i] = tone(c, i);
        return true;
    }
private:
    const ModuleDescriptor& d_;
};

// Copies input to output channel by channel.
class Copy final : public ModuleProcessor {
public:
    explicit Copy(const ModuleDescriptor& d) : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    bool process(const AudioProcessBlock& b) noexcept override {
        if (b.input.channelCount != b.output.channelCount) return false;
        for (uint32_t c = 0; c < b.output.channelCount; ++c)
            for (uint32_t i = 0; i < b.frames; ++i) b.output.channels[c][i] = b.input.channels[c][i];
        return true;
    }
private:
    const ModuleDescriptor& d_;
};

ModuleDescriptor module(const char* id, const PortDescriptor* ports, uint32_t count) {
    ModuleDescriptor d;
    d.id = id;
    d.ports = ports;
    d.portCount = count;
    return d;
}

const PortDescriptor kMonoOut[] = {audioPort("out", false, ChannelLayout::Mono)};
const PortDescriptor kStereoOut[] = {stereoOutput("out")};
const PortDescriptor kStereoFx[] = {stereoInput("in"), stereoOutput("out")};
const PortDescriptor kMonoFx[] = {audioPort("in", true, ChannelLayout::Mono), audioPort("out", false, ChannelLayout::Mono)};
const PortDescriptor kStereoBus[] = {{"in", PortType::Audio, ChannelLayout::Stereo, true, 0, true, 0.0f}, stereoOutput("out")};

struct Out {
    std::vector<float> l, r;
    float* ch[2];
    explicit Out(uint32_t frames) : l(frames, 9.0f), r(frames, 9.0f), ch{l.data(), r.data()} {}
    ChannelBufferView view(uint32_t frames) { return {ch, 2, frames}; }
};
}  // namespace

TEST(graph_mono_output_feeds_a_stereo_input_duplicated) {
    const ModuleDescriptor mono = module("test.mono", kMonoOut, 1), fx = module("test.fx", kStereoFx, 2);
    Source source(mono);
    Copy copy(fx);
    GraphExecutor executor;
    CHECK(executor.prepare({{"src", &mono}, {"fx", &fx}}, {{0, 0, 1, 0}}, {&source, &copy}, 1, 64, 48000.0, kBudget) ==
          GraphError::Ok);
    Out out(64);
    CHECK(executor.process(ConstChannelBufferView{}, out.view(64), 64));
    for (uint32_t i = 0; i < 64; ++i) CHECK(out.l[i] == tone(0, i) && out.r[i] == tone(0, i));  // L = R, unity
}

TEST(graph_mono_and_stereo_sum_into_a_stereo_bus) {
    const ModuleDescriptor mono = module("test.mono", kMonoOut, 1), stereo = module("test.stereo", kStereoOut, 1),
                           bus = module("test.bus", kStereoBus, 2);
    Source a(mono), b(stereo);
    Copy copy(bus);
    GraphExecutor executor;
    CHECK(executor.prepare({{"a", &mono}, {"b", &stereo}, {"bus", &bus}}, {{0, 0, 2, 0}, {1, 0, 2, 0}}, {&a, &b, &copy}, 2,
                           64, 48000.0, kBudget) == GraphError::Ok);
    Out out(64);
    CHECK(executor.process(ConstChannelBufferView{}, out.view(64), 64));
    for (uint32_t i = 0; i < 64; ++i) {
        CHECK_EQ(out.l[i], (0.0f + tone(0, i)) + tone(0, i));
        CHECK_EQ(out.r[i], (0.0f + tone(0, i)) + tone(1, i));
    }
    // Dynamic routing takes the same widening.
    GraphExecutor routed;
    CHECK(routed.prepareRouted({{"a", &mono}, {"b", &stereo}, {"bus", &bus}}, {&a, &b, &copy}, 2, 64, 48000.0, kBudget, 4) ==
          GraphError::Ok);
    const GraphConnection edges[] = {{0, 0, 2, 0}};
    const uint32_t order[] = {0, 1, 2};
    CHECK(routed.setRouting(edges, 1, order, 3));
    Out again(64);
    CHECK(routed.process(ConstChannelBufferView{}, again.view(64), 64));
    for (uint32_t i = 0; i < 64; ++i) CHECK(again.l[i] == tone(0, i) && again.r[i] == tone(0, i));
}

TEST(graph_refuses_stereo_into_mono_without_a_downmix) {
    const ModuleDescriptor stereo = module("test.stereo", kStereoOut, 1), mono = module("test.monofx", kMonoFx, 2);
    CHECK(compileGraph({{"s", &stereo}, {"m", &mono}}, {{0, 0, 1, 0}}, kBudget).error == GraphError::ChannelLayoutMismatch);
    // Mono into a 5.1 input, or 5.1 into stereo, stays a mismatch: only mono to stereo widens.
    const PortDescriptor wide[] = {audioPort("in", true, ChannelLayout::Surround51), audioPort("out", false, ChannelLayout::Surround51)};
    const ModuleDescriptor six = module("test.six", wide, 2), monoSrc = module("test.mono", kMonoOut, 1);
    CHECK(compileGraph({{"m", &monoSrc}, {"x", &six}}, {{0, 0, 1, 0}}, kBudget).error == GraphError::ChannelLayoutMismatch);

    // With org.caw.downmix between them: (L+R)/2, L or R.
    ModuleRegistry registry;
    registerBuiltinComponents(registry);
    std::unique_ptr<ModuleProcessor> downmix = registry.create("org.caw.downmix");
    CHECK(downmix != nullptr);
    if (!downmix) return;
    CHECK(downmix->activate(48000.0, 64));
    const ModuleDescriptor& dm = downmix->descriptor();
    Source source(stereo);
    Copy copy(mono);
    // The mono effect's output is the graph's: a mono output view.
    GraphExecutor executor;
    CHECK(executor.prepare({{"s", &stereo}, {"dm", &dm}, {"m", &mono}}, {{0, 0, 1, 0}, {1, 1, 2, 0}},
                           {&source, downmix.get(), &copy}, 2, 64, 48000.0, kBudget) == GraphError::Ok);
    for (uint32_t mode = 0; mode < 3; ++mode) {
        CHECK(executor.setInitialParameter(1, 0, static_cast<double>(mode)));
        std::vector<float> l(64);
        float* ch[1] = {l.data()};
        CHECK(executor.process(ConstChannelBufferView{}, ChannelBufferView{ch, 1, 64}, 64));
        for (uint32_t i = 0; i < 64; ++i) {
            const float want = mode == 1 ? tone(0, i) : mode == 2 ? tone(1, i) : 0.5f * (tone(0, i) + tone(1, i));
            CHECK_EQ(l[i], want);
        }
    }
}

namespace {
// A mono effect with state (a one-sample delay), so dual mono must give each channel its own instance.
const ModuleDescriptor& delayDescriptor() {
    static const ModuleDescriptor d = [] {
        ModuleDescriptor m = module("test.mono.delay", kMonoFx, 2);
        m.domains = kDomainWhole | kDomainPerChannel;
        return m;
    }();
    return d;
}
class MonoDelay final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return delayDescriptor(); }
    bool process(const AudioProcessBlock& b) noexcept override {
        if (b.input.channelCount != 1 || b.output.channelCount != 1) return false;
        for (uint32_t i = 0; i < b.frames; ++i) {
            const float x = b.input.channels[0][i];
            b.output.channels[0][i] = last_;
            last_ = x;
        }
        return true;
    }
    void reset() noexcept override { last_ = 0.0f; }
private:
    float last_ = 0.0f;
};
ModuleProcessor* makeDelay() noexcept { return new (std::nothrow) MonoDelay(); }
}  // namespace

TEST(graph_per_channel_mono_effect_runs_as_dual_mono) {
    ModuleRegistry registry;
    CHECK(registry.add(delayDescriptor(), &makeDelay));
    std::unique_ptr<ModuleProcessor> dual = registry.createDualMono("test.mono.delay");
    CHECK(dual != nullptr);
    if (!dual) return;
    const ModuleDescriptor& d = dual->descriptor();
    CHECK(validateModuleDescriptor(d) == ModuleValidation::Ok);
    CHECK(d.id == "test.mono.delay" && d.ports[0].layout == ChannelLayout::Stereo && d.ports[1].layout == ChannelLayout::Stereo);
    CHECK_EQ(d.domains, kDomainWhole);
    CHECK(dual->activate(48000.0, 64));
    const ModuleDescriptor stereo = module("test.stereo", kStereoOut, 1);
    Source source(stereo);
    GraphExecutor executor;
    CHECK(executor.prepare({{"s", &stereo}, {"d", &d}}, {{0, 0, 1, 0}}, {&source, dual.get()}, 1, 64, 48000.0, kBudget) ==
          GraphError::Ok);
    Out out(64);
    CHECK(executor.process(ConstChannelBufferView{}, out.view(64), 64));
    CHECK(out.l[0] == 0.0f && out.r[0] == 0.0f);
    for (uint32_t i = 1; i < 64; ++i) CHECK(out.l[i] == tone(0, i - 1) && out.r[i] == tone(1, i - 1));  // apart
    // A mono effect that does not declare PerChannel, or a stereo one, has no dual-mono form.
    static const ModuleDescriptor plain = module("test.mono.plain", kMonoFx, 2);
    CHECK(registry.add(plain, &makeDelay));
    CHECK(registry.createDualMono("test.mono.plain") == nullptr);
    ModuleRegistry builtins;
    registerBuiltinComponents(builtins);
    CHECK(builtins.createDualMono("org.caw.utility") == nullptr);
}
