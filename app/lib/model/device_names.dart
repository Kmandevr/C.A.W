// Every built-in device's crow-family name, plain subtitle, search tags and purpose tags, by component id (one table; ids never change).
//
// The names are the sound plan's (owner, 2026-11-19): only what is shown changes, so projects, presets and code keep
// naming components by id. [DeviceNames.title] is what the app shows ("Talon · Compressor"); [DeviceNames.name] the
// short form used where a name is generated ("Talon 2"). Search ([DeviceNames.rank]) finds a device by its name, plain
// name, abbreviations, synonyms, modes, old names and purposes, an exact tag first.

/// What a device is for: the effect browser's purpose chips (device UI plan, "The effect browser").
enum DevicePurpose {
  guitar('Guitar'),
  vocals('Vocals'),
  drums('Drums'),
  bass('Bass'),
  mixing('Mixing'),
  mastering('Mastering'),
  soundDesign('Sound design'),
  lofi('Lo-fi');

  const DevicePurpose(this.label);
  final String label;
}

/// One device's names: [name] (the crow-family name), [plain] (what it is), [tags] (other words search finds it by:
/// abbreviations, synonyms, its modes and its old names) and [purposes].
class DeviceName {
  const DeviceName(this.name, this.plain, {this.tags = const [], this.purposes = const {}});
  final String name, plain;
  final List<String> tags;
  final Set<DevicePurpose> purposes;

  /// "Talon · Compressor"; just the name when the plain name says the same ("Macros").
  String get title => name.toLowerCase() == plain.toLowerCase() ? name : '$name · $plain';

  /// Every word search looks at, lower case: the name, the plain name, the tags and the purposes.
  Iterable<String> get words => [name, plain, ...tags, for (final p in purposes) p.label].map((w) => w.toLowerCase());
}

const _g = DevicePurpose.guitar, _v = DevicePurpose.vocals, _d = DevicePurpose.drums, _b = DevicePurpose.bass,
    _mix = DevicePurpose.mixing, _mas = DevicePurpose.mastering, _sd = DevicePurpose.soundDesign, _lo = DevicePurpose.lofi;

class DeviceNames {
  DeviceNames._();

