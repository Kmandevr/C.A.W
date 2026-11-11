// A small VST3 test host: loads the exported .vst3 plug-ins and checks them against the same components run through C.A.W's registry.
#include <pluginterfaces/base/ibstream.h>
#include <pluginterfaces/base/ipluginbase.h>
#include <pluginterfaces/vst/ivstaudioprocessor.h>
#include <pluginterfaces/vst/ivstcomponent.h>
#include <pluginterfaces/vst/ivsteditcontroller.h>
#include <pluginterfaces/vst/ivstevents.h>
#include <pluginterfaces/vst/ivstparameterchanges.h>
#include <pluginterfaces/vst/ivstprocesscontext.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#if defined(_WIN32)
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#include "alloc_counter.h"
#include "module_registry.h"
#include "params.h"
#include "test.h"

using namespace caw;
using namespace Steinberg;

namespace {

constexpr const char* kDrive = "org.caw.tests.clap.drive";
constexpr const char* kSynth = "org.caw.tests.clap.synth";
constexpr const char* kTransport = "org.caw.tests.clap.transport";
constexpr double kRate = 48000.0;
constexpr double kTwoPi = 6.283185307179586;

// ---- Loading a .vst3 (the library inside the bundle, as a host finds it)

struct Vst3Library {
    void* handle = nullptr;
    IPluginFactory* factory = nullptr;
    bool (*exitFn)() = nullptr;

    explicit Vst3Library(const char* path) {
        using GetFactory = IPluginFactory* (PLUGIN_API*)();
#if defined(_WIN32)
        HMODULE m = LoadLibraryA(path);
        handle = m;
        if (!m) return;
        auto init = reinterpret_cast<bool (*)()>(GetProcAddress(m, "InitDll"));
        exitFn = reinterpret_cast<bool (*)()>(GetProcAddress(m, "ExitDll"));
        auto get = reinterpret_cast<GetFactory>(GetProcAddress(m, "GetPluginFactory"));
        if (init && init() && get) factory = get();
#else
        handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (!handle) return;
        auto entry = reinterpret_cast<bool (*)(void*)>(dlsym(handle, "ModuleEntry"));
        exitFn = reinterpret_cast<bool (*)()>(dlsym(handle, "ModuleExit"));
        auto get = reinterpret_cast<GetFactory>(dlsym(handle, "GetPluginFactory"));
        if (entry && entry(handle) && get) factory = get();
#endif
    }
    ~Vst3Library() {
        if (factory) factory->release();
        if (exitFn) exitFn();
#if defined(_WIN32)
        if (handle) FreeLibrary(static_cast<HMODULE>(handle));
#else
        if (handle) dlclose(handle);
#endif
    }
    int32 find(const char* name) const {
        PClassInfo info{};
        for (int32 i = 0; factory && i < factory->countClasses(); ++i)
            if (factory->getClassInfo(i, &info) == kResultOk && std::string(info.name) == name) return i;
        return -1;
    }
};

// One plug-in instance: the component, with its processor and controller.
struct Plug {
    Vst::IComponent* component = nullptr;
    Vst::IAudioProcessor* processor = nullptr;
    Vst::IEditController* controller = nullptr;
    bool active = false;

