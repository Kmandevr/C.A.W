// Factory presets of the fx-space effects (ensemble, doubler, vibrato, tremolo, auto-pan, rotary, Haas, imager, channel mixer, convolver, shimmer).
#include "builtin_fx_space.h"

namespace caw::fx {

namespace {

// Sync divisions (kSyncDivisions).
constexpr double kFree = 0, k16th = 3, k8thT = 5, k8th = 6, k8thD = 7, kQuarter = 9, kHalf = 12, kBar = 14;
// Shapes (kSpaceLfoShapes).
constexpr double kSine = 0, kTri = 1, kSquare = 4, kSampleHold = 5, kSmoothRandom = 6;

const std::vector<BuiltinPreset> kEnsemble = {
    {"Strings", "A string-machine ensemble: six voices on the vintage two-speed sweep", {{"voices", 4}, {"delay", 10}, {"detune", 14}, {"rate", 0.55}, {"spread", 1}, {"motion", 3}, {"tone", 9000}, {"mix", 0.6}}},
    {"Wide unison", "Eight voices spread hard, like a stack of detuned copies", {{"voices", 6}, {"delay", 14}, {"detune", 22}, {"rate", 0.35}, {"spread", 1}, {"motion", 2}, {"tone", 14000}, {"mix", 0.55}}},
    {"Subtle thicken", "Two voices, gently: more body, no obvious movement", {{"voices", 0}, {"delay", 9}, {"detune", 5}, {"rate", 0.4}, {"spread", 0.6}, {"motion", 0}, {"tone", 16000}, {"mix", 0.35}}},
    {"Seasick", "Slow and deep: four voices wobbling out of tune", {{"voices", 2}, {"delay", 20}, {"detune", 45}, {"rate", 0.25}, {"spread", 0.8}, {"motion", 1}, {"tone", 8000}, {"mix", 0.6}}},
    {"Shimmer pad", "Fast and bright on the random sweep: a glassy sparkle", {{"voices", 5}, {"delay", 6}, {"detune", 10}, {"rate", 2.5}, {"spread", 0.9}, {"motion", 2}, {"tone", 20000}, {"mix", 0.45}}},
};

const std::vector<BuiltinPreset> kDoubler = {
    {"Vocal double", "A second take beside the lead: two copies, a little late and a few cents off", {{"voices", 0}, {"delay", 18}, {"detune", 8}, {"drift", 0.4}, {"width", 0.9}, {"low_cut", 150}, {"high_cut", 9000}, {"mix", 0.5}}},
    {"Guitar wall", "Four doubles spread wide: a quad-tracked rhythm part", {{"voices", 1}, {"delay", 25}, {"detune", 12}, {"drift", 0.6}, {"width", 1}, {"low_cut", 120}, {"high_cut", 11000}, {"mix", 0.55}}},
    {"Tight", "Close and steady: wider without sounding doubled", {{"voices", 0}, {"delay", 8}, {"detune", 4}, {"drift", 0.15}, {"width", 0.8}, {"low_cut", 200}, {"high_cut", 14000}, {"mix", 0.45}}},
    {"Sloppy", "Late, loose and out of tune: a careless second take", {{"voices", 0}, {"delay", 45}, {"detune", 22}, {"drift", 1}, {"width", 0.9}, {"low_cut", 120}, {"high_cut", 7000}, {"mix", 0.5}}},
};

const std::vector<BuiltinPreset> kVibrato = {
    {"Singer", "A natural vocal vibrato: 5.5 Hz, a quarter tone", {{"rate", 5.5}, {"sync", kFree}, {"depth", 25}, {"shape", 0}, {"stereo", 0}, {"mix", 1}}},
    {"Tape wow", "Slow, random pitch drift, like a worn cassette", {{"rate", 0.8}, {"sync", kFree}, {"depth", 18}, {"shape", 2}, {"stereo", 0.3}, {"mix", 1}}},
    {"Warble", "Fast and deep: a broken toy's pitch", {{"rate", 9}, {"sync", kFree}, {"depth", 80}, {"shape", 1}, {"stereo", 0}, {"mix", 1}}},
    {"Synced chorus", "Eighth-note pitch swing, half wet, the sides apart", {{"sync", k8th}, {"depth", 30}, {"shape", 0}, {"stereo", 1}, {"mix", 0.5}}},
};

const std::vector<BuiltinPreset> kTremolo = {
    {"Amp tremolo", "A '60s amp's tremolo: a smooth sine, medium speed", {{"rate", 5}, {"sync", kFree}, {"depth", 0.6}, {"shape", kSine}, {"smooth", 0.2}, {"stereo", 0}, {"mode", 0}}},
    {"Harmonic", "The lows and highs pulse against each other", {{"rate", 4.5}, {"sync", kFree}, {"depth", 0.8}, {"shape", kSine}, {"smooth", 0.2}, {"stereo", 0}, {"mode", 1}}},
    {"Chopper", "Sixteenth-note square gate, rounded just enough not to click", {{"sync", k16th}, {"depth", 1}, {"shape", kSquare}, {"smooth", 0.15}, {"stereo", 0}, {"mode", 0}}},
    {"Stereo pulse", "Eighth-note triangles, left and right in turn", {{"sync", k8th}, {"depth", 0.8}, {"shape", kTri}, {"smooth", 0.1}, {"stereo", 1}, {"mode", 0}}},
    {"Random flutter", "Sample-and-hold steps on each sixteenth", {{"sync", k16th}, {"depth", 0.7}, {"shape", kSampleHold}, {"smooth", 0.3}, {"stereo", 0.5}, {"mode", 0}}},
};

const std::vector<BuiltinPreset> kAutopan = {
    {"Gentle sway", "A slow sine from side to side over two bars", {{"sync", 15}, {"depth", 0.6}, {"shape", kSine}, {"smooth", 0.1}, {"offset", 0}, {"width", 0.5}}},
    {"Ping-pong", "Hard left and right on each eighth", {{"sync", k8th}, {"depth", 1}, {"shape", kSquare}, {"smooth", 0.2}, {"offset", 0}, {"width", 0}}},
    {"Triplet swirl", "Eighth-note triplets, a triangle sweep", {{"sync", k8thT}, {"depth", 0.9}, {"shape", kTri}, {"smooth", 0.05}, {"offset", 0}, {"width", 0.3}}},
    {"Wander", "Drifts at random, never in time", {{"sync", kFree}, {"rate", 0.4}, {"depth", 0.8}, {"shape", kSmoothRandom}, {"smooth", 0.2}, {"offset", 0}, {"width", 0.5}}},
    {"Dotted bounce", "Dotted eighths, a saw sweep", {{"sync", k8thD}, {"depth", 0.8}, {"shape", 2}, {"smooth", 0.3}, {"offset", 0.25}, {"width", 0.4}}},
};

const std::vector<BuiltinPreset> kRotary = {
    {"Chorale", "The slow rotor: a gentle swirl for organ pads", {{"speed", 0}, {"accel", 1}, {"balance", 0}, {"drive", 0}, {"width", 0.7}, {"doppler", 0.6}, {"mix", 1}}},
    {"Tremolo", "The fast rotor: a full-speed, warbling spin", {{"speed", 1}, {"accel", 1}, {"balance", 0}, {"drive", 0}, {"width", 0.8}, {"doppler", 0.7}, {"mix", 1}}},
    {"Gritty organ", "Fast, with the amplifier driven hard", {{"speed", 1}, {"accel", 0.8}, {"balance", 0.1}, {"drive", 14}, {"width", 0.8}, {"doppler", 0.6}, {"mix", 1}}},
    {"Brake", "The rotors coast to a stop", {{"speed", 2}, {"accel", 1.5}, {"balance", 0}, {"drive", 0}, {"width", 0.7}, {"doppler", 0.6}, {"mix", 1}}},
    {"Guitar cab", "Horn-heavy and half wet, for guitars", {{"speed", 0}, {"accel", 2}, {"balance", -0.4}, {"drive", 4}, {"width", 1}, {"doppler", 0.5}, {"mix", 0.6}}},
};

const std::vector<BuiltinPreset> kHaas = {
    {"Wide", "12 ms on the right, the bass kept centred", {{"side", 1}, {"delay", 12}, {"guard", 150}, {"level", 0}, {"mono_check", 0}, {"mix", 1}}},
    {"Subtle", "A touch of width that survives in mono", {{"side", 1}, {"delay", 4}, {"guard", 250}, {"level", -1}, {"mono_check", 0}, {"mix", 1}}},
    {"Extra wide", "30 ms, the late side trimmed to keep it centred", {{"side", 0}, {"delay", 30}, {"guard", 200}, {"level", -3}, {"mono_check", 0}, {"mix", 1}}},
    {"Mono check", "Wide, summed to mono to hear what a phone speaker plays", {{"side", 1}, {"delay", 12}, {"guard", 150}, {"level", 0}, {"mono_check", 1}, {"mix", 1}}},
};

const std::vector<BuiltinPreset> kImager = {
    {"Master widen", "Mono lows, a wider top: the usual mastering move", {{"low_freq", 150}, {"high_freq", 5000}, {"low_width", 0}, {"mid_width", 1.1}, {"high_width", 1.4}, {"mid_gain", 0}, {"side_gain", 0}, {"output", 0}}},
    {"Mono bass", "Everything below 120 Hz in the middle, the rest untouched", {{"low_freq", 120}, {"high_freq", 4000}, {"low_width", 0}, {"mid_width", 1}, {"high_width", 1}, {"mid_gain", 0}, {"side_gain", 0}, {"output", 0}}},
    {"Narrow", "Pulled toward the middle at every frequency", {{"low_freq", 200}, {"high_freq", 4000}, {"low_width", 0.3}, {"mid_width", 0.5}, {"high_width", 0.6}, {"mid_gain", 0}, {"side_gain", 0}, {"output", 0}}},
    {"Air", "Wider highs and a little more side", {{"low_freq", 250}, {"high_freq", 7000}, {"low_width", 0.8}, {"mid_width", 1}, {"high_width", 1.8}, {"mid_gain", 0}, {"side_gain", 1.5}, {"output", 0}}},
    {"Sides only", "The middle removed: only what differs between left and right", {{"low_freq", 200}, {"high_freq", 4000}, {"low_width", 1}, {"mid_width", 1}, {"high_width", 1}, {"mid_gain", -24}, {"side_gain", 0}, {"output", 0}}},
};

const std::vector<BuiltinPreset> kMixer = {
    {"Swap", "Left and right trade places", {{"left_to_left", 0}, {"right_to_left", 1}, {"left_to_right", 1}, {"right_to_right", 0}}},
    {"Mono", "Both sides to both outputs, at half each", {{"left_to_left", 0.5}, {"right_to_left", 0.5}, {"left_to_right", 0.5}, {"right_to_right", 0.5}}},
    {"Left only", "The left input on both sides", {{"left_to_left", 1}, {"right_to_left", 0}, {"left_to_right", 1}, {"right_to_right", 0}}},
    {"Invert right", "The right side's polarity flipped", {{"left_to_left", 1}, {"right_to_left", 0}, {"left_to_right", 0}, {"right_to_right", -1}}},
    {"Side to mono", "Left minus right on both sides: only what differs", {{"left_to_left", 0.5}, {"right_to_left", -0.5}, {"left_to_right", 0.5}, {"right_to_right", -0.5}}},
};

const std::vector<BuiltinPreset> kConvolver = {
    {"Small room", "A tight, natural room", {{"source", 0}, {"decay", 0.6}, {"size", 0.35}, {"damping", 0.5}, {"length", 1}, {"reverse", 0}, {"predelay", 2}, {"low_cut", 100}, {"high_cut", 12000}, {"width", 1}, {"mix", 0.25}}},
    {"Concert hall", "A big, warm hall with a slow build", {{"source", 1}, {"decay", 3.2}, {"size", 0.7}, {"damping", 0.45}, {"length", 1}, {"reverse", 0}, {"predelay", 25}, {"low_cut", 80}, {"high_cut", 11000}, {"width", 1.1}, {"mix", 0.3}}},
    {"Vocal plate", "Bright and dense from the first moment", {{"source", 2}, {"decay", 2.0}, {"size", 0.5}, {"damping", 0.3}, {"length", 1}, {"reverse", 0}, {"predelay", 30}, {"low_cut", 180}, {"high_cut", 16000}, {"width", 1}, {"mix", 0.25}}},
    {"Surf spring", "A drippy spring tank", {{"source", 3}, {"decay", 2.5}, {"size", 0.5}, {"damping", 0.3}, {"length", 1}, {"reverse", 0}, {"predelay", 0}, {"low_cut", 150}, {"high_cut", 6000}, {"width", 0.7}, {"mix", 0.35}}},
    {"Stone cathedral", "Huge and dark", {{"source", 5}, {"decay", 8}, {"size", 0.9}, {"damping", 0.6}, {"length", 1}, {"reverse", 0}, {"predelay", 40}, {"low_cut", 60}, {"high_cut", 8000}, {"width", 1.2}, {"mix", 0.35}}},
    {"80s gated", "The gated drum room: a burst, then nothing", {{"source", 6}, {"decay", 1}, {"size", 0.6}, {"damping", 0.2}, {"length", 1}, {"reverse", 0}, {"predelay", 0}, {"low_cut", 120}, {"high_cut", 12000}, {"width", 1.2}, {"mix", 0.35}}},
    {"Reverse swell", "A hall played backwards: it rises into each note", {{"source", 1}, {"decay", 2}, {"size", 0.6}, {"damping", 0.4}, {"length", 1}, {"reverse", 1}, {"predelay", 0}, {"low_cut", 120}, {"high_cut", 12000}, {"width", 1.2}, {"mix", 0.4}}},
    {"Metal tank", "Ringing steel combs: weird and metallic", {{"source", 7}, {"decay", 1.8}, {"size", 0.5}, {"damping", 0.2}, {"length", 1}, {"reverse", 0}, {"predelay", 10}, {"low_cut", 200}, {"high_cut", 14000}, {"width", 1}, {"mix", 0.3}}},
};

const std::vector<BuiltinPreset> kShimmer = {
    {"Octave heaven", "The classic: every round an octave higher", {{"size", 0.8}, {"decay", 8}, {"predelay", 30}, {"damping", 0.35}, {"shift", 0}, {"amount", 0.6}, {"tone", 8000}, {"low_cut", 300}, {"mod", 0.5}, {"width", 1.2}, {"mix", 0.4}}},
    {"Fifths", "A fifth up each round: an open, choral wash", {{"size", 0.75}, {"decay", 6}, {"predelay", 20}, {"damping", 0.4}, {"shift", 1}, {"amount", 0.5}, {"tone", 7000}, {"low_cut", 300}, {"mod", 0.4}, {"width", 1.1}, {"mix", 0.4}}},
    {"Subtle sparkle", "A hall with a faint octave halo", {{"size", 0.65}, {"decay", 3.5}, {"predelay", 15}, {"damping", 0.45}, {"shift", 0}, {"amount", 0.25}, {"tone", 9000}, {"low_cut", 400}, {"mod", 0.3}, {"width", 1}, {"mix", 0.3}}},
    {"Infinite", "A long, rising cloud that barely fades", {{"size", 1}, {"decay", 25}, {"predelay", 40}, {"damping", 0.3}, {"shift", 0}, {"amount", 0.8}, {"tone", 6000}, {"low_cut", 250}, {"mod", 0.6}, {"width", 1.3}, {"mix", 0.5}}},
    {"Dark descent", "An octave down each round: a sinking drone", {{"size", 0.8}, {"decay", 7}, {"predelay", 20}, {"damping", 0.5}, {"shift", 5}, {"amount", 0.5}, {"tone", 5000}, {"low_cut", 80}, {"mod", 0.4}, {"width", 1}, {"mix", 0.4}}},
};

}  // namespace

const std::vector<BuiltinPreset>* fxSpacePresets(std::string_view id) {
    if (id == "org.caw.ensemble") return &kEnsemble;
    if (id == "org.caw.doubler") return &kDoubler;
    if (id == "org.caw.vibrato") return &kVibrato;
    if (id == "org.caw.tremolo") return &kTremolo;
    if (id == "org.caw.autopan") return &kAutopan;
    if (id == "org.caw.rotary") return &kRotary;
    if (id == "org.caw.haas") return &kHaas;
    if (id == "org.caw.imager") return &kImager;
    if (id == "org.caw.channelmixer") return &kMixer;
    if (id == "org.caw.convolver") return &kConvolver;
    if (id == "org.caw.shimmer") return &kShimmer;
    return nullptr;
}

}  // namespace caw::fx
