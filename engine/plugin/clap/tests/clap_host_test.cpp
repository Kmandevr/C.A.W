// A small CLAP test host: loads the exported .clap plug-ins and checks them against the same components run through C.A.W's registry.
#include <clap/clap.h>

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

namespace {

constexpr const char* kDrive = "org.caw.tests.clap.drive";
constexpr const char* kSynth = "org.caw.tests.clap.synth";
constexpr const char* kTransport = "org.caw.tests.clap.transport";
constexpr double kRate = 48000.0;
constexpr double kTwoPi = 6.283185307179586;

// ---- Loading a .clap

struct ClapLibrary {
    void* handle = nullptr;
    const clap_plugin_entry_t* entry = nullptr;
    const clap_plugin_factory_t* factory = nullptr;

    explicit ClapLibrary(const char* path) {
#if defined(_WIN32)
        HMODULE m = LoadLibraryA(path);
        handle = m;
        if (m) entry = reinterpret_cast<const clap_plugin_entry_t*>(GetProcAddress(m, "clap_entry"));
#else
        handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        if (handle) entry = static_cast<const clap_plugin_entry_t*>(dlsym(handle, "clap_entry"));
#endif
        if (entry && clap_version_is_compatible(entry->clap_version) && entry->init(path))
            factory = static_cast<const clap_plugin_factory_t*>(entry->get_factory(CLAP_PLUGIN_FACTORY_ID));
    }
    ~ClapLibrary() {
        if (factory) entry->deinit();
#if defined(_WIN32)
        if (handle) FreeLibrary(static_cast<HMODULE>(handle));
#else
        if (handle) dlclose(handle);
#endif
    }
};

const void* hostGetExtension(const clap_host_t*, const char*) { return nullptr; }
void hostRequest(const clap_host_t*) {}
const clap_host_t kHost = {CLAP_VERSION_INIT, nullptr, "caw-clap-test-host", "C.A.W", "", "1",
                           hostGetExtension, hostRequest, hostRequest, hostRequest};

// One plug-in instance with its extensions.
struct Plug {
    const clap_plugin_t* plugin = nullptr;
    const clap_plugin_params_t* params = nullptr;
    const clap_plugin_state_t* state = nullptr;
    const clap_plugin_audio_ports_t* audioPorts = nullptr;
    const clap_plugin_note_ports_t* notePorts = nullptr;
    const clap_plugin_latency_t* latency = nullptr;
    const clap_plugin_tail_t* tail = nullptr;
    bool active = false;