  /// The table: every built-in the engine lists, by component id (retired ids are left out).
  static const Map<String, DeviceName> table = {
    // Dynamics
    'org.caw.compressor': DeviceName('Talon', 'Compressor', tags: ['comp', 'compression', 'glue', 'squash', 'sidechain',
      'down', 'downward', 'dynamics', 'upward', 'up', 'bus', 'bus compressor', 'expander', 'parallel', 'punch', 'leveller'],
      purposes: {_g, _v, _d, _b, _mix, _mas}),
    'org.caw.limiter': DeviceName('Canopy', 'Limiter', tags: ['limit', 'brickwall', 'maximizer', 'maximiser', 'loudness',
      'ceiling', 'true peak', 'clip', 'lufs'], purposes: {_mix, _mas}),
    'org.caw.gate': DeviceName('Hatch', 'Gate', tags: ['noise gate', 'gating', 'expand', 'expander', 'pedal gate',
      'noise suppressor', 'hum', 'bleed', 'tight'], purposes: {_g, _v, _d}),
    'org.caw.duck': DeviceName('Duck', 'Ducker', tags: ['ducking', 'sidechain', 'side chain', 'pump', 'pumping',
      'volume shaper', 'level', 'rider', 'vocal rider', 'leveller', 'carve', 'spectral ducking', 'auto level'],
      purposes: {_v, _b, _mix}),
    'org.caw.transient': DeviceName('Swoop', 'Transient', tags: ['transient shaper', 'shaper', 'attack', 'sustain',
      'punch', 'snap', 'envelope shaper'], purposes: {_d, _mix}),
    'org.caw.multiband': DeviceName('Pinion', 'Multiband dynamics', tags: ['multiband', 'multiband compressor', 'ott',
      'upward', 'downward', 'crispy', 'mb'], purposes: {_mix, _mas, _sd}),
    'org.caw.deesser': DeviceName('Quell', 'De-esser', tags: ['deesser', 'de-ess', 'deess', 'sibilance', 'esses',
      'harsh'], purposes: {_v}),
    // EQ and filters
    'org.caw.eq': DeviceName('Plume', 'EQ', tags: ['equalizer', 'equaliser', 'eq', 'tone', 'bands', 'parametric',
      'graphic', 'graphic eq', 'shelf', 'bell', 'tilt', 'dj', 'dj eq', 'kill', 'linear phase', 'match', 'match eq',
      'dynamic eq', 'low cut', 'high cut'], purposes: {_g, _v, _d, _b, _mix, _mas}),
    'org.caw.filter': DeviceName('Sweep', 'Filter', tags: ['low-pass', 'lowpass', 'high-pass', 'highpass', 'band-pass',
      'cutoff', 'resonance', 'multimode', 'ladder', 'moog', 'nonlinear', 'wah', 'auto-wah', 'autowah', 'svf'],
      purposes: {_g, _sd, _mix}),
    'org.caw.comb': DeviceName('Comb', 'Comb filter', tags: ['comb', 'metallic', 'flange'], purposes: {_sd}),
    'org.caw.resonator': DeviceName('Trill', 'Resonator', tags: ['resonance', 'tuned', 'string', 'bell', 'modal'],
      purposes: {_sd}),
    'org.caw.formant': DeviceName('Syrinx', 'Formant filter', tags: ['formant', 'vowel', 'talk box', 'talkbox', 'voice'],
      purposes: {_v, _sd}),
    'org.caw.disperser': DeviceName('Scatter', 'Disperser', tags: ['dispersion', 'all-pass', 'allpass', 'zap', 'laser',
      'phase'], purposes: {_sd, _d}),
    // Drive
    'org.caw.drive': DeviceName('Ember', 'Drive', tags: ['distortion', 'overdrive', 'saturation', 'saturator', 'saturate',
      'warmth', 'tape', 'tube', 'fuzz', 'clip', 'clipper', 'soft clip', 'fold', 'wavefolder', 'phase distortion', 'amp',
      'amp sim', 'pedal', 'bands', 'multiband drive', 'crunch', 'grit'], purposes: {_g, _b, _d, _v, _sd, _lo, _mix}),
    'org.caw.bits': DeviceName('Grit', 'Bit distortion', tags: ['bitcrush', 'bitcrusher', 'bit crusher', 'crush', 'bits',
      'sample rate', 'downsample', 'decimate', '8-bit', '8 bit', 'bitwise', 'xor', 'aliasing', 'glitch', 'bit mask',
      'and mask', 'or mask', 'bit rotate', 'bit reverse', 'bit freeze', 'bit flip', 'stutter', 'metallic'],
      purposes: {_lo, _sd, _d}),
    'org.caw.exciter': DeviceName('Glint', 'Exciter', tags: ['enhancer', 'harmonics', 'air', 'presence', 'sheen',
      'bass enhancer', 'bass', 'sub', 'aural exciter', 'maxxbass'], purposes: {_v, _b, _mix, _mas}),
    'org.caw.lofi': DeviceName('Dust', 'Lo-fi', tags: ['lofi', 'lo fi', 'vinyl', 'record', 'cassette', 'tape', 'radio',
      'telephone', 'old', 'crackle', 'wow', 'flutter', 'age'], purposes: {_lo, _sd}),
    // Modulation
    'org.caw.chorus': DeviceName('Flutter', 'Chorus/Flanger', tags: ['chorus', 'flanger', 'flange', 'ensemble', 'doubler',
      'double', 'vibrato', 'rotary', 'leslie', 'detune', 'jet', 'thicken'], purposes: {_g, _v, _sd}),
    'org.caw.phaser': DeviceName('Spiral', 'Phaser', tags: ['phase', 'phasing', 'swirl', 'all-pass', 'notch'],
      purposes: {_g, _sd}),
    'org.caw.tremolo': DeviceName('Wingbeat', 'Tremolo/Pan', tags: ['tremolo', 'pan', 'auto pan', 'autopan', 'panner',
      'shape', 'volume shaper', 'chopper', 'pulse'], purposes: {_g, _sd}),
    'org.caw.ringmod': DeviceName('Ring', 'Ring mod', tags: ['ring modulator', 'ringmod', 'am', 'robot', 'metallic',
      'bell'], purposes: {_sd}),
    'org.caw.trancegate': DeviceName('Strobe', 'Trance gate', tags: ['trancegate', 'gate', 'chopper', 'stutter gate',
      'rhythm', 'pattern'], purposes: {_sd}),
    // Space
    'org.caw.delay': DeviceName('Relay', 'Delay', tags: ['echo', 'tape delay', 'tape echo', 'ping pong', 'ping-pong',
      'slapback', 'dub', 'digital', 'reverse', 'reverse delay', 'multitap', 'taps'], purposes: {_g, _v, _sd, _mix}),
    'org.caw.reverb': DeviceName('Roost', 'Reverb', tags: ['verb', 'reverberation', 'hall', 'room', 'plate', 'spring',
      'shimmer', 'gated', 'gated reverb', 'reverse reverb', 'ambience', 'space', 'freeze'],
      purposes: {_g, _v, _d, _mix, _sd}),
    'org.caw.convolver': DeviceName('Hollow', 'Convolver', tags: ['convolution', 'convolution reverb', 'impulse response',
      'ir', 'cab', 'cabinet', 'cab sim', 'speaker', 'reverb', 'room'], purposes: {_g, _b, _mix, _sd}),
    // Pitch and time
    'org.caw.shift': DeviceName('Soar', 'Pitch/Shift', tags: ['pitch', 'pitch shift', 'pitch shifter', 'pitchshift',
      'frequency shifter', 'freqshift', 'harmonizer', 'harmoniser', 'harmony', 'octaver', 'octave', 'transpose',
      'detune', 'whammy'], purposes: {_v, _g, _sd}),
    'org.caw.pitchfix': DeviceName('Lark', 'Pitch correction', tags: ['autotune', 'auto-tune', 'auto tune', 'tune',
      'tuning', 'pitch fix', 'pitch correct', 'melodyne', 'key', 'scale', 'retune', 'hard tune', 'vocal tune', 'pitch editor'],
      purposes: {_v}),
    'org.caw.tapestop': DeviceName('Stall', 'Tape stop', tags: ['tapestop', 'tape', 'brake', 'slow down', 'spin up',
      'vinyl stop'], purposes: {_sd, _lo}),
    'org.caw.reverser': DeviceName('Rewind', 'Reverser', tags: ['reverse', 'backwards', 'flip'], purposes: {_sd}),
    'org.caw.stutter': DeviceName('Flicker', 'Stutter', tags: ['beat repeat', 'repeat', 'roll', 'glitch', 'retrigger'],
      purposes: {_sd, _d}),
    // Utility and tools
    'org.caw.utility': DeviceName('Wingspan', 'Stereo', tags: ['utility', 'utility/stereo', 'gain', 'trim', 'width',
      'stereo width', 'imager', 'stereo imager', 'balance', 'pan', 'haas', 'mono', 'mono bass', 'mixer',
      'channel mixer', 'phase invert', 'invert', 'swap', 'mid/side', 'm/s'], purposes: {_mix, _mas, _b}),
    'org.caw.downmix': DeviceName('Fold', 'Downmix', tags: ['mono', 'sum', 'fold down', 'stereo to mono'],
      purposes: {_mix}),
    'org.caw.meters': DeviceName('Lookout', 'Meters', tags: ['meter', 'analyzer', 'analyser', 'spectrum', 'spectrogram',
      'tuner', 'loudness', 'lufs', 'goniometer', 'correlation', 'scope', 'level'], purposes: {_mix, _mas, _g, _b}),
    'org.caw.phasealign': DeviceName('Formation', 'Phase align', tags: ['phase', 'alignment', 'polarity', 'time align',
      'mic', 'di', 'multi-mic'], purposes: {_d, _g, _b, _mix}),
    'org.caw.clean': DeviceName('Preen', 'Clean-up', tags: ['denoise', 'noise reduction', 'noise', 'hiss', 'de-hum',
      'dehum', 'hum', 'buzz', 'de-reverb', 'dereverb', 'room', 'restore', 'repair'], purposes: {_v, _g}),
    'org.caw.vocalclean': DeviceName('Hush', 'Vocal clean-up', tags: ['de-click', 'declick', 'click', 'de-plosive',
      'plosive', 'pop', 'pop filter', 'breath', 'breaths', 'mouth noise', 'crackle', 'repair'], purposes: {_v}),
    'org.caw.vocoder': DeviceName('Mimic', 'Vocoder', tags: ['vocoder', 'robot', 'talk box', 'talkbox', 'voice synth',
      'carrier'], purposes: {_v, _sd}),
    // Racks
    'org.caw.rack.fx': DeviceName('Nest', 'FX rack', tags: ['rack', 'chain', 'container', 'snap heap', 'macro',
      'effect rack'], purposes: {_sd, _mix}),
    'org.caw.rack.multiband': DeviceName('Branch', 'Multiband rack', tags: ['rack', 'multiband', 'multipass', 'crossover',
      'split', 'bands'], purposes: {_sd, _mix, _mas}),
    // The AutoStacc pack
    'org.caw.pack.granular': DeviceName('Murmur', 'Granular', tags: ['grains', 'granular', 'cloud', 'texture', 'freeze'],
      purposes: {_sd}),
    'org.caw.pack.glitch': DeviceName('Peck', 'Glitch', tags: ['glitch', 'stutter', 'beat repeat', 'chop', 'slice'],
      purposes: {_sd, _d}),
    'org.caw.pack.warp': DeviceName('Bend', 'Warp', tags: ['warp', 'wow', 'tape', 'speed', 'vinyl', 'time'],
      purposes: {_sd, _lo}),
    'org.caw.pack.spectral': DeviceName('Iris', 'Spectral', tags: ['spectral', 'fft', 'freeze', 'blur', 'smear'],
      purposes: {_sd}),
    // Instruments
    'org.caw.synth.flagship': DeviceName('Raven', 'Wavetable synth', tags: ['synth', 'synthesizer', 'wavetable',
      'flagship', 'fm', 'additive', 'subtractive', 'lead', 'pad', 'bass synth', 'vital', 'serum'],
      purposes: {_sd, _b}),
    'org.caw.sampler': DeviceName('Magpie', 'Sampler', tags: ['sampler', 'sample', 'samples', 'multisample', 'chop',
      'slice', 'keys'], purposes: {_sd, _d}),
    'org.caw.drums': DeviceName('Rook', 'Drums', tags: ['drum machine', 'drum kit', 'kit', 'drums', 'beat', '808', '909',
      'pads', 'percussion', 'kick', 'snare', 'hats'], purposes: {_d}),
    'org.caw.timber': DeviceName('Timber', 'Acoustic', tags: ['acoustic', 'physical modelling', 'physical modeling',
      'piano', 'electric piano', 'organ', 'guitar', 'strings', 'harp', 'mallets', 'bells', 'winds', 'keys'],
      purposes: {_g}),
    'org.caw.starling': DeviceName('Starling', 'Piano', tags: ['piano', 'grand piano', 'acoustic piano', 'realistic',
      'keys', 'upright', 'felt piano', 'struck strings'], purposes: {_g}),
    'org.caw.nightingale': DeviceName('Nightingale', 'Bowed strings', tags: ['strings', 'violin', 'viola', 'cello',
      'double bass', 'contrabass', 'bowed', 'orchestral', 'realistic'], purposes: {_g}),
    'org.caw.curlew': DeviceName('Curlew', 'Winds', tags: ['winds', 'woodwind', 'brass', 'flute', 'clarinet',
      'saxophone', 'sax', 'trumpet', 'trombone', 'french horn', 'horn', 'realistic'], purposes: {_g}),
    'org.caw.flock': DeviceName('Flock', 'Granular', tags: ['granular', 'grains', 'cloud', 'texture', 'drone', 'pad'],
      purposes: {_sd}),
    // MIDI effects
    'org.caw.midi.arp': DeviceName('Hop', 'Arpeggiator', tags: ['arp', 'arpeggio', 'arpeggiator'], purposes: {_sd}),
    'org.caw.midi.chords': DeviceName('Clutch', 'Chords', tags: ['chord', 'chords', 'harmony', 'stack']),
    'org.caw.midi.scale': DeviceName('Perch', 'Scale', tags: ['scale', 'key', 'quantize pitch', 'snap']),
    'org.caw.midi.echo': DeviceName('Ricochet', 'Note echo', tags: ['note echo', 'midi echo', 'repeat', 'delay']),
    'org.caw.midi.humanize': DeviceName('Ruffle', 'Humanize', tags: ['humanise', 'humanize', 'random', 'groove',
      'feel', 'timing']),
    // Modulators
    'org.caw.mod.lfo': DeviceName('Orbit', 'LFO', tags: ['lfo', 'oscillator', 'wobble', 'modulation']),
    'org.caw.mod.envelope': DeviceName('Arc', 'Envelope', tags: ['envelope', 'adsr', 'modulation']),
    'org.caw.mod.follower': DeviceName('Shadow', 'Envelope follower', tags: ['follower', 'envelope follower',
      'modulation']),
    'org.caw.mod.steps': DeviceName('Steps', 'Step sequencer', tags: ['steps', 'step sequencer', 'sequencer',
      'modulation']),
    'org.caw.mod.random': DeviceName('Flit', 'Random', tags: ['random', 'sample and hold', 's&h', 'modulation']),
    'org.caw.mod.macros': DeviceName('Macros', 'Macros', tags: ['macro', 'macros', 'knobs', 'modulation']),
    'org.caw.mod.midi': DeviceName('Wire', 'MIDI to CV', tags: ['midi', 'cv', 'velocity', 'pitch', 'modulation']),
  };