    Plug(const Vst3Library& lib, const char* name) {
        const int32 index = lib.find(name);
        if (index < 0) return;
        PClassInfo info{};
        lib.factory->getClassInfo(index, &info);
        void* obj = nullptr;
        if (lib.factory->createInstance(info.cid, Vst::IComponent::iid, &obj) != kResultOk) return;
        component = static_cast<Vst::IComponent*>(obj);
        if (component->initialize(nullptr) != kResultOk) {
            component->release();
            component = nullptr;
            return;
        }
        component->queryInterface(Vst::IAudioProcessor::iid, &obj);
        processor = static_cast<Vst::IAudioProcessor*>(obj);
        TUID controllerId{};
        if (component->getControllerClassId(controllerId) != kResultOk &&
            component->queryInterface(Vst::IEditController::iid, &obj) == kResultOk)
            controller = static_cast<Vst::IEditController*>(obj);  // a single-component plug-in
    }
    ~Plug() {
        if (!component) return;
        if (active) {
            processor->setProcessing(false);
            component->setActive(false);
        }
        if (controller) controller->release();
        if (processor) processor->release();
        component->terminate();
        component->release();
    }
    bool activate(int32 maxFrames) {
        Vst::ProcessSetup setup{Vst::kRealtime, Vst::kSample32, maxFrames, kRate};
        active = processor->setupProcessing(setup) == kResultOk && component->setActive(true) == kResultOk &&
                 processor->setProcessing(true) == kResultOk;
        return active;
    }
    Vst::ParamID paramId(int32 index) const {
        Vst::ParameterInfo info{};
        return controller->getParameterInfo(index, info) == kResultOk ? info.id : 0xFFFFFFFFu;
    }
    double plain(int32 index) const {
        const Vst::ParamID id = paramId(index);
        return controller->normalizedParamToPlain(id, controller->getParamNormalized(id));
    }
    double normalized(int32 index, double plainValue) const {
        return controller->plainParamToNormalized(paramId(index), plainValue);
    }
};

// ---- Host-side objects (reference counts are ignored: they live on the test's stack)

struct Queue final : Vst::IParamValueQueue {
    Vst::ParamID id = 0;
    std::vector<std::pair<int32, double>> points;
    tresult PLUGIN_API queryInterface(const TUID, void** obj) override { *obj = nullptr; return kNoInterface; }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    Vst::ParamID PLUGIN_API getParameterId() override { return id; }
    int32 PLUGIN_API getPointCount() override { return static_cast<int32>(points.size()); }
    tresult PLUGIN_API getPoint(int32 i, int32& offset, Vst::ParamValue& v) override {
        if (i < 0 || size_t(i) >= points.size()) return kInvalidArgument;
        offset = points[i].first;
        v = points[i].second;
        return kResultOk;
    }
    tresult PLUGIN_API addPoint(int32, Vst::ParamValue, int32&) override { return kResultFalse; }
};

struct Changes final : Vst::IParameterChanges {
    std::vector<std::unique_ptr<Queue>> queues;
    tresult PLUGIN_API queryInterface(const TUID, void** obj) override { *obj = nullptr; return kNoInterface; }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    int32 PLUGIN_API getParameterCount() override { return static_cast<int32>(queues.size()); }
    Vst::IParamValueQueue* PLUGIN_API getParameterData(int32 i) override {
        return i >= 0 && size_t(i) < queues.size() ? queues[i].get() : nullptr;
    }
    Vst::IParamValueQueue* PLUGIN_API addParameterData(const Vst::ParamID&, int32&) override { return nullptr; }
    void add(Vst::ParamID id, int32 offset, double normalized) {
        for (auto& q : queues)
            if (q->id == id) {
                q->points.push_back({offset, normalized});
                return;
            }
        auto q = std::make_unique<Queue>();
        q->id = id;
        q->points.push_back({offset, normalized});
        queues.push_back(std::move(q));
    }
};

struct Events final : Vst::IEventList {
    std::vector<Vst::Event> list;
    tresult PLUGIN_API queryInterface(const TUID, void** obj) override { *obj = nullptr; return kNoInterface; }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    int32 PLUGIN_API getEventCount() override { return static_cast<int32>(list.size()); }
    tresult PLUGIN_API getEvent(int32 i, Vst::Event& e) override {
        if (i < 0 || size_t(i) >= list.size()) return kInvalidArgument;
        e = list[i];
        return kResultOk;
    }
    tresult PLUGIN_API addEvent(Vst::Event& e) override {
        if (list.size() == list.capacity()) return kResultFalse;  // never grows inside process
        list.push_back(e);
        return kResultOk;
    }
    void on(int32 offset, int16 channel, int16 key, float velocity, int32 noteId) {
        Vst::Event e{};
        e.type = Vst::Event::kNoteOnEvent;
        e.sampleOffset = offset;
        e.noteOn.channel = channel;
        e.noteOn.pitch = key;
        e.noteOn.velocity = velocity;
        e.noteOn.noteId = noteId;
        list.push_back(e);
    }
    void off(int32 offset, int16 channel, int16 key, int32 noteId) {
        Vst::Event e{};
        e.type = Vst::Event::kNoteOffEvent;
        e.sampleOffset = offset;
        e.noteOff.channel = channel;
        e.noteOff.pitch = key;
        e.noteOff.noteId = noteId;
        list.push_back(e);
    }
};

struct MemoryStream final : IBStream {
    std::vector<uint8_t> bytes;
    size_t at = 0;
    tresult PLUGIN_API queryInterface(const TUID, void** obj) override { *obj = nullptr; return kNoInterface; }
    uint32 PLUGIN_API addRef() override { return 1; }
    uint32 PLUGIN_API release() override { return 1; }
    tresult PLUGIN_API read(void* buffer, int32 n, int32* read) override {
        const size_t k = std::min<size_t>({size_t(std::max(n, 0)), bytes.size() - at, 5});  // short reads
        std::memcpy(buffer, bytes.data() + at, k);
        at += k;
        if (read) *read = static_cast<int32>(k);
        return kResultOk;
    }
    tresult PLUGIN_API write(void* buffer, int32 n, int32* written) override {
        const size_t k = std::min<size_t>(size_t(std::max(n, 0)), 7);  // short writes, as real hosts may do
        const auto* b = static_cast<const uint8_t*>(buffer);
        bytes.insert(bytes.end(), b, b + k);
        if (written) *written = static_cast<int32>(k);
        return kResultOk;
    }
    tresult PLUGIN_API seek(int64 pos, int32 mode, int64* result) override {
        int64 base = mode == kIBSeekSet ? 0 : mode == kIBSeekCur ? int64(at) : int64(bytes.size());
        at = size_t(std::clamp<int64>(base + pos, 0, int64(bytes.size())));
        if (result) *result = int64(at);
        return kResultOk;
    }
    tresult PLUGIN_API tell(int64* pos) override {
        if (pos) *pos = int64(at);
        return kResultOk;
    }
};

// ---- Processing a block through the plug-in

struct Stereo {
    std::vector<float> l, r;
    explicit Stereo(uint32_t n) : l(n, 0.0f), r(n, 0.0f) {}
};

Stereo sine(uint32_t frames, uint32_t offset) {
    Stereo s(frames);
    for (uint32_t i = 0; i < frames; ++i) {
        const double t = double(offset + i) / kRate;
        s.l[i] = static_cast<float>(0.8 * std::sin(kTwoPi * 440.0 * t));
        s.r[i] = static_cast<float>(0.6 * std::cos(kTwoPi * 330.0 * t));
    }
    return s;
}

tresult run(Plug& p, Stereo* in, Stereo& out, int32 frames, Changes* changes = nullptr, Events* events = nullptr,
            Events* outEvents = nullptr, Vst::ProcessContext* context = nullptr) {
    float* inPtrs[2] = {in ? in->l.data() : nullptr, in ? in->r.data() : nullptr};
    float* outPtrs[2] = {out.l.data(), out.r.data()};
    Vst::AudioBusBuffers inBus, outBus;
    inBus.numChannels = 2;
    inBus.channelBuffers32 = inPtrs;
    outBus.numChannels = 2;
    outBus.channelBuffers32 = outPtrs;
    Vst::ProcessData data;
    data.processMode = Vst::kRealtime;
    data.symbolicSampleSize = Vst::kSample32;
    data.numSamples = frames;
    data.numInputs = in ? 1 : 0;
    data.numOutputs = 1;
    data.inputs = in ? &inBus : nullptr;
    data.outputs = &outBus;
    data.inputParameterChanges = changes;
    data.inputEvents = events;
    data.outputEvents = outEvents;
    data.processContext = context;
    return p.processor->process(data);
}

uint32_t fnv(const char* s) {
    uint32_t h = 2166136261u;
    for (; *s; ++s) h = (h ^ static_cast<unsigned char>(*s)) * 16777619u;
    return h & 0x7FFFFFFFu;
}

std::string utf8(const Vst::TChar* s) {
    std::string out;
    for (; *s; ++s) out += static_cast<char>(*s);  // ASCII in these tests
    return out;
}
void utf16(const char* s, Vst::String128 out) {
    size_t n = 0;
    for (; s[n] && n < 127; ++n) out[n] = static_cast<Vst::TChar>(s[n]);
    out[n] = 0;
}

// ---- The same component through C.A.W's registry

struct Reference {
    ModuleRegistry registry;
    std::unique_ptr<ModuleProcessor> processor;
    const ModuleDescriptor* descriptor = nullptr;
    Reference(const char* path, const char* id, uint32_t maxFrames) {
        const ModuleLoadResult r = registry.loadSharedLibrary(path, id, NativeModuleTrust::Trusted);
        if (!r.success) return;
        descriptor = registry.find(id);
        processor = registry.create(id);
        if (processor && !processor->activate(kRate, maxFrames)) processor.reset();
    }
};

struct Change {
    uint32_t frame, param;
    double value;  // plain
};

}  // namespace