    Plug(const ClapLibrary& lib, const char* id) {
        if (!lib.factory) return;
        plugin = lib.factory->create_plugin(lib.factory, &kHost, id);
        if (!plugin) return;
        if (!plugin->init(plugin)) {
            plugin->destroy(plugin);
            plugin = nullptr;
            return;
        }
        params = static_cast<const clap_plugin_params_t*>(plugin->get_extension(plugin, CLAP_EXT_PARAMS));
        state = static_cast<const clap_plugin_state_t*>(plugin->get_extension(plugin, CLAP_EXT_STATE));
        audioPorts = static_cast<const clap_plugin_audio_ports_t*>(plugin->get_extension(plugin, CLAP_EXT_AUDIO_PORTS));
        notePorts = static_cast<const clap_plugin_note_ports_t*>(plugin->get_extension(plugin, CLAP_EXT_NOTE_PORTS));
        latency = static_cast<const clap_plugin_latency_t*>(plugin->get_extension(plugin, CLAP_EXT_LATENCY));
        tail = static_cast<const clap_plugin_tail_t*>(plugin->get_extension(plugin, CLAP_EXT_TAIL));
    }
    ~Plug() {
        if (!plugin) return;
        if (active) {
            plugin->stop_processing(plugin);
            plugin->deactivate(plugin);
        }
        plugin->destroy(plugin);
    }
    bool activate(uint32_t maxFrames) {
        active = plugin->activate(plugin, kRate, 1, maxFrames) && plugin->start_processing(plugin);
        return active;
    }
    clap_id paramId(uint32_t index) const {
        clap_param_info_t info{};
        return params->get_info(plugin, index, &info) ? info.id : CLAP_INVALID_ID;
    }
    double value(uint32_t index) const {
        double v = -999.0;
        params->get_value(plugin, paramId(index), &v);
        return v;
    }
};

// ---- Event lists

union AnyEvent {
    clap_event_header_t header;
    clap_event_note_t note;
    clap_event_note_expression_t expression;
    clap_event_param_value_t value;
    clap_event_param_mod_t mod;
    clap_event_midi_t midi;
    clap_event_midi2_t midi2;
};

struct InEvents {
    std::vector<AnyEvent> list;
    clap_input_events_t api{this, size, get};
    static uint32_t size(const clap_input_events_t* l) {
        return static_cast<uint32_t>(static_cast<const InEvents*>(l->ctx)->list.size());
    }
    static const clap_event_header_t* get(const clap_input_events_t* l, uint32_t i) {
        return &static_cast<const InEvents*>(l->ctx)->list[i].header;
    }
    void param(uint32_t time, clap_id id, double v, bool mod = false) {
        AnyEvent e{};
        if (mod) {
            e.mod.header = {sizeof(clap_event_param_mod_t), time, CLAP_CORE_EVENT_SPACE_ID, CLAP_EVENT_PARAM_MOD, 0};
            e.mod.param_id = id;
            e.mod.note_id = -1;
            e.mod.port_index = e.mod.channel = e.mod.key = -1;
            e.mod.amount = v;
        } else {
            e.value.header = {sizeof(clap_event_param_value_t), time, CLAP_CORE_EVENT_SPACE_ID, CLAP_EVENT_PARAM_VALUE, 0};
            e.value.param_id = id;
            e.value.note_id = -1;
            e.value.port_index = e.value.channel = e.value.key = -1;
            e.value.value = v;
        }
        list.push_back(e);
    }
    void note(uint32_t time, uint16_t type, int32_t id, int16_t channel, int16_t key, double velocity) {
        AnyEvent e{};
        e.note.header = {sizeof(clap_event_note_t), time, CLAP_CORE_EVENT_SPACE_ID, type, 0};
        e.note.note_id = id;
        e.note.port_index = 0;
        e.note.channel = channel;
        e.note.key = key;
        e.note.velocity = velocity;
        list.push_back(e);
    }
    void midi(uint32_t time, uint8_t a, uint8_t b, uint8_t c) {
        AnyEvent e{};
        e.midi.header = {sizeof(clap_event_midi_t), time, CLAP_CORE_EVENT_SPACE_ID, CLAP_EVENT_MIDI, 0};
        e.midi.data[0] = a;
        e.midi.data[1] = b;
        e.midi.data[2] = c;
        list.push_back(e);
    }
};

struct OutEvents {
    std::vector<AnyEvent> list;
    clap_output_events_t api{this, push};
    static bool push(const clap_output_events_t* l, const clap_event_header_t* h) {
        AnyEvent e{};
        std::memcpy(&e, h, std::min<size_t>(h->size, sizeof(AnyEvent)));
        static_cast<OutEvents*>(l->ctx)->list.push_back(e);
        return true;
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

clap_process_status run(Plug& p, Stereo* in, Stereo& out, uint32_t frames, InEvents& events, OutEvents& outEvents,
                        const clap_event_transport_t* transport = nullptr) {
    float* inPtrs[2] = {in ? in->l.data() : nullptr, in ? in->r.data() : nullptr};
    float* outPtrs[2] = {out.l.data(), out.r.data()};
    clap_audio_buffer_t inBuffer{inPtrs, nullptr, 2, 0, 0};
    clap_audio_buffer_t outBuffer{outPtrs, nullptr, 2, 0, 0};
    clap_process_t proc{};
    proc.steady_time = -1;
    proc.frames_count = frames;
    proc.transport = transport;
    proc.audio_inputs = in ? &inBuffer : nullptr;
    proc.audio_inputs_count = in ? 1 : 0;
    proc.audio_outputs = &outBuffer;
    proc.audio_outputs_count = 1;
    proc.in_events = &events.api;
    proc.out_events = &outEvents.api;
    return p.plugin->process(p.plugin, &proc);
}

uint32_t fnv(const char* s) {
    uint32_t h = 2166136261u;
    for (; *s; ++s) h = (h ^ static_cast<unsigned char>(*s)) * 16777619u;
    return h;
}

bool hasFeature(const clap_plugin_descriptor_t* d, const char* f) {
    for (const char* const* p = d->features; p && *p; ++p)
        if (!std::strcmp(*p, f)) return true;
    return false;
}

struct MemoryStream {
    std::vector<uint8_t> bytes;
    size_t at = 0;
    clap_ostream_t out{this, write};
    clap_istream_t in{this, read};
    static int64_t write(const clap_ostream_t* s, const void* buffer, uint64_t size) {
        auto* m = static_cast<MemoryStream*>(s->ctx);
        const auto* b = static_cast<const uint8_t*>(buffer);
        const uint64_t n = std::min<uint64_t>(size, 7);  // short writes, as real hosts may do
        m->bytes.insert(m->bytes.end(), b, b + n);
        return static_cast<int64_t>(n);
    }
    static int64_t read(const clap_istream_t* s, void* buffer, uint64_t size) {
        auto* m = static_cast<MemoryStream*>(s->ctx);
        const uint64_t n = std::min<uint64_t>({size, m->bytes.size() - m->at, 5});
        std::memcpy(buffer, m->bytes.data() + m->at, n);
        m->at += n;
        return static_cast<int64_t>(n);
    }
};

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
    double value;
};

}  // namespace

TEST(clap_minimal_example_is_listed_and_passes_audio_like_the_registry) {
    ClapLibrary lib(CAW_CLAP_MINIMAL);
    CHECK(lib.factory != nullptr);
    if (!lib.factory) return;
    CHECK_EQ(lib.factory->get_plugin_count(lib.factory), 1u);
    const clap_plugin_descriptor_t* d = lib.factory->get_plugin_descriptor(lib.factory, 0);
    CHECK(d && std::string(d->id) == "org.caw.examples.minimal");
    CHECK(d && std::string(d->vendor) == "C.A.W examples" && std::string(d->version) == "1.0.0");
    CHECK(d && hasFeature(d, CLAP_PLUGIN_FEATURE_AUDIO_EFFECT) && hasFeature(d, CLAP_PLUGIN_FEATURE_STEREO));
    CHECK(lib.factory->get_plugin_descriptor(lib.factory, 1) == nullptr);
    CHECK(lib.factory->create_plugin(lib.factory, &kHost, "org.caw.nothing") == nullptr);

    Plug p(lib, "org.caw.examples.minimal");
    CHECK(p.plugin != nullptr);
    if (!p.plugin) return;
    CHECK(p.audioPorts && p.audioPorts->count(p.plugin, true) == 1 && p.audioPorts->count(p.plugin, false) == 1);
    CHECK(p.notePorts == nullptr);
    CHECK(p.activate(256));
    Reference ref(CAW_CLAP_MINIMAL_COMPONENT, "org.caw.examples.minimal", 256);
    CHECK(ref.processor != nullptr);
    if (!ref.processor) return;
    uint32_t mismatches = 0;
    for (uint32_t block = 0; block < 3; ++block) {
        Stereo in = sine(256, block * 256), out(256), expected(256);
        InEvents events;
        OutEvents outEvents;
        CHECK_EQ(run(p, &in, out, 256, events, outEvents), CLAP_PROCESS_CONTINUE);
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

TEST(clap_bundle_lists_every_component_with_its_category) {
    ClapLibrary lib(CAW_CLAP_FIXTURE);
    CHECK(lib.factory != nullptr);
    if (!lib.factory) return;
    CHECK_EQ(lib.factory->get_plugin_count(lib.factory), 3u);
    const clap_plugin_descriptor_t* drive = lib.factory->get_plugin_descriptor(lib.factory, 0);
    const clap_plugin_descriptor_t* synth = lib.factory->get_plugin_descriptor(lib.factory, 1);
    const clap_plugin_descriptor_t* transport = lib.factory->get_plugin_descriptor(lib.factory, 2);
    CHECK(drive && std::string(drive->id) == kDrive && std::string(drive->name) == "Test drive");
    CHECK(drive && std::string(drive->version) == "3");  // no VERSION given: the component's own
    CHECK(drive && std::string(drive->url) == "https://example.invalid/caw-tests");
    CHECK(drive && hasFeature(drive, CLAP_PLUGIN_FEATURE_AUDIO_EFFECT) && !hasFeature(drive, CLAP_PLUGIN_FEATURE_INSTRUMENT));
    CHECK(synth && std::string(synth->id) == kSynth && hasFeature(synth, CLAP_PLUGIN_FEATURE_INSTRUMENT));
    CHECK(transport && std::string(transport->name) == kTransport);  // no name: the id
    CHECK(transport && hasFeature(transport, CLAP_PLUGIN_FEATURE_UTILITY));
    // The plug-in is still an ordinary C.A.W component library: the registry loads it too.
    ModuleRegistry registry;
    CHECK(registry.loadSharedLibrary(CAW_CLAP_FIXTURE, kDrive, NativeModuleTrust::Trusted).success);
}

TEST(clap_params_describe_the_component_parameters) {
    ClapLibrary lib(CAW_CLAP_FIXTURE);
    Plug p(lib, kDrive);
    CHECK(p.plugin && p.params);
    if (!p.plugin || !p.params) return;
    CHECK_EQ(p.params->count(p.plugin), 3u);
    clap_param_info_t info{};
    CHECK(p.params->get_info(p.plugin, 0, &info));
    CHECK_EQ(info.id, fnv("drive"));
    CHECK_EQ(std::string(info.name), std::string("Drive"));
    CHECK_EQ(info.min_value, 1.0);
    CHECK_EQ(info.max_value, 8.0);
    CHECK_EQ(info.default_value, 2.0);
    CHECK_EQ(info.flags, uint32_t(CLAP_PARAM_IS_AUTOMATABLE | CLAP_PARAM_IS_MODULATABLE));
    CHECK(p.params->get_info(p.plugin, 1, &info));
    CHECK_EQ(info.flags, uint32_t(CLAP_PARAM_IS_AUTOMATABLE | CLAP_PARAM_IS_STEPPED | CLAP_PARAM_IS_ENUM));
    CHECK(p.params->get_info(p.plugin, 2, &info));
    CHECK_EQ(std::string(info.name), std::string("mix"));  // no display name: the id
    CHECK(info.flags & CLAP_PARAM_IS_STEPPED);
    CHECK(!p.params->get_info(p.plugin, 3, &info));

    char textOut[64];
    CHECK(p.params->value_to_text(p.plugin, p.paramId(0), 2.0, textOut, sizeof(textOut)));
    CHECK_EQ(std::string(textOut), std::string("2.000 x"));
    CHECK(p.params->value_to_text(p.plugin, p.paramId(1), 1.0, textOut, sizeof(textOut)));
    CHECK_EQ(std::string(textOut), std::string("Hard"));
    CHECK(p.params->value_to_text(p.plugin, p.paramId(2), 0.254, textOut, sizeof(textOut)));
    CHECK_EQ(std::string(textOut), std::string("0.25"));
    double v = 0;
    CHECK(p.params->text_to_value(p.plugin, p.paramId(1), "Fold", &v));
    CHECK_EQ(v, 2.0);
    CHECK(p.params->text_to_value(p.plugin, p.paramId(0), "3.5 x", &v));
    CHECK_EQ(v, 3.5);
    CHECK(!p.params->text_to_value(p.plugin, p.paramId(0), "loud", &v));
    CHECK(!p.params->get_value(p.plugin, 12345, &v));

    CHECK_EQ(p.value(0), 2.0);
    CHECK_EQ(p.value(2), 1.0);
    // A flush while inactive sets the value at once (main thread).
    InEvents events;
    events.param(0, p.paramId(2), 0.3);
    OutEvents out;
    p.params->flush(p.plugin, &events.api, &out.api);
    CHECK_EQ(p.value(2), 0.3);

    CHECK(p.latency && p.latency->get(p.plugin) == 3u);
    CHECK(p.tail && p.tail->get(p.plugin) == 1000u);
}

TEST(clap_effect_matches_the_registry_with_sample_accurate_parameter_changes) {
    constexpr uint32_t kFrames = 512;
    ClapLibrary lib(CAW_CLAP_FIXTURE);
    Plug p(lib, kDrive);
    CHECK(p.plugin && p.activate(kFrames));
    Reference ref(CAW_CLAP_FIXTURE_COMPONENT, kDrive, kFrames);
    CHECK(ref.processor != nullptr);
    if (!p.active || !ref.processor) return;
    ParameterResolver resolvers[3];
    for (uint32_t k = 0; k < 3; ++k) CHECK(resolvers[k].configure(ref.descriptor->parameters[k]));

    const std::vector<std::vector<Change>> blocks = {
        {},
        {{100, 0, 5.0}, {300, 2, 0.5}},
        {{0, 1, 1.0}, {511, 0, 1.5}},
        {{7, 0, 9.0}, {256, 1, 2.0}},  // 9 is past the range: clamped to 8
    };
    uint32_t mismatches = 0;
    for (uint32_t block = 0; block < blocks.size(); ++block) {
        Stereo in = sine(kFrames, block * kFrames), out(kFrames), expected(kFrames);
        InEvents events;
        for (const Change& c : blocks[block]) events.param(c.frame, p.paramId(c.param), c.value);
        OutEvents outEvents;
        CHECK_EQ(run(p, &in, out, kFrames, events, outEvents), CLAP_PROCESS_CONTINUE);

        // The registry side: each parameter resolved frame by frame, changing at the same frames.
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
            for (const Change& c : blocks[block]) {
                if (c.param != k) continue;
                resolveTo(c.frame);
                resolvers[k].setBase(c.value);
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
    CHECK_EQ(p.value(0), 8.0);
    CHECK_EQ(p.value(1), 2.0);
    CHECK_EQ(p.value(2), 0.5);

    // Modulation adds to the plain value and is clamped: mix 0.5 - 1 reads 0, so the output is the
    // input 3 frames late (the declared latency).
    Stereo in = sine(kFrames, 99999), out(kFrames);
    InEvents events;
    events.param(0, p.paramId(2), -1.0, true);
    OutEvents outEvents;
    CHECK_EQ(run(p, &in, out, kFrames, events, outEvents), CLAP_PROCESS_CONTINUE);
    uint32_t dry = 0;
    for (uint32_t i = 3; i < kFrames; ++i) dry += out.l[i] == in.l[i - 3] && out.r[i] == in.r[i - 3];
    CHECK_EQ(dry, kFrames - 3);
    CHECK_EQ(p.value(2), 0.5);  // the host's value, without modulation
}

TEST(clap_state_round_trips_parameters_and_component_state) {
    ClapLibrary lib(CAW_CLAP_FIXTURE);
    MemoryStream saved;
    {
        Plug p(lib, kDrive);
        CHECK(p.plugin && p.state && p.activate(128));
        if (!p.active) return;
        InEvents events;
        events.param(5, p.paramId(0), 6.25);
        events.param(9, p.paramId(1), 1.0);
        OutEvents out;
        Stereo in = sine(128, 0), o(128);
        for (int k = 0; k < 4; ++k) {
            CHECK_EQ(run(p, &in, o, 128, events, out), CLAP_PROCESS_CONTINUE);
            events.list.clear();
        }
        CHECK(p.state->save(p.plugin, &saved.out));  // while active (save may run alongside process)
    }
    // The component's own state (4 blocks processed) is the last 8 bytes.
    CHECK(saved.bytes.size() > 8);
    uint64_t blocks = 0;
    std::memcpy(&blocks, saved.bytes.data() + saved.bytes.size() - 8, 8);
    CHECK_EQ(blocks, 4u);

    Plug q(lib, kDrive);
    CHECK(q.plugin && q.state);
    if (!q.plugin) return;
    CHECK(q.state->load(q.plugin, &saved.in));
    CHECK_EQ(q.value(0), 6.25);
    CHECK_EQ(q.value(1), 1.0);
    CHECK_EQ(q.value(2), 1.0);
    MemoryStream again;
    CHECK(q.state->save(q.plugin, &again.out));
    CHECK(again.bytes == saved.bytes);

    // Loading while active hands the values to the audio thread at the next block.
    CHECK(q.activate(128));
    MemoryStream reload;
    reload.bytes = saved.bytes;
    CHECK(q.state->load(q.plugin, &reload.in));
    CHECK_EQ(q.value(0), 6.25);

    // Another component's state, or a damaged one, is refused.
    MemoryStream damaged;
    damaged.bytes = saved.bytes;
    damaged.bytes[12] ^= 0x20;  // inside the component id
    CHECK(!q.state->load(q.plugin, &damaged.in));
    MemoryStream truncated;
    truncated.bytes.assign(saved.bytes.begin(), saved.bytes.end() - 3);
    CHECK(!q.state->load(q.plugin, &truncated.in));
    Plug synth(lib, kSynth);
    MemoryStream other;
    other.bytes = saved.bytes;
    CHECK(synth.plugin && !synth.state->load(synth.plugin, &other.in));
}

TEST(clap_notes_and_midi_reach_an_instrument_as_caw_events) {
    constexpr uint32_t kFrames = 128;
    ClapLibrary lib(CAW_CLAP_FIXTURE);
    Plug p(lib, kSynth);
    CHECK(p.plugin && p.notePorts);
    if (!p.plugin || !p.notePorts) return;
    CHECK_EQ(p.notePorts->count(p.plugin, true), 1u);
    CHECK_EQ(p.notePorts->count(p.plugin, false), 1u);
    clap_note_port_info_t port{};
    CHECK(p.notePorts->get(p.plugin, 0, true, &port));
    CHECK(port.supported_dialects & CLAP_NOTE_DIALECT_CLAP);
    CHECK(port.supported_dialects & CLAP_NOTE_DIALECT_MIDI);
    CHECK_EQ(p.audioPorts->count(p.plugin, true), 0u);
    CHECK(p.activate(kFrames));
    if (!p.active) return;

    InEvents events;
    events.note(10, CLAP_EVENT_NOTE_ON, 7, 0, 60, 0.5);
    events.midi(20, 0x90, 64, 100);
    AnyEvent pressure{};
    pressure.expression.header = {sizeof(clap_event_note_expression_t), 30, CLAP_CORE_EVENT_SPACE_ID,
                                  CLAP_EVENT_NOTE_EXPRESSION, 0};
    pressure.expression.expression_id = CLAP_NOTE_EXPRESSION_PRESSURE;
    pressure.expression.note_id = 7;
    pressure.expression.port_index = 0;
    pressure.expression.channel = -1;
    pressure.expression.key = -1;
    pressure.expression.value = 0.25;
    events.list.push_back(pressure);
    events.note(50, CLAP_EVENT_NOTE_OFF, 7, 0, 60, 0.0);
    events.midi(60, 0x80, 64, 0);
    events.midi(70, 0xB0, 7, 99);
    AnyEvent raw{};
    raw.midi2.header = {sizeof(clap_event_midi2_t), 80, CLAP_CORE_EVENT_SPACE_ID, CLAP_EVENT_MIDI2, 0};
    raw.midi2.data[0] = 0x40B00A00u;
    raw.midi2.data[1] = 0x12345678u;
    events.list.push_back(raw);
    Stereo out(kFrames);
    OutEvents outEvents;
    CHECK_EQ(run(p, nullptr, out, kFrames, events, outEvents), CLAP_PROCESS_CONTINUE);

    // What the component should have received: MIDI 2.0 UMP words, host note ids + 1, wrapper ids
    // (top bit set) for MIDI 1.0 notes.
    const uint32_t v100 = (100u * 65535u + 63u) / 127u;
    const Event expected[] = {
        {10, EventKind::Note, 0, 8, {0x40903C00u, 32768u << 16, 0, 0}},
        {20, EventKind::Note, 0, 0x80000001u, {0x40904000u, v100 << 16, 0, 0}},
        {30, EventKind::Note, 0, 8, {0x40A03C00u, 1073741824u, 0, 0}},
        {50, EventKind::Note, 0, 8, {0x40803C00u, 0, 0, 0}},
        {60, EventKind::Note, 0, 0x80000001u, {0x40804000u, 0, 0, 0}},
        {70, EventKind::Midi, 0, 0, {0x20B00763u, 0, 0, 0}},
        {80, EventKind::Midi, 0, 0, {0x40B00A00u, 0x12345678u, 0, 0}},
    };
    Reference ref(CAW_CLAP_FIXTURE_COMPONENT, kSynth, kFrames);
    CHECK(ref.processor != nullptr);
    if (!ref.processor) return;
    Stereo reference(kFrames);
    float* outs[2] = {reference.l.data(), reference.r.data()};
    ChannelBufferView audioOut{outs, 2, kFrames};
    EventInput eventIn{expected, 7};
    Event echo[16];
    EventOutput eventOut{echo, 16, 0};
    ProcessBlock b;
    b.frames = kFrames;
    b.sampleRate = kRate;
    b.audioOut = &audioOut;
    b.audioOutCount = 1;
    b.eventIn = &eventIn;
    b.eventInCount = 1;
    b.eventOut = &eventOut;
    b.eventOutCount = 1;
    CHECK(ref.processor->processPorts(b));
    uint32_t mismatches = 0;
    for (uint32_t i = 0; i < kFrames; ++i) mismatches += (out.l[i] != reference.l[i]) + (out.r[i] != reference.r[i]);
    CHECK_EQ(mismatches, 0u);
    CHECK_EQ(out.l[25], static_cast<float>(32768.0 / 65535.0 / 10.0 + double(v100) / 65535.0 / 10.0));
    CHECK_EQ(out.l[100], 0.0f);

    // The echo comes back as CLAP events: notes as notes (host ids restored), MIDI 1.0 as MIDI,
    // the rest as MIDI 2.
    CHECK_EQ(outEvents.list.size(), 7u);
    if (outEvents.list.size() != 7u) return;
    const auto& on = outEvents.list[0].note;
    CHECK(on.header.type == CLAP_EVENT_NOTE_ON && on.header.time == 10 && on.note_id == 7 && on.key == 60);
    CHECK_NEAR(on.velocity, 0.5, 1e-4);
    const auto& midiOn = outEvents.list[1].note;
    CHECK(midiOn.header.type == CLAP_EVENT_NOTE_ON && midiOn.note_id == -1 && midiOn.key == 64);
    CHECK(outEvents.list[2].header.type == CLAP_EVENT_MIDI2 && outEvents.list[2].midi2.data[0] == 0x40A03C00u);
    CHECK(outEvents.list[3].header.type == CLAP_EVENT_NOTE_OFF && outEvents.list[3].note.note_id == 7);
    CHECK(outEvents.list[4].header.type == CLAP_EVENT_NOTE_OFF && outEvents.list[4].note.note_id == -1);
    const auto& cc = outEvents.list[5].midi;
    CHECK(cc.header.type == CLAP_EVENT_MIDI && cc.data[0] == 0xB0 && cc.data[1] == 7 && cc.data[2] == 99);
    CHECK(outEvents.list[6].header.type == CLAP_EVENT_MIDI2 && outEvents.list[6].midi2.data[1] == 0x12345678u);

    // A wildcard note off ends every sounding note.
    InEvents more;
    more.note(0, CLAP_EVENT_NOTE_ON, 3, 1, 50, 1.0);
    more.note(1, CLAP_EVENT_NOTE_ON, -1, 2, 51, 1.0);
    more.note(64, CLAP_EVENT_NOTE_OFF, -1, -1, -1, 0.0);
    OutEvents moreOut;
    CHECK_EQ(run(p, nullptr, out, kFrames, more, moreOut), CLAP_PROCESS_CONTINUE);
    CHECK_EQ(out.l[10], 0.2f);
    CHECK_EQ(out.l[64], 0.0f);
    CHECK_EQ(moreOut.list.size(), 4u);
}

TEST(clap_transport_reaches_the_component_while_playing) {
    ClapLibrary lib(CAW_CLAP_FIXTURE);
    Plug p(lib, kTransport);
    // A host block longer than the wrapper's 4096-frame pieces: the second piece's position moves on.
    CHECK(p.plugin && p.activate(8192));
    if (!p.active) return;
    clap_event_transport_t t{};
    t.header = {sizeof(t), 0, CLAP_CORE_EVENT_SPACE_ID, CLAP_EVENT_TRANSPORT, 0};
    t.flags = CLAP_TRANSPORT_HAS_TEMPO | CLAP_TRANSPORT_HAS_BEATS_TIMELINE | CLAP_TRANSPORT_HAS_TIME_SIGNATURE |
              CLAP_TRANSPORT_IS_PLAYING;
    t.tempo = 150.0;
    t.song_pos_beats = 8 * CLAP_BEATTIME_FACTOR;
    t.tsig_num = 6;
    t.tsig_denom = 8;
    Stereo in(8192), out(8192);
    InEvents events;
    OutEvents outEvents;
    CHECK_EQ(run(p, &in, out, 8192, events, outEvents, &t), CLAP_PROCESS_CONTINUE);
    CHECK_EQ(out.l[0], 0.15f);
    CHECK_EQ(out.r[0], static_cast<float>(8.0 / 100.0 + 3.0 / 1000.0));  // 6/8 is 3 quarter notes a bar
    const double later = 8.0 + 4096.0 * 150.0 / 60.0 / kRate;
    CHECK_EQ(out.r[4096], static_cast<float>(later / 100.0 + 3.0 / 1000.0));
    t.flags &= ~uint32_t(CLAP_TRANSPORT_IS_PLAYING);
    CHECK_EQ(run(p, &in, out, 8192, events, outEvents, &t), CLAP_PROCESS_CONTINUE);
    CHECK_EQ(out.l[0], -1.0f);
    CHECK_EQ(run(p, &in, out, 64, events, outEvents, nullptr), CLAP_PROCESS_CONTINUE);
    CHECK_EQ(out.r[0], -1.0f);
}

TEST(clap_process_and_audio_thread_calls_never_allocate) {
    ClapLibrary lib(CAW_CLAP_FIXTURE);
    Plug drive(lib, kDrive), synth(lib, kSynth);
    CHECK(drive.plugin && synth.plugin && drive.activate(256) && synth.activate(256));
    if (!drive.active || !synth.active) return;
    InEvents driveEvents, notes, flush;
    driveEvents.param(3, drive.paramId(0), 4.0);
    driveEvents.param(60, drive.paramId(1), 2.0);
    driveEvents.param(61, drive.paramId(2), 0.2, true);
    flush.param(0, drive.paramId(2), 0.7);
    notes.note(0, CLAP_EVENT_NOTE_ON, -1, 0, 60, 0.9);
    notes.midi(5, 0x90, 62, 80);
    notes.midi(9, 0xE0, 0, 64);
    notes.note(200, CLAP_EVENT_NOTE_OFF, -1, -1, -1, 0.0);
    OutEvents out;
    out.list.reserve(64);
    Stereo in = sine(256, 0), o(256);
    cawtest::AllocationScope scope;
    for (int k = 0; k < 4; ++k) {
        run(drive, &in, o, 256, driveEvents, out);
        run(synth, nullptr, o, 256, notes, out);
    }
    drive.params->flush(drive.plugin, &flush.api, &out.api);
    drive.plugin->reset(drive.plugin);
    synth.plugin->reset(synth.plugin);
    CHECK_EQ(scope.count(), 0u);
}
