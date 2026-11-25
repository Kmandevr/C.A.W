// The "?" field guide's text for every built-in device, in the warm voice: what it does, the three knobs that matter, and a starting preset (one data file).
//
// Style (sound plan, "Personality"): say what it does and what to do, warm and plain, no jokes. Presets are the
// engine's own names (a test checks each one exists); null means start from Init.

/// One device's field guide.
class FieldGuide {
  const FieldGuide(this.what, this.knobs, [this.preset]);

  /// What the device does, in a sentence or two.
  final String what;

  /// The three knobs that matter: (knob, what it does for you).
  final List<(String, String)> knobs;

  /// A good preset to start from, or null for Init.
  final String? preset;
}

/// The guides by component id ([DeviceNames]' ids). A device without one gets [fieldGuideFallback].
const fieldGuides = <String, FieldGuide>{
  // Dynamics
  'org.caw.compressor': FieldGuide('Talon evens out the loud and quiet parts, so a part sits steady in the mix. Down '
      'turns the peaks down; Up lifts the quiet details; Bus glues a group together.', [
    ('Threshold', 'Where it starts working. Lower it until the meter moves on the loud parts.'),
    ('Ratio', 'How firmly it holds. 2:1 is gentle, 4:1 is firm, 10:1 is close to a limiter.'),
    ('Attack', 'How fast it grabs. Slower lets the hit of a drum or pick through first.'),
  ], 'Gentle glue'),
  'org.caw.limiter': FieldGuide('Hover is a ceiling nothing goes through. Put it last on the master to stop clipping '
      'and to make the mix louder without overs.', [
    ('Gain', 'How hard you push into the ceiling. Raise it slowly and listen for the punch going soft.'),
    ('Ceiling', 'The loudest the output gets. -1 dB leaves room for streaming.'),
    ('Release', 'How quickly it lets go. Longer is smoother, shorter is louder.'),
  ]),
  'org.caw.gate': FieldGuide('Hatch closes when a part goes quiet, so hum, room and bleed between notes drop away. '
      'Expand lowers them gently instead of cutting.', [
    ('Threshold', 'Set it just above the noise, so it opens on every note you want.'),
    ('Range', 'How far it turns down when closed. Less range sounds more natural.'),
    ('Release', 'How it fades out. Longer keeps the tails of notes.'),
  ], 'Tame the room'),
  'org.caw.duck': FieldGuide('Swoop turns this track down while another one plays, so a voice or kick always comes '
      'through. Level rides a part to an even loudness on its own.', [
    ('Threshold', 'How loud the key needs to be before it ducks.'),
    ('Amount', 'How far it ducks. A few dB is felt more than heard.'),
    ('Release', 'How fast it comes back. Match it to the tempo for a pump.'),
  ], 'Kick duck bass'),
  'org.caw.transient': FieldGuide('Stoop changes the hit and the ring of a sound, whatever its level: more snap on a '
      'snare, less room on a kick.', [
    ('Attack', 'Up for more snap at the start, down to soften it.'),
    ('Sustain', 'Up for more body and room, down for a tighter, drier hit.'),
    ('Mix', 'Blend it back with the original when it gets too much.'),
  ]),
  'org.caw.multiband': FieldGuide('Puff compresses the lows, mids and highs on their own, and can lift the quiet '
      'parts too. OTT is its loud, bright, everything-up sound.', [
    ('Depth', 'How much it does overall. Start low; it adds up fast.'),
    ('Upward', 'How much the quiet details come up.'),
    ('Downward', 'How much the loud parts come down.'),
  ], 'OTT gentle'),
  'org.caw.deesser': FieldGuide('Quell turns down harsh "s" and "t" sounds in a voice, and leaves the rest alone.', [
    ('Frequency', 'Where the esses are. Use Listen to find the sharpest spot.'),
    ('Threshold', 'Lower it until only the esses trigger it.'),
    ('Range', 'How far it turns them down. Too much makes a lisp.'),
  ], 'Vocal'),
  // EQ and filters
  'org.caw.eq': FieldGuide('Plume shapes the tone: cut what gets in the way, lift what you want to hear. Bands, '
      'Graphic, DJ, Tilt and Match are its modes.', [
    ('Frequency', 'Which part of the sound a band works on. Sweep it while you listen.'),
    ('Gain', 'Boost or cut there. Cutting first usually sounds cleaner.'),
    ('Q', 'How wide the band is. Narrow for a ring, wide for a gentle tilt.'),
  ], 'Less mud'),
  'org.caw.filter': FieldGuide('Sweep keeps some frequencies and removes the rest. Move the cutoff for builds, wahs '
      'and drops.', [
    ('Cutoff', 'Where it cuts. Automate it for a sweep.'),
    ('Resonance', 'A peak at the cutoff. Higher sounds more vocal, then whistles.'),
    ('LFO amount', 'Lets the cutoff move on its own, in time if you sync it.'),
  ], 'Warm low-pass'),
  'org.caw.comb': FieldGuide('Comb adds a tight, metallic ring at one pitch, from a subtle colour to a robotic tone.', [
    ('Frequency', 'The pitch of the ring. Tune it by note to stay in key.'),
    ('Feedback', 'How long and strong the ring is.'),
    ('Mix', 'How much of it you hear.'),
  ], 'Metallic'),
  'org.caw.resonator': FieldGuide('Trill makes anything ring like a string or bell tuned to a note or chord.', [
    ('Note', 'The root it rings at.'),
    ('Decay', 'How long it rings after each hit.'),
    ('Brightness', 'Dark and soft, or bright and glassy.'),
  ], 'Plucked string'),
  'org.caw.formant': FieldGuide('Coo gives a sound vowels, like a mouth shaping it: ahh, ooh, eee.', [
    ('Vowel X', 'Moves between vowels. Automate it to make a sound talk.'),
    ('Vowel Y', 'The other direction of the vowel pad.'),
    ('Gender / shift', 'A bigger or smaller mouth.'),
  ], 'Ahh'),
  'org.caw.disperser': FieldGuide('Scatter smears the timing of frequencies, for laser zaps, deeper kicks and soft '
      'snaps.', [
    ('Amount', 'How much it smears.'),
    ('Frequency', 'Where the smear sits.'),
    ('Pinch', 'How narrow it is around that frequency.'),
  ], 'Soft snap'),
  // Drive
  'org.caw.drive': FieldGuide('Ember adds harmonics: warm tape and tube, a crunchy amp, a pedal, or a hard clip.', [
    ('Drive', 'How hard it pushes. A little adds warmth; a lot adds grit.'),
    ('Shape', 'The kind of distortion. Try a few at the same drive.'),
    ('Mix', 'Blend the clean sound back in to keep the punch.'),
  ], 'Warm tape'),
  'org.caw.bits': FieldGuide('Grit lowers the bits and the sample rate, for old samplers, game consoles and broken '
      'radios.', [
    ('Bits', 'Fewer bits for more crunch and noise.'),
    ('Sample rate', 'Lower for an aliased, metallic edge.'),
    ('Mix', 'Keep some of the clean sound underneath.'),
  ], '12-bit sampler'),
  'org.caw.exciter': FieldGuide('Glint adds fresh harmonics: air and presence on top, or bass that carries on small '
      'speakers.', [
    ('Frequency', 'Where the new harmonics start.'),
    ('Amount', 'How much it adds. Less than you think is usually right.'),
    ('Tone', 'Smooth or bright.'),
  ], 'Vocal air'),
  'org.caw.lofi': FieldGuide('Dust makes a sound older: vinyl crackle, worn tape, hiss and a narrow radio band.', [
    ('Age', 'One knob for how old it sounds.'),
    ('Wobble', 'Tape wow and flutter.'),
    ('Crackle', 'Vinyl dust and pops.'),
  ], 'Dusty sample'),
  // Modulation
  'org.caw.chorus': FieldGuide('Flutter thickens a sound with slightly moving copies: chorus, ensemble, doubler, '
      'flanger, vibrato and rotary.', [
    ('Rate', 'How fast the copies move. Slow is lush, fast is wobbly.'),
    ('Depth', 'How far they move.'),
    ('Mix', 'How much you hear. Half way is a good start.'),
  ], 'Subtle thicken'),
  'org.caw.phaser': FieldGuide('Spiral sweeps notches through the sound for a swirling, liquid movement.', [
    ('Rate', 'How fast it sweeps. Sync it to the tempo for a groove.'),
    ('Feedback', 'Makes the notches sharper and more vocal.'),
    ('Mix', 'How much of the swirl you hear.'),
  ]),
  'org.caw.tremolo': FieldGuide('Wingbeat moves the level or the place of a sound in time: tremolo, auto pan, or a '
      'shape you draw.', [
    ('Rate', 'How fast it moves. Sync it for rhythm.'),
    ('Depth', 'How far it moves.'),
    ('Shape', 'Smooth like an amp, or square like a chopper.'),
  ], 'Amp tremolo'),
  'org.caw.ringmod': FieldGuide('Ring multiplies the sound by a tone, for bells, robots and clangy metal.', [
    ('Frequency', 'The tone it multiplies by. Low is a tremolo, high is metal.'),
    ('Stereo spread', 'Sets the sides apart for width.'),
    ('Mix', 'How much of the effect you hear.'),
  ], 'Classic ring'),
  'org.caw.trancegate': FieldGuide('Blink chops a sound to a step pattern, so pads and chords pulse in time.', [
    ('Steps', 'How many steps the pattern has; tap them to turn them on and off.'),
    ('Gate length', 'How long each step stays open.'),
    ('Release', 'Soft or clipped edges.'),
  ], 'Classic 16'),
  // Space
  'org.caw.delay': FieldGuide('Relay repeats the sound: a quick slapback, echoes in time, tape that wobbles, or '
      'ping-pong across the sides.', [
    ('Sync', 'The echo time in beats. A dotted eighth is a classic.'),
    ('Feedback', 'How many repeats. High values build up, so go slowly.'),
    ('Mix', 'How loud the echoes are.'),
  ], 'Tape slapback'),
  'org.caw.reverb': FieldGuide('Roost puts a sound in a space: a small room, a hall, a plate, a spring or a shimmer.', [
    ('Decay', 'How long the space rings.'),
    ('Pre-delay', 'A short gap before the space starts, so the dry sound stays clear.'),
    ('Mix', 'How far back the sound sits.'),
  ], 'Vocal plate'),
  'org.caw.convolver': FieldGuide('Call plays a sound through a real space or speaker cabinet, from a recording of '
      'it.', [
    ('Impulse', 'Which space or cab.'),
    ('Size / stretch', 'Makes the space bigger or smaller.'),
    ('Mix', 'How much of the space you hear. A cab sits at full mix.'),
  ], 'Small room'),
  // Pitch and time
  'org.caw.shift': FieldGuide('Soar moves the pitch: an octave up or down, harmonies in key, or a frequency shift for '
      'odd metallic tones.', [
    ('Semitones', 'How far it moves. 12 is an octave.'),
    ('Cents', 'Fine tuning, for a doubled, wider sound.'),
    ('Mix', 'Blend the shifted voice with the original.'),
  ], 'Octave down'),
  'org.caw.pitchfix': FieldGuide('Chirp pulls a voice to the notes of a key, from a gentle polish to a hard, '
      'stepped tune.', [
    ('Key and scale', 'The notes it may land on. Set them to the song.'),
    ('Speed', 'How fast it pulls. Slow is natural, fast is the hard-tune sound.'),
    ('Humanize', 'Keeps long notes a little loose, so it sounds sung.'),
  ], 'Natural vocal'),
  'org.caw.tapestop': FieldGuide('Stall slows the sound to a halt like tape or a turntable, and spins it back up.', [
    ('Stop', 'Turn it on to stop; automate it on the beat.'),
    ('Stop time', 'How long the slow-down takes.'),
    ('Curve', 'How the speed falls: steady, or late and sudden.'),
  ], 'Quick stop'),
  'org.caw.reverser': FieldGuide('Rewind plays short pieces of the sound backwards, in time with the song.', [
    ('Time', 'How long each reversed piece is.'),
    ('Crossfade', 'Smooths the joins.'),
    ('Mix', 'How much is reversed.'),
  ], 'Quarter flip'),
  'org.caw.stutter': FieldGuide('Flicker repeats a slice of the sound, for fills, rolls and glitches.', [
    ('Division', 'How short each repeat is.'),
    ('Chance', 'How often it happens.'),
    ('Pitch per repeat', 'Rises or falls with each repeat.'),
  ], 'Fill on the 4'),
  // Utility and tools
  'org.caw.utility': FieldGuide('Wingspan handles gain and the stereo field: width, balance, mono bass, Haas and '
      'channel swaps.', [
    ('Gain', 'Turns the part up or down without changing its tone.'),
    ('Width', 'Narrower towards mono, wider towards the sides.'),
    ('Bass mono', 'Keeps the low end in the middle, where it hits hardest.'),
  ], 'Mono bass'),
  'org.caw.meters': FieldGuide('Spot shows what you hear: the spectrum, the stereo field, loudness and a tuner.', [
    ('Source', 'What it measures.'),
    ('Tilt', 'Tilts the spectrum so a balanced mix looks level.'),
    ('Mode', 'Spectrum, stereo, loudness or tuner.'),
  ], 'Mix spectrum'),
  'org.caw.phasealign': FieldGuide('Formation lines up two mics on one source, so they add up full instead of '
      'thin.', [
    ('Learn', 'Listens and finds the best delay for you.'),
    ('Delay', 'The time between the mics.'),
    ('Invert', 'Flips the polarity when it sounds hollow.'),
  ], 'Auto align (2 s)'),
  'org.caw.clean': FieldGuide('Preen removes steady noise: hiss, hum and buzz, or too much room.', [
    ('Learn', 'Play a moment of just the noise, and it learns what to remove.'),
    ('Reduction', 'How much it takes away. Stop before the voice sounds watery.'),
    ('Listen to removed', 'Hear only what it takes out, to check it is only noise.'),
  ], 'Voice clean-up'),
  'org.caw.vocalclean': FieldGuide('Hush removes small vocal noises: mouth clicks, pops on "p" and "b", and loud '
      'breaths.', [
    ('Mode', 'Clicks, plosives or breaths.'),
    ('Sensitivity', 'How easily it reacts. Raise it until the noises go.'),
    ('Listen to removed', 'Hear only what it takes out.'),
  ], 'Pop filter'),
  'org.caw.vocoder': FieldGuide('Mimic makes a synth speak with your voice: play notes on the key track and talk or '
      'sing into this one.', [
    ('Bands', 'More bands for clearer words, fewer for a classic robot.'),
    ('Carrier', 'What does the singing: the built-in synth, or another track.'),
    ('Formant', 'A bigger or smaller voice.'),
  ], 'Classic robot'),
  'org.caw.downmix': FieldGuide('Fold sums the two sides into one, to check a mix in mono or feed a mono input.', [
    ('Mode', 'How the sides are combined: both, or one side only.'),
    ('Power', 'Turn it off and on to compare with the stereo sound.'),
    ('Track volume', 'Summing can change the level; even it out on the track.'),
  ]),
  // Racks
  'org.caw.rack.fx': FieldGuide('Nest holds up to eight effects in one device, with its own LFOs, envelopes and '
      'macros.', [
    ('Slots', 'Add effects in the order they run.'),
    ('Macros', 'One knob that moves many; map them to the knobs you use most.'),
    ('Mix', 'Blend the whole rack with the dry sound.'),
  ], 'Dub space'),
  'org.caw.rack.multiband': FieldGuide('Branch splits the sound into bands, each with its own effects.', [
    ('Crossovers', 'Where the bands split.'),
    ('Band effects', 'What runs on each band.'),
    ('Band level', 'Balance the bands after their effects.'),
  ], 'Mono lows, wide top'),
  // The AutoStacc pack
  'org.caw.pack.granular': FieldGuide('Murmur breaks the sound into tiny grains and scatters them into clouds and '
      'textures.', [
    ('Size', 'How long each grain is.'),
    ('Density', 'How many grains play at once.'),
    ('Spray', 'How far they wander from where you are.'),
  ], 'Soft cloud'),
  'org.caw.pack.glitch': FieldGuide('Peck chops the beat into repeats, reverses and pitch jumps, in time.', [
    ('Chaos', 'How often something happens.'),
    ('Grid', 'The size of the chops.'),
    ('Mix', 'How much of the glitch you hear.'),
  ], 'Light pecks'),
  'org.caw.pack.warp': FieldGuide('Bend bends time and pitch, like warped tape or a turntable pushed by hand.', [
    ('Depth', 'How far it bends.'),
    ('Cycle', 'How long one bend takes.'),
    ('Shape', 'Smooth wobble or sharp steps.'),
  ], 'Tape wow'),
  'org.caw.pack.spectral': FieldGuide('Molt freezes and paints the spectrum, for pads from any sound.', [
    ('Freeze', 'Holds the sound as it is now.'),
    ('Blur', 'Smears it into a wash.'),
    ('Shift', 'Moves it up or down.'),
  ], 'Freeze pad'),
  // Instruments
  'org.caw.synth.flagship': FieldGuide('Kestrel is a wavetable synth with three oscillators, two filters and a mod '
      'matrix: basses, leads, pads and keys.', [
    ('Osc 1 frame', 'Moves through the wavetable; the main way to change the tone.'),
    ('Filter cutoff', 'Darker or brighter.'),
    ('Amp release', 'How long notes ring after you let go.'),
  ], 'Morph pad'),
  'org.caw.sampler': FieldGuide('Magpie plays a sample across the keyboard; drop one on it and play.', [
    ('Transpose', 'Moves the sample up or down in semitones.'),
    ('Attack and release', 'How notes start and fade.'),
    ('Cutoff', 'Darker or brighter.'),
  ]),
  'org.caw.drums': FieldGuide('Rook is a drum kit: each pad its own drum, with kits from 808 to acoustic.', [
    ('Kit', 'Pick a kit from the presets to start.'),
    ('Glue', 'A bus compressor on the whole kit.'),
    ('Kit drive', 'Warmth and grit on the whole kit.'),
  ], 'Kit: 808'),
  'org.caw.timber': FieldGuide('Timber models real instruments with no samples: pianos, keys, plucked and bowed '
      'strings, mallets and winds.', [
    ('Tone', 'Darker or brighter, like playing softer or harder.'),
    ('Body', 'How big the instrument is.'),
    ('Space', 'The room around it.'),
  ], 'Concert grand'),
  'org.caw.starling': FieldGuide('Starling is real-sounding struck and plucked strings: a grand piano, a classical '
      'guitar or a concert harp (pick it under Model), modelled strings with the real instrument\'s recorded attack.', [
    ('Hammer', 'Piano: softer or harder hammers, darker or brighter.'),
    ('Pluck position', 'Guitar and harp: near the bridge is thin and bright, the middle round and warm.'),
    ('Space', 'A room around it (off by default: add your own reverb).'),
  ], 'Grand piano'),
  'org.caw.nightingale': FieldGuide('Nightingale is a bowed string: violin, viola, cello or double bass, played by a '
      'modelled bow.', [
    ('Bow pressure', 'Light and airy, or digging in.'),
    ('Bow position', 'Glassy at the bridge, soft over the fingerboard.'),
    ('Vibrato', 'How much the finger rocks the pitch.'),
  ], 'Solo violin'),
  'org.caw.curlew': FieldGuide('Curlew is a wind player: flute, clarinet, sax, trumpet, trombone or horn, '
      'blown by a modelled breath.', [
    ('Breath', 'How hard it is blown: soft and round, or bright and forward.'),
    ('Breath noise', 'The air you hear around the tone.'),
    ('Vibrato', 'A gentle waver in the note.'),
  ], 'Concert flute'),
  'org.caw.bittern': FieldGuide('Bittern is a cathedral pipe organ: draw its stops and it fills a great stone '
      'room.', [
    ('Stops', 'Each rank of pipes: flutes, principals, strings, the trumpet.'),
    ('Tremulant', 'A pulse in the wind, for a warm, vocal tone.'),
    ('Space', 'The cathedral (on): turn it down for the organ loft.'),
  ], 'Cathedral principal chorus'),
  'org.caw.woodpecker': FieldGuide('Woodpecker is tuned percussion: marimba, xylophone, glockenspiel, vibraphone, '
      'tubular bells or timpani, each with its recorded mallet stroke.', [
    ('Mallet hardness', 'Soft yarn and round, or hard and bright.'),
    ('Decay', 'How long the bars ring.'),
    ('Motor rate', 'The vibraphone\'s shimmer (off until you turn it up).'),
  ], 'Concert marimba'),
  'org.caw.flock': FieldGuide('Flock plays a sample as a cloud of grains, for pads, textures and drones.', [
    ('Position', 'Where in the sample the grains come from.'),
    ('Size', 'How long each grain is.'),
    ('Density', 'How thick the cloud is.'),
  ], 'Soft strings cloud'),
  // MIDI effects
  'org.caw.midi.arp': FieldGuide('Hop plays held chords as patterns of single notes.', [
    ('Rate', 'How fast the notes come, in beats.'),
    ('Pattern', 'Up, down, up and down, or random.'),
    ('Octaves', 'How many octaves it climbs.'),
  ]),
  'org.caw.midi.chords': FieldGuide('Clutch turns one note into a chord in your key.', [
    ('Key and scale', 'The key the chords fit.'),
    ('Chord', 'Triads, sevenths and more.'),
    ('Strum', 'Plays the notes one after another, like a guitar.'),
  ]),
  'org.caw.midi.scale': FieldGuide('Perch keeps every note in a key, so nothing played is a wrong note.', [
    ('Key', 'The root of the scale.'),
    ('Scale', 'Major, minor and the modes.'),
    ('Mode', 'Snap to the nearest note, or leave out the others.'),
  ]),
  'org.caw.midi.echo': FieldGuide('Mock repeats each note, quieter each time, for echoes the synth plays itself.', [
    ('Time', 'How far apart the repeats are.'),
    ('Repeats', 'How many there are.'),
    ('Pitch', 'Moves each repeat up or down.'),
  ]),
  'org.caw.midi.humanize': FieldGuide('Ruffle moves notes a little in time and velocity, so parts feel played.', [
    ('Timing', 'How far notes drift from the grid.'),
    ('Velocity', 'How much their loudness varies.'),
    ('Seed', 'A different take of the same feel.'),
  ]),
  // Modulators
  'org.caw.mod.lfo': FieldGuide('Orbit moves a knob up and down in a repeating shape.', [
    ('Shape', 'Sine, triangle, square or one you draw.'),
    ('Rate', 'How fast; sync it to the tempo.'),
    ('Amount', 'Set on each knob it moves: drag from its output to a knob.'),
  ]),
  'org.caw.mod.envelope': FieldGuide('Arc moves a knob once per note: up, down, and back when you let go.', [
    ('Attack', 'How fast it rises.'),
    ('Decay and sustain', 'Where it settles while you hold the note.'),
    ('Release', 'How it falls when you let go.'),
  ]),
  'org.caw.mod.follower': FieldGuide('Shadow follows how loud a track is, and moves a knob with it.', [
    ('Attack', 'How fast it follows a rise.'),
    ('Release', 'How fast it follows a fall.'),
    ('Gain', 'How much a quiet track moves it.'),
  ]),
  'org.caw.mod.steps': FieldGuide('Steps moves a knob through a pattern of steps, in time.', [
    ('Steps', 'How many steps; drag each one to its value.'),
    ('Rate', 'How long each step is.'),
    ('Glide', 'Slides between steps instead of jumping.'),
  ]),
  'org.caw.mod.random': FieldGuide('Flit moves a knob to new random values, in time or smoothly.', [
    ('Rate', 'How often it changes.'),
    ('Smooth', 'Jumps or glides.'),
    ('Seed', 'A different pattern of the same kind.'),
  ]),
  'org.caw.mod.macros': FieldGuide('Macros are eight knobs that each move many: map them, then play the whole sound '
      'with one hand.', [
    ('Macro 1', 'Map it to the knobs you reach for most.'),
    ('Macro 2', 'A second gesture, such as brightness.'),
    ('Macro 3', 'A third, such as space.'),
  ]),
  'org.caw.mod.midi': FieldGuide('Wire turns the notes you play into modulation: pitch, velocity, gate and '
      'pressure.', [
    ('Lowest and highest note', 'The range that maps to the full sweep.'),
    ('Glide', 'Smooths jumps between notes.'),
    ('Priority', 'Which held note it follows.'),
  ]),
};

/// The guide for a device without its own: the shape of one, with its first three knobs.
FieldGuide fieldGuideFallback(String name, List<String> knobs) => FieldGuide(
    '$name has no field guide yet. Start from Init, then turn one knob at a time and listen.',
    [for (final k in knobs.take(3)) (k, 'Turn it slowly and listen to what changes.')]);