TEST(vst3_minimal_example_is_listed_and_passes_audio_like_the_registry) {
    Vst3Library lib(CAW_VST3_MINIMAL);
    CHECK(lib.factory != nullptr);
    if (!lib.factory) return;
    PFactoryInfo fi{};
    CHECK(lib.factory->getFactoryInfo(&fi) == kResultOk && std::string(fi.vendor) == "C.A.W examples");
    CHECK_EQ(lib.factory->countClasses(), 1);
    void* f2 = nullptr;
    CHECK(lib.factory->queryInterface(IPluginFactory2::iid, &f2) == kResultOk);
    PClassInfo2 info{};
    CHECK(static_cast<IPluginFactory2*>(f2)->getClassInfo2(0, &info) == kResultOk);
    CHECK_EQ(std::string(info.category), std::string(kVstAudioEffectClass));
    CHECK_EQ(std::string(info.version), std::string("1.0.0"));
    CHECK_EQ(std::string(info.subCategories), std::string("Fx|Stereo"));
    CHECK_EQ(std::string(info.sdkVersion), std::string(kVstVersionString));
    TUID unknown{};
    void* obj = nullptr;
    CHECK(lib.factory->createInstance(unknown, Vst::IComponent::iid, &obj) != kResultOk && obj == nullptr);

    CHECK_EQ(std::string(info.name), std::string("org.caw.examples.minimal"));  // no display name: the id
    Plug p(lib, "org.caw.examples.minimal");
    CHECK(p.component && p.processor && p.controller);
    if (!p.component) return;
    CHECK_EQ(p.component->getBusCount(Vst::kAudio, Vst::kInput), 1);
    CHECK_EQ(p.component->getBusCount(Vst::kAudio, Vst::kOutput), 1);
    CHECK_EQ(p.component->getBusCount(Vst::kEvent, Vst::kInput), 0);
    Vst::SpeakerArrangement stereo = Vst::SpeakerArr::kStereo, mono = Vst::SpeakerArr::kMono;
    CHECK(p.processor->setBusArrangements(&stereo, 1, &stereo, 1) == kResultTrue);
    CHECK(p.processor->setBusArrangements(&mono, 1, &stereo, 1) == kResultFalse);
    CHECK(p.processor->canProcessSampleSize(Vst::kSample32) == kResultTrue);
    CHECK(p.processor->canProcessSampleSize(Vst::kSample64) == kResultFalse);
    CHECK(p.activate(256));
    Reference ref(CAW_VST3_MINIMAL_COMPONENT, "org.caw.examples.minimal", 256);
    CHECK(ref.processor != nullptr);
    if (!p.active || !ref.processor) return;
    uint32_t mismatches = 0;
    for (uint32_t block = 0; block < 3; ++block) {
        Stereo in = sine(256, block * 256), out(256), expected(256);
        CHECK(run(p, &in, out, 256) == kResultOk);
        const float* ins[2] = {in.l.data(), in.r.data()};
        float* outs[2] = {expected.l.data(), expected.r.data()};
        AudioProcessBlock b;
        b.input = {ins, 2, 256};
        b.output = {outs, 2, 256};
        b.frames = 256;
        b.sampleRate = kRate;
        CHECK(ref.processor->process(b));
        for (uint32_t i = 0; i < 256; ++i)
            mismatches += (out.l[i] != expected.l[i]) + (out.r[i] != expected.r[i]) + (out.l[i] != in.l[i]);
    }
    CHECK_EQ(mismatches, 0u);
}