  /// Component [id]'s names, or null for a component the table doesn't name (a project's own C++, or an id the
  /// engine retired: a project naming one is converted when it opens, so it is never shown).
  static DeviceName? of(String id) => table[id];

  /// What the app shows for [id]: "Talon · Compressor", or [fallback] for a component the table doesn't name.
  static String title(String id, String fallback) => of(id)?.title ?? fallback;

  /// The short name ("Talon"), for names the app makes up ("Talon 2"), or [fallback].
  static String name(String id, String fallback) => of(id)?.name ?? fallback;

  /// The purposes of [id] (none for a component the table doesn't name).
  static Set<DevicePurpose> purposesOf(String id) => of(id)?.purposes ?? const {};

  /// How well [query] finds [id]: 0 an exact name or tag ("eq" → Plume), 1 a word of one starting with it, 2 one
  /// containing it; null when no word of the table's matches ([also]: more words to look at, such as a description).
  static int? rank(String id, String query, {Iterable<String> also = const []}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return 0;
    final words = [...?of(id)?.words, for (final w in also) w.toLowerCase()];
    int? best;
    for (final w in words) {
      final r = w == q ? 0 : (w.startsWith(q) || w.split(RegExp(r'[\s/·-]+')).any((p) => p.startsWith(q))) ? 1
          : w.contains(q) ? 2 : null;
      if (r != null && (best == null || r < best)) best = r;
      if (best == 0) break;
    }
    return best;
  }
}