TEST(vst3_bundle_lists_every_component_with_its_category) {
    Vst3Library lib(CAW_VST3_FIXTURE);
    CHECK(lib.factory != nullptr);
    if (!lib.factory) return;
    CHECK_EQ(lib.factory->countClasses(), 3);
    void* obj = nullptr;
    CHECK(lib.factory->queryInterface(IPluginFactory2::iid, &obj) == kResultOk);
    auto* f2 = static_cast<IPluginFactory2*>(obj);
    PClassInfo2 drive{}, synth{}, transport{};
    CHECK(f2->getClassInfo2(0, &drive) == kResultOk && f2->getClassInfo2(1, &synth) == kResultOk &&
          f2->getClassInfo2(2, &transport) == kResultOk);
    CHECK_EQ(std::string(drive.name), std::string("Test drive"));
    CHECK_EQ(std::string(drive.version), std::string("3"));  // no VERSION given: the component's own
    CHECK_EQ(std::string(drive.vendor), std::string("C.A.W tests"));
    CHECK_EQ(std::string(drive.subCategories), std::string("Fx|Stereo"));
    CHECK_EQ(std::string(synth.subCategories), std::string("Instrument|Synth|Stereo"));
    CHECK_EQ(std::string(transport.name), std::string(kTransport));  // no name: the id
    CHECK_EQ(std::string(transport.subCategories), std::string("Fx|Tools|Stereo"));
    // Class ids differ, and stay the same from one load to the next (they come from the component ids).
    CHECK(std::memcmp(drive.cid, synth.cid, sizeof(TUID)) != 0);
    Vst3Library again(CAW_VST3_FIXTURE);
    PClassInfo second{};
    CHECK(again.factory && again.factory->getClassInfo(0, &second) == kResultOk &&
          std::memcmp(second.cid, drive.cid, sizeof(TUID)) == 0);
    // The plug-in is still an ordinary C.A.W component library: the registry loads it too.
    ModuleRegistry registry;
    CHECK(registry.loadSharedLibrary(CAW_VST3_FIXTURE, kDrive, NativeModuleTrust::Trusted).success);
}

TEST(vst3_params_describe_the_component_parameters) {
    Vst3Library lib(CAW_VST3_FIXTURE);
    Plug p(lib, "Test drive");
    CHECK(p.component && p.controller);
    if (!p.controller) return;
    CHECK_EQ(p.controller->getParameterCount(), 3);
    Vst::ParameterInfo info{};
    CHECK(p.controller->getParameterInfo(0, info) == kResultOk);
    CHECK_EQ(info.id, fnv("drive"));
    CHECK_EQ(utf8(info.title), std::string("Drive"));
    CHECK_EQ(utf8(info.units), std::string("x"));
    CHECK_EQ(info.stepCount, 0);
    CHECK(std::fabs(info.defaultNormalizedValue - 1.0 / 7.0) < 1e-12);
    CHECK_EQ(info.flags, int32(Vst::ParameterInfo::kCanAutomate));
    CHECK(p.controller->getParameterInfo(1, info) == kResultOk);
    CHECK_EQ(info.stepCount, 2);
    CHECK_EQ(info.flags, int32(Vst::ParameterInfo::kCanAutomate | Vst::ParameterInfo::kIsList));
    CHECK(p.controller->getParameterInfo(2, info) == kResultOk);
    CHECK_EQ(utf8(info.title), std::string("mix"));  // no display name: the id
    CHECK_EQ(info.stepCount, 100);
    CHECK(p.controller->getParameterInfo(3, info) != kResultOk);

    // Plain and normalized: linear, and steps counted as the VST3 SDK does (n * (steps + 1), floored).
    const Vst::ParamID drive = p.paramId(0), shape = p.paramId(1), mix = p.paramId(2);
    CHECK_EQ(p.controller->normalizedParamToPlain(drive, 0.0), 1.0);
    CHECK_EQ(p.controller->normalizedParamToPlain(drive, 1.0), 8.0);
    CHECK_EQ(p.controller->plainParamToNormalized(drive, 4.5), 0.5);
    CHECK_EQ(p.controller->normalizedParamToPlain(shape, 0.3), 0.0);
    CHECK_EQ(p.controller->normalizedParamToPlain(shape, 0.5), 1.0);
    CHECK_EQ(p.controller->normalizedParamToPlain(shape, 1.0), 2.0);
    CHECK_EQ(p.controller->plainParamToNormalized(shape, 2.0), 1.0);
    CHECK_EQ(p.controller->plainParamToNormalized(shape, 1.0), 0.5);
    for (int k = 0; k <= 2; ++k)  // each step survives a round trip
        CHECK_EQ(p.controller->normalizedParamToPlain(shape, p.controller->plainParamToNormalized(shape, k)), double(k));

    Vst::String128 s{};
    CHECK(p.controller->getParamStringByValue(drive, p.normalized(0, 2.0), s) == kResultOk);
    CHECK_EQ(utf8(s), std::string("2.000 x"));
    CHECK(p.controller->getParamStringByValue(shape, 0.5, s) == kResultOk);
    CHECK_EQ(utf8(s), std::string("Hard"));
    CHECK(p.controller->getParamStringByValue(mix, 0.25, s) == kResultOk);
    CHECK_EQ(utf8(s), std::string("0.25"));
    Vst::ParamValue v = -1.0;
    utf16("Fold", s);
    CHECK(p.controller->getParamValueByString(shape, s, v) == kResultOk);
    CHECK_EQ(v, 1.0);
    utf16("4.5 x", s);
    CHECK(p.controller->getParamValueByString(drive, s, v) == kResultOk);
    CHECK_EQ(v, 0.5);
    utf16("loud", s);
    CHECK(p.controller->getParamValueByString(drive, s, v) != kResultOk);

    CHECK_EQ(p.plain(0), 2.0);
    CHECK_EQ(p.plain(2), 1.0);
    CHECK(p.controller->setParamNormalized(mix, 0.3) == kResultOk);
    CHECK(std::fabs(p.plain(2) - 0.3) < 1e-12);
    CHECK(p.controller->createView("editor") == nullptr);
    CHECK_EQ(p.processor->getLatencySamples(), 3u);
    CHECK_EQ(p.processor->getTailSamples(), 1000u);
}

TEST(vst3_effect_matches_the_registry_with_sample_accurate_parameter_changes) {
    constexpr uint32_t kFrames = 512;
    Vst3Library lib(CAW_VST3_FIXTURE);
    Plug p(lib, "Test drive");
    CHECK(p.component && p.activate(kFrames));
    Reference ref(CAW_VST3_FIXTURE_COMPONENT, kDrive, kFrames);
    CHECK(ref.processor != nullptr);
    if (!p.active || !ref.processor) return;
    ParameterResolver resolvers[3];
    for (uint32_t k = 0; k < 3; ++k) CHECK(resolvers[k].configure(ref.descriptor->parameters[k]));

    // Plain values that normalized values reach exactly (drive: 1 + 7n; shape: steps; mix: 0.01 steps).
    const std::vector<std::vector<Change>> blocks = {
        {},
        {{100, 0, 4.5}, {300, 2, 0.5}},
        {{0, 1, 1.0}, {511, 0, 1.0}},
        {{7, 0, 8.0}, {256, 1, 2.0}, {300, 0, 2.75}},
    };
    uint32_t mismatches = 0;
    for (uint32_t block = 0; block < blocks.size(); ++block) {
        Stereo in = sine(kFrames, block * kFrames), out(kFrames), expected(kFrames);
        Changes changes;
        std::vector<double> plain;  // what the plug-in will take, as the registry side's values
        for (const Change& c : blocks[block]) {
            const double n = p.normalized(int32(c.param), c.value);
            changes.add(p.paramId(int32(c.param)), int32(c.frame), n);
            plain.push_back(p.controller->normalizedParamToPlain(p.paramId(int32(c.param)), n));
        }
        CHECK(run(p, &in, out, kFrames, &changes) == kResultOk);

        std::vector<double> frames[3];
        ParameterValue values[3];
        for (uint32_t k = 0; k < 3; ++k) {
            frames[k].assign(kFrames, 0.0);
            uint32_t at = 0;
            auto resolveTo = [&](uint32_t end) {
                if (end <= at) return;
                const ParameterValue v = resolvers[k].resolve(end - at, nullptr, nullptr, frames[k].data() + at);
                if (!v.samples) std::fill(frames[k].begin() + at, frames[k].begin() + end, v.value);
                at = end;
            };
            for (size_t i = 0; i < blocks[block].size(); ++i) {
                const Change& c = blocks[block][i];
                if (c.param != k) continue;
                resolveTo(c.frame);
                resolvers[k].setBase(plain[i]);
            }
            resolveTo(kFrames);
            values[k] = {frames[k].data(), frames[k][0]};
        }
        const float* ins[2] = {in.l.data(), in.r.data()};
        float* outs[2] = {expected.l.data(), expected.r.data()};
        AudioProcessBlock b;
        b.input = {ins, 2, kFrames};
        b.output = {outs, 2, kFrames};
        b.frames = kFrames;
        b.sampleRate = kRate;
        b.parameters = values;
        b.parameterCount = 3;
        CHECK(ref.processor->process(b));
        for (uint32_t i = 0; i < kFrames; ++i) mismatches += (out.l[i] != expected.l[i]) + (out.r[i] != expected.r[i]);
    }
    CHECK_EQ(mismatches, 0u);

    // A block of 0 frames carries changes only (a flush): mix 0 makes the output the input 3 frames late.
    Changes flush;
    flush.add(p.paramId(2), 0, 0.0);
    Stereo none(1);
    CHECK(run(p, nullptr, none, 0, &flush) == kResultOk);
    Stereo in = sine(kFrames, 99999), out(kFrames);
    CHECK(run(p, &in, out, kFrames) == kResultOk);
    uint32_t dry = 0;
    for (uint32_t i = 3; i < kFrames; ++i) dry += out.l[i] == in.l[i - 3] && out.r[i] == in.r[i - 3];
    CHECK_EQ(dry, kFrames - 3);
}

TEST(vst3_state_round_trips_parameters_and_component_state) {
    Vst3Library lib(CAW_VST3_FIXTURE);
    MemoryStream saved;
    {
        Plug p(lib, "Test drive");
        CHECK(p.component && p.activate(128));
        if (!p.active) return;
        Stereo in = sine(128, 0), o(128);
        for (int k = 0; k < 4; ++k) {
            Changes changes;
            if (k == 0) {
                changes.add(p.paramId(0), 5, p.normalized(0, 6.25));
                changes.add(p.paramId(1), 9, p.normalized(1, 1.0));
            }
            CHECK(run(p, &in, o, 128, &changes) == kResultOk);
        }
        CHECK(p.component->getState(&saved) == kResultOk);  // while active
    }
    CHECK(saved.bytes.size() > 8);
    uint64_t blocks = 0;
    std::memcpy(&blocks, saved.bytes.data() + saved.bytes.size() - 8, 8);
    CHECK_EQ(blocks, 4u);

    Plug q(lib, "Test drive");
    CHECK(q.component && q.controller);
    if (!q.controller) return;
    CHECK(q.component->setState(&saved) == kResultOk);
    CHECK_EQ(q.plain(0), 6.25);
    CHECK_EQ(q.plain(1), 1.0);
    CHECK_EQ(q.plain(2), 1.0);
    MemoryStream again;
    CHECK(q.component->getState(&again) == kResultOk);
    CHECK(again.bytes == saved.bytes);

    // The controller side takes the same bytes (setComponentState) and shows the values.
    Plug viewer(lib, "Test drive");
    MemoryStream forController;
    forController.bytes = saved.bytes;
    CHECK(viewer.controller && viewer.controller->setComponentState(&forController) == kResultOk);
    CHECK_EQ(viewer.plain(0), 6.25);

    // Loading while active hands the values to the audio thread at the next block.
    CHECK(q.activate(128));
    MemoryStream reload;
    reload.bytes = saved.bytes;
    CHECK(q.component->setState(&reload) == kResultOk);
    CHECK_EQ(q.plain(0), 6.25);

    MemoryStream damaged;
    damaged.bytes = saved.bytes;
    damaged.bytes[12] ^= 0x20;  // inside the component id
    CHECK(q.component->setState(&damaged) != kResultOk);
    MemoryStream truncated;
    truncated.bytes.assign(saved.bytes.begin(), saved.bytes.end() - 3);
    CHECK(q.component->setState(&truncated) != kResultOk);
    Plug synth(lib, "Test synth");
    MemoryStream other;
    other.bytes = saved.bytes;
    CHECK(synth.component && synth.component->setState(&other) != kResultOk);
}

TEST(vst3_notes_reach_an_instrument_and_come_back_out) {
    constexpr int32 kFrames = 128;
    Vst3Library lib(CAW_VST3_FIXTURE);
    Plug p(lib, "Test synth");
    CHECK(p.component);
    if (!p.component) return;
    CHECK_EQ(p.component->getBusCount(Vst::kEvent, Vst::kInput), 1);
    CHECK_EQ(p.component->getBusCount(Vst::kEvent, Vst::kOutput), 1);
    CHECK_EQ(p.component->getBusCount(Vst::kAudio, Vst::kInput), 0);
    Vst::BusInfo bus{};
    CHECK(p.component->getBusInfo(Vst::kEvent, Vst::kInput, 0, bus) == kResultOk);
    CHECK_EQ(utf8(bus.name), std::string("notes"));
    CHECK(p.activate(kFrames));
    if (!p.active) return;

    // The synth's left output is the sum of the sounding notes' velocities / 10, the right the sum of their keys / 1280.
    Events events, out;
    out.list.reserve(64);
    events.on(10, 0, 60, 0.5f, 7);
    events.on(20, 0, 64, 1.0f, -1);  // no host id: a wrapper id
    events.off(50, 0, 60, 7);
    events.off(60, 0, 64, -1);       // ends the note on its key
    Stereo o(kFrames);
    CHECK(run(p, nullptr, o, kFrames, nullptr, &events, &out) == kResultOk);
    CHECK_EQ(o.l[9], 0.0f);
    CHECK(std::fabs(o.l[10] - 0.5f / 10.0f) < 1e-4f);
    CHECK(std::fabs(o.r[10] - 60.0f / 1280.0f) < 1e-6f);
    CHECK(std::fabs(o.l[30] - 1.5f / 10.0f) < 1e-4f);
    CHECK(std::fabs(o.r[30] - 124.0f / 1280.0f) < 1e-6f);
    CHECK(std::fabs(o.l[55] - 0.1f) < 1e-4f);
    CHECK_EQ(o.l[60], 0.0f);
    CHECK_EQ(o.r[127], 0.0f);

    // The echo: the same notes, with the host's id restored (-1 where it had none).
    CHECK_EQ(out.list.size(), size_t(4));
    if (out.list.size() == 4) {
        CHECK(out.list[0].type == Vst::Event::kNoteOnEvent && out.list[0].sampleOffset == 10);
        CHECK_EQ(out.list[0].noteOn.noteId, 7);
        CHECK_EQ(out.list[0].noteOn.pitch, int16(60));
        CHECK(std::fabs(out.list[0].noteOn.velocity - 0.5f) < 1e-4f);
        CHECK_EQ(out.list[1].noteOn.noteId, -1);
        CHECK(out.list[2].type == Vst::Event::kNoteOffEvent && out.list[2].noteOff.noteId == 7);
        CHECK(out.list[3].type == Vst::Event::kNoteOffEvent && out.list[3].sampleOffset == 60);
    }

    // A repeated note without an id ends the one before.
    Events again;
    again.on(0, 0, 70, 1.0f, -1);
    again.on(5, 0, 70, 1.0f, -1);
    CHECK(run(p, nullptr, o, kFrames, nullptr, &again) == kResultOk);
    CHECK(std::fabs(o.l[10] - 0.1f) < 1e-4f);  // one voice, not two
    Events end;
    end.off(0, 0, 70, -1);
    CHECK(run(p, nullptr, o, kFrames, nullptr, &end) == kResultOk);
    CHECK_EQ(o.l[1], 0.0f);
}

TEST(vst3_transport_reaches_the_component_while_playing) {
    Vst3Library lib(CAW_VST3_FIXTURE);
    Plug p(lib, kTransport);
    CHECK(p.component && p.activate(8192));
    if (!p.active) return;
    Vst::ProcessContext t{};
    t.state = Vst::ProcessContext::kPlaying | Vst::ProcessContext::kTempoValid |
              Vst::ProcessContext::kProjectTimeMusicValid | Vst::ProcessContext::kTimeSigValid;
    t.sampleRate = kRate;
    t.tempo = 150.0;
    t.projectTimeMusic = 8.0;
    t.timeSigNumerator = 6;
    t.timeSigDenominator = 8;
    Stereo in(8192), out(8192);
    CHECK(run(p, &in, out, 8192, nullptr, nullptr, nullptr, &t) == kResultOk);
    CHECK_EQ(out.l[0], 0.15f);
    CHECK_EQ(out.r[0], static_cast<float>(8.0 / 100.0 + 3.0 / 1000.0));  // 6/8 is 3 quarter notes a bar
    const double later = 8.0 + 4096.0 * 150.0 / 60.0 / kRate;  // the second 4096-frame piece moves on
    CHECK_EQ(out.r[4096], static_cast<float>(later / 100.0 + 3.0 / 1000.0));
    t.state &= ~uint32(Vst::ProcessContext::kPlaying);
    CHECK(run(p, &in, out, 8192, nullptr, nullptr, nullptr, &t) == kResultOk);
    CHECK_EQ(out.l[0], -1.0f);
    CHECK(run(p, &in, out, 64) == kResultOk);
    CHECK_EQ(out.r[0], -1.0f);
}

TEST(vst3_process_never_allocates) {
    Vst3Library lib(CAW_VST3_FIXTURE);
    Plug drive(lib, "Test drive"), synth(lib, "Test synth");
    CHECK(drive.component && synth.component && drive.activate(256) && synth.activate(256));
    if (!drive.active || !synth.active) return;
    Changes changes;
    changes.add(drive.paramId(0), 3, 0.4);
    changes.add(drive.paramId(1), 60, 1.0);
    changes.add(drive.paramId(0), 200, 0.9);
    Events notes, out;
    notes.on(0, 0, 60, 0.9f, -1);
    notes.on(5, 1, 62, 0.6f, 3);
    notes.off(200, 0, 60, -1);
    notes.off(210, 1, 62, 3);
    out.list.reserve(64);
    Stereo in = sine(256, 0), o(256);
    cawtest::AllocationScope scope;
    for (int k = 0; k < 4; ++k) {
        run(drive, &in, o, 256, &changes);
        out.list.clear();
        run(synth, nullptr, o, 256, nullptr, &notes, &out);
    }
    CHECK_EQ(scope.count(), 0u);
}
