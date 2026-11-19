// Every setting's id, section, card, title, description and search words: the one list Settings' pages, cards and search follow.
import 'dart:io';

import 'package:flutter/material.dart';

import '../../model/settings.dart';
import '../../model/templates.dart' show templateLabel;
import '../../platform/distribution.dart';
import '../../version.dart';
import '../theme.dart';

/// The Settings sections, in the category list's order: by how often they are used (owner, 2026-11-18, #244).
enum SettingsSection {
  sound('Sound', Icons.speaker_outlined),
  editing('Editing', Icons.edit_note),
  appearance('Appearance and feel', Icons.palette_outlined),
  projects('Projects and export', Icons.folder_outlined),
  app('App', Icons.tune);

  const SettingsSection(this.title, this.icon);
  final String title;
  final IconData icon;

  /// The section's accent, cycling through the theme's neon colours.
  Color get color => [Neon.green, Neon.blue, Neon.pink, Neon.yellow, Neon.violet][index % 5];

  /// The section's cards, in page order.
  List<SettingsCard> get cards => [for (final c in SettingsCard.values) if (c.section == this) c];

  /// One line of the section's current values, for the category list.
  String summary(Settings s) {
    String rate(int r) => '${(r / 1000).toStringAsFixed(r % 1000 == 0 ? 0 : 1)} kHz';
    return switch (this) {
      sound => [
          s.audioDevice.isEmpty ? 'System default' : s.audioDevice,
          rate(s.sampleRate),
          s.bufferFrames == 0 ? 'buffer ${s.audioBuffer.label}' : '${s.bufferFrames} frames',
          s.soundQuality.label,
          if (!s.safetyLimiter) 'limiter off',
        ].join(' · '),
      editing => [
          s.followPlayhead ? 'Follows the playhead' : 'Stays put',
          'grid 1/${s.rollGrid}',
          s.rollSnap ? 'snap on' : 'snap off',
          s.rollTool.label,
        ].join(' · '),
      appearance => [
          s.themeName,
          s.lookMode.label,
          s.compact ? 'Compact' : 'Comfortable',
          'motion ${s.motion.name}',
          if (s.leftHanded) 'left-handed',
        ].join(' · '),
      projects => [
          'Autosave ${s.autosaveMs < 1000 ? '${s.autosaveMs} ms' : '${s.autosaveMs ~/ 1000} s'}',
          '${s.restorePointsKept} restore points',
          'new: ${templateLabel(s.newProjectTemplate)}',
          'export ${exportKindLabel(s.exportKind).toLowerCase()}',
        ].join(' · '),
      app => [s.performanceMode.label, if (s.lightAuto) 'auto Lightweight', 'v$appVersion'].join(' · '),
    };
  }
}

/// A group of related settings on a section's page (owner, 2026-11-18, #244): a rounded glass card with a small
/// header, its everyday settings shown and the rarer ones under its More fold.
enum SettingsCard {
  devices(SettingsSection.sound, 'Audio devices', Icons.speaker),
  quality(SettingsSection.sound, 'Quality and buffer', Icons.high_quality_outlined),
  latency(SettingsSection.sound, 'Latency and Bluetooth', Icons.bluetooth_audio),
  recording(SettingsSection.sound, 'Recording and metronome', Icons.fiber_manual_record_outlined),
  midi(SettingsSection.sound, 'MIDI and controllers', Icons.piano_outlined),
  arrange(SettingsSection.editing, 'Arrange', Icons.view_timeline_outlined),
  newTracks(SettingsSection.editing, 'New tracks', Icons.playlist_add),
  roll(SettingsSection.editing, 'Piano roll', Icons.piano),
  automation(SettingsSection.editing, 'Automation', Icons.timeline),
  theme(SettingsSection.appearance, 'Theme and glass', Icons.palette_outlined),
  layout(SettingsSection.appearance, 'Layout and sizes', Icons.dashboard_outlined),
  motion(SettingsSection.appearance, 'Motion', Icons.animation),
  touch(SettingsSection.appearance, 'Haptics and menus', Icons.vibration),
  saving(SettingsSection.projects, 'Saving', Icons.save_outlined),
  newProjects(SettingsSection.projects, 'New projects', Icons.add_box_outlined),
  export(SettingsSection.projects, 'Export', Icons.ios_share),
  storage(SettingsSection.projects, 'Storage', Icons.storage),
  performance(SettingsSection.app, 'Performance', Icons.speed),
  code(SettingsSection.app, 'Code editor', Icons.code),
  keys(SettingsSection.app, 'Keys and shortcuts', Icons.keyboard_alt_outlined),
  about(SettingsSection.app, 'About', Icons.info_outline),
  updates(SettingsSection.app, 'Updates', Icons.system_update_alt),
  privacy(SettingsSection.app, 'Privacy and feedback', Icons.privacy_tip_outlined);

  const SettingsCard(this.section, this.title, this.icon);
  final SettingsSection section;
  final String title;
  final IconData icon;

  /// The card's entries in page order: its everyday rows, then its More fold's.
  List<SettingEntry> get entries => [for (final e in settingEntries) if (e.card == this && e.searchable) e];
}

String exportKindLabel(String kind) => switch (kind) {
      'free' => 'Free length',
      'oneShot' => 'One-shot',
      'wavetable' => 'Wavetable',
      'midi' => 'MIDI file',
      _ => 'Loop',
    };

extension SoundQualityLabel on SoundQuality {
  String get label => switch (this) { SoundQuality.eco => 'Eco', SoundQuality.normal => 'Normal', SoundQuality.high => 'High' };
}

extension AudioBufferLabel on AudioBuffer {
  String get label => switch (this) {
        AudioBuffer.auto => 'Auto',
        AudioBuffer.lowLatency => 'Low latency',
        AudioBuffer.battery => 'Battery',
      };
}

/// One setting as the search sees it. [id] is also the row's key on its page (`SettingRow`).
class SettingEntry {
  /// An everyday setting, shown in its card.
  const SettingEntry(this.id, this.card, this.title, this.description, [this.keywords = const []])
      : more = false,
        searchable = true;

  /// A rarer setting, under its card's More fold (search opens the fold).
  const SettingEntry.more(this.id, this.card, this.title, this.description, [this.keywords = const []])
      : more = true,
        searchable = true;

  /// A row on a page of its own inside a card (Privacy's): a title for its row, not a search result (search lists
  /// its way in instead).
  const SettingEntry.page(this.id, this.card, this.title, this.description)
      : keywords = const [],
        more = false,
        searchable = false;

  final String id;
  final SettingsCard card;
  final bool more, searchable;
  final String title, description;
  final List<String> keywords;

  SettingsSection get section => card.section;

  /// Whether every word of [query] is in the title, description, keywords, card or section name.
  bool matches(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (words.isEmpty) return false;
    final text = '$title $description ${keywords.join(' ')} ${card.title} ${section.title}'.toLowerCase();
    return words.every(text.contains);
  }
}

typedef _E = SettingEntry;
typedef _C = SettingsCard;

/// Every setting on every page, in page order (section, card, then the card's rows). Each id is here once: one
/// setting, one place (#244); a second way to it links here.
const List<SettingEntry> settingEntries = [
  _E('audio.status', _C.devices, 'Device now', 'What the audio device runs at: backend, device, rate, buffer and latency',
      ['latency', 'ms', 'running', 'backend', 'aaudio', 'wasapi']),
  _E('audio.device', _C.devices, 'Output device', 'Where the sound plays; the system default follows the phone',
      ['speaker', 'headphones', 'usb', 'interface', 'output', 'sound card']),
  _E('audio.input', _C.devices, 'Audio input', 'Record and monitor audio tracks: asks for the microphone the first time',
      ['microphone', 'mic', 'record', 'input', 'interface', 'permission']),
  _E('audio.inputDevice', _C.devices, 'Input device', 'Where audio tracks record from', ['microphone', 'usb', 'interface', 'capture']),
  _E('audio.inputChannels', _C.devices, 'Input channels', 'How many of the device\'s channels open (tracks pick theirs)',
      ['mono', 'stereo', 'channels']),
  _E('audio.rate', _C.devices, 'Sample rate', 'The rate the engine runs at: 44.1, 48, 88.2 or 96 kHz',
      ['khz', 'hz', 'quality', '44100', '48000', '96000']),
  _E.more('audio.pauseOnUnplug', _C.devices, 'Pause when unplugged', 'Playback stops when headphones or a Bluetooth output disconnect',
      ['headphones', 'bluetooth', 'unplug', 'disconnect', 'noisy', 'speaker', 'pause']),
  _E.more('audio.test', _C.devices, 'Test tone', 'Plays 440 Hz for a moment to check the output', ['beep', 'sine', 'check', 'a4']),
  _E('audio.quality', _C.quality, 'Sound quality', 'Eco, Normal or High: oversampling, unison copies and reverb density',
      ['eco', 'battery', 'oversampling', 'cpu']),
  _E('audio.buffer', _C.quality, 'Buffer size', 'The callback size in frames, down to the smallest the device gives',
      ['latency', 'frames', 'period', 'samples', 'ms', 'delay']),
  _E('audio.mode', _C.quality, 'Buffer mode', 'Auto, Low latency or Battery: the size and power path when Buffer size is Auto',
      ['latency', 'battery', 'power', 'low latency', 'mmap']),
  _E('audio.safetyLimiter', _C.quality, 'Safety limiter', 'A gentle limiter on what plays, to protect ears and speakers; never in exports',
      ['limiter', 'loud', 'ears', 'protect', 'clip', 'volume', 'hearing', 'speaker']),
  _E.more('audio.bufferTuning', _C.quality, 'Find the smallest stable buffer', 'While playing, the buffer shrinks until it plays steadily and grows after a dropout',
      ['buffer', 'latency', 'tune', 'tuner', 'automatic', 'dropout', 'glitch', 'aaudio']),
  _E.more('audio.autoGain', _C.quality, 'Auto gain on new devices', 'Each device you add starts with its auto gain on (the ear in its header)',
      ['auto gain', 'loudness', 'gain staging', 'level', 'ear', 'match', 'volume']),
  _E.more('audio.monoCheck', _C.quality, 'Mono check', 'Hear the mix in mono, to check what cancels; for listening only, never in exports',
      ['mono', 'stereo', 'phase', 'mix', 'check', 'sum']),
  _E.more('audio.exclusive', _C.quality, 'Exclusive mode', 'Take the device for C.A.W alone: AAudio exclusive, WASAPI exclusive',
      ['latency', 'mmap', 'wasapi', 'aaudio', 'low latency', 'exclusive']),
  _E.more('audio.background', _C.quality, 'Background playback', 'Whether Android restricts C.A.W\'s battery behind other apps (Android)',
      ['battery', 'unrestricted', 'background', 'optimization', 'samsung', 'sleep']),
  _E('audio.outputLatency', _C.latency, 'Latency', 'How late Bluetooth, USB or HDMI output and the microphone are, per device',
      ['bluetooth', 'delay', 'late', 'offset', 'compensation', 'a2dp', 'headphones', 'calibrate', 'tap along',
       'loopback', 'microphone', 'sync', 'playhead', 'meters']),
  _E('audio.latency', _C.latency, 'Measure recording latency', 'A short noise burst finds the round trip, so takes land in time',
      ['latency', 'ping', 'calibrate', 'offset', 'delay', 'loopback']),
  _E.more('audio.latencyOffset', _C.latency, 'Audio take offset', 'The round trip for audio takes typed in, in milliseconds (instead of the measured one)',
      ['latency', 'offset', 'delay', 'manual', 'compensation', 'recording offset']),
  _E.more('recording.offset', _C.latency, 'MIDI note offset', 'Writes played MIDI notes this much earlier, for the output delay',
      ['latency', 'compensation', 'delay', 'ms', 'timing', 'recording offset']),
  _E('recording.metronome', _C.recording, 'Metronome', 'Off, click while recording, or click whenever playing',
      ['click', 'beat', 'tempo']),
  _E('recording.countIn', _C.recording, 'Count-in', 'Bars of clicks before a recording starts from a stop', ['metronome', 'bars']),
  _E('recording.mode', _C.recording, 'Record mode', 'Where a track already has clips: a new clip of takes, Overdub or Replace',
      ['takes', 'overdub', 'replace', 'record', 'loop', 'comping']),
  _E('audio.punch', _C.recording, 'Punch in and out', 'Record only over the loop range or the time selection',
      ['punch', 'loop', 'selection', 'range']),
  _E.more('recording.clickSound', _C.recording, 'Click sound', 'Classic, Wood or Tick', ['metronome', 'beep', 'sound']),
  _E.more('recording.clickVolume', _C.recording, 'Click volume', 'How loud the metronome and count-in click', ['metronome', 'level']),
  _E.more('recording.preRoll', _C.recording, 'Pre-roll', 'Bars played before the record point; heard, not recorded',
      ['punch', 'bars', 'lead in']),
  _E.more('recording.monitor', _C.recording, 'New audio tracks hear', 'A new audio track\'s monitoring: Off, Auto (while armed) or On',
      ['monitor', 'monitoring', 'input', 'hear', 'new track', 'default']),
  _E.more('audio.recordFormat', _C.recording, 'Recording format', '32-bit float or 24-bit WAV takes', ['wav', 'bits', 'float', 'format']),
  _E('midi.devices', _C.midi, 'MIDI devices', 'The connected keyboards and pad controllers: on or off, and a light as each plays',
      ['usb', 'bluetooth', 'controller', 'pads', 'keyboard', 'device', 'connect']),
  _E('midi.device', _C.midi, 'MIDI keyboard', 'Which connected keyboard plays; every one by default',
      ['controller', 'usb', 'bluetooth', 'input', 'device']),
  _E('midi.channel', _C.midi, 'MIDI channel', 'Listen on every channel or on one of 1 to 16', ['channel', 'omni']),
  _E('midi.velocity', _C.midi, 'Velocity curve', 'How hard you play becomes how loud: Linear, Soft, Hard or Fixed',
      ['velocity', 'dynamics', 'touch', 'sensitivity']),
  _E('midi.thru', _C.midi, 'MIDI thru', 'A keyboard plays the selected track when not recording',
      ['thru', 'through', 'monitor', 'play']),
  _E.more('midi.bluetooth', _C.midi, 'Scan for Bluetooth MIDI', 'Find and connect a Bluetooth LE MIDI keyboard or controller',
      ['bluetooth', 'ble', 'pair', 'wireless']),
  _E.more('midi.fixedVelocity', _C.midi, 'Fixed velocity', 'The velocity every note gets with the Fixed curve',
      ['velocity', 'fixed']),
  _E.more('midi.mpe', _C.midi, 'MPE', 'MIDI Polyphonic Expression: each note on its own channel bends and presses alone',
      ['mpe', 'expression', 'seaboard', 'linnstrument', 'per-note']),
  _E.more('midi.bendRange', _C.midi, 'Pitch bend range', 'Semitones a full pitch bend moves', ['bend', 'wheel', 'range', 'semitones']),
  _E.more('midi.mappings', _C.midi, 'Controller mappings', 'Hardware knobs mapped with Learn MIDI CC; remove them here',
      ['learn', 'cc', 'knob', 'map', 'controller']),
  _E.more('midi.keysVelocity', _C.midi, 'On-screen keys velocity', 'From where a key is touched, or one fixed velocity',
      ['piano', 'pads', 'touch', 'keys']),
  _E.more('midi.keysFixedVelocity', _C.midi, 'On-screen keys fixed velocity', 'The keys\' and pads\' velocity when not by touch',
      ['piano', 'pads', 'velocity']),
  _E.more('midi.keysOctave', _C.midi, 'On-screen keys octave', 'The octave the keys and pads open on', ['piano', 'pads', 'range']),
  _E('editing.follow', _C.arrange, 'Follow the playhead', 'The arrangement scrolls to keep the playhead in view while playing',
      ['auto scroll', 'autoscroll', 'scroll', 'playback']),
  _E('editing.followStyle', _C.arrange, 'Follow style', 'Page: the view jumps on near the edge. Smooth: it scrolls on, the '
      'playhead a third in', ['smooth scroll', 'page', 'follow', 'continuous']),
  _E('editing.confirmDelete', _C.arrange, 'Ask before deleting a track', 'A question before a track or folder goes',
      ['delete', 'confirm', 'remove']),
  _E('editing.rememberZoom', _C.arrange, 'Remember zoom per project', 'Each project reopens at its arrangement\'s zoom and scroll position',
      ['zoom', 'scroll', 'view', 'position', 'project', 'reopen']),
  _E.more('editing.followResume', _C.arrange, 'Resume after',
      'After you scroll, zoom, drag or select, how long the view waits before following again; Never waits for Play',
      ['auto scroll', 'follow', 'pause', 'delay', 'playback']),
  _E.more('editing.wheel', _C.arrange, 'Wheel zooms', 'The mouse wheel zooms the arrangement; Ctrl + wheel then scrolls',
      ['mouse', 'zoom', 'scroll', 'ctrl']),
  _E('tracks.instrument', _C.newTracks, 'New MIDI track instrument', 'What a MIDI track Record makes plays; None leaves it empty',
      ['instrument', 'synth', 'default', 'new track', 'flagship']),
  _E('tracks.colors', _C.newTracks, 'Track colours', 'The next colour for each new track, or one colour per kind (MIDI, audio, sampler, folder)',
      ['colour', 'color', 'new track', 'default', 'kind']),
  _E('tracks.naming', _C.newTracks, 'Track names', 'A new track\'s kind and number (MIDI 3), or its instrument\'s name (Flagship 2)',
      ['name', 'naming', 'new track', 'default', 'rename']),
  _E('editing.grid', _C.roll, 'Piano roll grid', 'The grid the roll opens with', ['snap', 'quantize', 'resolution', '1/16']),
  _E('editing.snap', _C.roll, 'Snap to grid', 'Whether the roll opens with snapping on', ['quantize', 'grid']),
  _E('editing.tool', _C.roll, 'Starting tool', 'Draw (a tap draws a note) or Select (a tap selects)',
      ['tap to draw', 'select', 'pencil', 'tool']),
  _E('editing.noteLength', _C.roll, 'New note length', 'Follow the grid, or always this length', ['note', 'length', 'draw']),
  _E('editing.hearNotes', _C.roll, 'Hear notes while editing', 'Notes sound as you place, move or bend them',
      ['piano roll', 'preview', 'audition']),
  _E.more('editing.keyNames', _C.roll, 'Key names', 'Note names on the roll\'s keyboard: none, C, or all', ['piano roll', 'labels']),
  _E.more('editing.emptyDrag', _C.roll, 'Drag on empty grid', 'With Draw: scroll, select or draw', ['piano roll', 'touch', 'scroll']),
  _E.more('editing.valueGrid', _C.roll, 'Value grid', 'What velocity, chance and timbre snap to', ['piano roll', 'snap']),
  _E.more('editing.rowHeight', _C.roll, 'Row height', 'The piano roll\'s key rows', ['piano roll', 'size']),
  _E.more('editing.velocityLane', _C.roll, 'Velocity lane', 'The roll\'s velocity lane height', ['piano roll', 'size']),
  _E.more('editing.chanceLane', _C.roll, 'Chance lane', 'The roll\'s chance lane height', ['piano roll', 'size', 'probability']),
  _E.more('editing.gridLines', _C.roll, 'Grid lines', 'How strong the roll\'s grid lines are', ['piano roll', 'contrast']),
  _E.more('editing.grab', _C.roll, 'Grab zone', 'How close to a note\'s end a touch resizes it', ['piano roll', 'resize', 'touch']),
  _E.more('editing.hold', _C.roll, 'Hold for extras', 'How long holding a note opens its extras', ['piano roll', 'long press']),
  _E('recording.automation', _C.automation, 'Automation write mode', 'What the transport\'s Automate writes: Touch, Latch, Write or Read',
      ['automate', 'touch', 'latch', 'write', 'read']),
  _E('look.family', _C.theme, 'Theme family', 'Neon, Flat, Dusk, Dawn, Amber or one of your own themes',
      ['colour', 'color', 'palette', 'neon', 'flat', 'dusk', 'dawn', 'amber']),
  _E('look.mode', _C.theme, 'Mode', 'Dark, Light or Follow system: only the palette changes',
      ['dark mode', 'light mode', 'night', 'day', 'system', 'brightness']),
  _E('look.theme', _C.theme, 'Edit theme', 'A whole profile: colours, look, layout and behaviour; edit, import or export',
      ['colour', 'color', 'dark', 'palette', 'profile', 'font', 'corners', 'roundness']),
  _E('look.glass', _C.theme, 'Glass', 'See-through panels over a soft background', ['transparency', 'frosted']),
  _E.more('look.blur', _C.theme, 'Frosted blur', 'Blur behind sheets and menus', ['glass', 'blur', 'performance']),
  _E.more('look.glow', _C.theme, 'Music-reactive glow', 'Clips and headers glow with their track\'s level', ['glow', 'meter', 'neon']),
  _E.more('look.meterFall', _C.theme, 'Meter fall', 'How fast peak meters fall', ['meters', 'peak', 'db']),
  _E('look.layout', _C.layout, 'Layout', 'Auto, Phone or Desktop frame', ['desktop', 'phone', 'tablet', 'dex', 'frame']),
  _E('look.density', _C.layout, 'Density', 'Compact or Comfortable (48 dp touch targets)', ['size', 'compact', 'touch targets']),
  _E('look.leftHanded', _C.layout, 'Left-handed layout', 'The transport\'s buttons and the side rail are mirrored',
      ['left handed', 'lefty', 'mirror', 'transport', 'rail', 'thumb']),
  _E.more('look.trackGap', _C.layout, 'Gap between tracks', 'Space between the arrangement\'s tracks', ['arrange', 'spacing']),
  _E.more('look.headerWidth', _C.layout, 'Track header width', 'The arrangement\'s header width; Default follows the screen',
      ['arrange', 'size', 'width']),
  _E.more('look.trackHeight', _C.layout, 'Track height', 'Every track\'s row height; Default follows the screen', ['arrange', 'size']),
  _E.more('look.focusShare', _C.layout, 'Focus panel width', 'Phone landscape: the focus view\'s side panel share', ['landscape', 'panel']),
  _E('feel.motion', _C.motion, 'Motion', 'Full, Reduced (fades only) or Off (drags, snapping and presses still move)',
      ['animation', 'reduce motion']),
  _E('feel.editStyle', _C.motion, 'Edit animations', 'How edits animate: Subtle or Playful', ['animation', 'style', 'playful']),
  _E.more('feel.edit.notes', _C.motion, 'Animate notes', 'Notes added, deleted and moved', ['animation', 'piano roll']),
  _E.more('feel.edit.clips', _C.motion, 'Animate clips', 'Clips added, deleted and moved', ['animation', 'arrange']),
  _E.more('feel.edit.tracks', _C.motion, 'Animate tracks', 'Tracks added, deleted and reordered', ['animation', 'arrange']),
  _E.more('feel.edit.lengths', _C.motion, 'Animate lengths and sizes', 'Lengths and sizes changing', ['animation', 'resize']),
  _E.more('feel.edit.panels', _C.motion, 'Animate panels', 'Panels, menus, sheets and pages opening', ['animation', 'sheet', 'page']),
  _E.more('feel.startupAnimation', _C.motion, 'Full startup animation',
      'Plays the crow animation to its end; off, it shows only while loading', ['intro', 'splash', 'launch', 'logo']),
  _E('feel.haptics', _C.touch, 'Haptics', 'A light touch on presses, steps, snaps, grabs and drops', ['vibration', 'feedback']),
  _E('feel.hapticStrength', _C.touch, 'Haptic strength', 'How strong the haptics are', ['vibration', 'intensity']),
  _E('feel.longPress', _C.touch, 'Long-press menus', 'A list near the finger, or a ring', ['menu', 'ring', 'context menu']),
  _E.more('feel.quickActions', _C.touch, 'Quick actions bar', 'A floating row of shortcut buttons on a phone', ['shortcuts', 'buttons']),
  _E('projects.autosave', _C.saving, 'Autosave', 'How soon after an edit the project is saved', ['save', 'interval', 'delay']),
  _E('projects.restorePoints', _C.saving, 'Restore points kept', 'How many restore points each project keeps',
      ['history', 'backup', 'versions', 'undo']),
  _E('projects.newStart', _C.newProjects, 'New project starts from', 'Blank, or the Mid tempo template', ['template', 'new']),
  _E('projects.newTempo', _C.newProjects, 'New project tempo', 'A blank project\'s BPM', ['bpm', 'tempo', 'new']),
  _E('projects.newMeter', _C.newProjects, 'New project time signature', 'A blank project\'s beats per bar', ['meter', '4/4', 'beats']),
  _E('projects.generatedNames', _C.newProjects, 'Name new projects', 'Short generated names like "Low Roost" instead of "New project"', ['name', 'untitled', 'generated']),
  _E('export.kind', _C.export, 'Default export', 'What the exporter opens on: loop, free length, one-shot, wavetable or MIDI',
      ['format', 'render', 'wav', 'midi']),
  _E('export.rate', _C.export, 'Export sample rate', '44.1 or 48 kHz', ['khz', 'render']),
  _E('export.depth', _C.export, 'Bit depth', '24-bit PCM or 32-bit float', ['bits', 'float', 'pcm', 'wav']),
  _E.more('export.seconds', _C.export, 'Free length', 'How long a free-length export runs', ['duration', 'seconds', 'tail']),
  _E.more('export.naming', _C.export, 'File names', 'Project, tempo and length; the project alone; or with the date',
      ['name', 'file', 'naming', 'date']),
  _E('projects.storage', _C.storage, 'Storage used', 'What projects, restore points, themes and caches take', ['space', 'disk', 'size']),
  _E('projects.clearCaches', _C.storage, 'Clear caches', 'Deletes temporary renders waiting to be saved', ['cache', 'space', 'temp']),
  _E('performance.profile', _C.performance, 'Performance profile', 'Full Experience, Balanced, Lightweight or Minimal',
      ['battery', 'speed', 'light mode', 'voices']),
  _E('performance.frameRate', _C.performance, 'Frame rate',
      'Auto: the screen\'s highest rate while anything moves, its lowest when still. Or a cap, to save battery',
      ['fps', 'hz', 'refresh rate', '120', '90', '60', '144', '240', 'smooth', 'battery', 'display', 'screen']),
  _E('performance.keepAwake', _C.performance, 'Keep the screen awake', 'Off, While playing (or recording), or Always while C.A.W is in front',
      ['screen', 'sleep', 'awake', 'display', 'timeout', 'lock', 'battery', 'keep on']),
  _E('performance.benchmark', _C.performance, 'Benchmark', 'How much this device can play: tracks, voices and effects, and what takes the time',
      ['stress test', 'test', 'speed', 'cpu', 'tracks', 'voices', 'limits', 'score']),
  _E.more('performance.lightAuto', _C.performance, 'Lightweight on overload', 'Switch to Lightweight by itself when the audio runs out of time',
      ['overload', 'cpu', 'automatic']),
  _E.more('performance.hardware', _C.performance, 'Hardware profile', 'Cores, work-memory budget, SIMD and GPU compute the engine found',
      ['cpu', 'cores', 'memory', 'simd']),
  _E.more('performance.plan', _C.performance, 'Workload plan', 'Workers, jobs and batch size the engine plans for live work',
      ['threads', 'workers', 'jobs']),
  _E('code.autoUpdate', _C.code, 'Auto-update', 'Code swaps in by itself after you stop typing', ['live coding', 'run']),
  _E('code.delay', _C.code, 'Auto-update delay', 'How long after the last key the code swaps in', ['live coding', 'ms']),
  _E('code.swap', _C.code, 'Swap timing', 'When new code takes over: now, on the beat or on the bar', ['live coding', 'quantize']),
  _E('code.fontSize', _C.code, 'Font size', 'The code editors\' text size', ['text', 'size', 'zoom']),
  _E.more('code.tabWidth', _C.code, 'Tab width', 'Spaces per indent in the C++ editor', ['indent', 'spaces', 'tab']),
  _E.more('code.lineNumbers', _C.code, 'Line numbers', 'Numbers in the C++ editor\'s gutter', ['gutter']),
  _E.more('code.wrap', _C.code, 'Wrap long lines', 'The C++ editor wraps instead of scrolling sideways', ['word wrap', 'soft wrap']),
  _E.more('code.solo', _C.code, 'Solo preview button', 'The pattern editor\'s Solo button', ['audition', 'preview']),
  _E.more('code.scope', _C.code, 'Scope', 'The pattern editor\'s oscilloscope', ['oscilloscope', 'waveform']),
  _E.more('code.barOnTop', _C.code, 'Run bar on top', 'The key row and Run above the pattern text', ['layout', 'toolbar']),
  _E('keys.bindings', _C.keys, 'Key bindings', 'Choose what each key does', ['shortcuts', 'keyboard', 'hotkeys']),
  _E('keys.hints', _C.keys, 'Key hints', 'A strip of the keys that work where the keyboard focus is',
      ['which-key', 'hints', 'shortcuts', 'help', 'keyboard']),
  _E('keys.keyRow', _C.keys, 'Key row', 'The symbol keys above the phone keyboard', ['symbols', 'toolbar', 'keyboard']),
  _E.more('keys.vim', _C.keys, 'Vim keys in the code editor', 'With a keyboard: WASD moves, I types, Esc stops typing',
      ['vim', 'modal', 'wasd']),
  _E.more('keys.vimKeys', _C.keys, 'Vim keys everywhere', 'H J K L move like the arrows in effects, mixer, Files and Settings',
      ['vim', 'hjkl', 'arrows', 'navigation']),
  _E('about.beta', _C.about, 'Version', 'The open alpha\'s version', ['version', 'alpha', 'beta', 'build']),
  _E('about.whatsNew', _C.about, 'What\'s new', 'What changed in each version, from 1.0.0 (the changelog)',
      ['changelog', 'changes', 'release notes', 'new', 'history', 'version']),
  _E('about.diagnostics', _C.about, 'Engine diagnostics', 'CPU, peaks, the master scope and spectrum, and signal paths',
      ['engine', 'lab', 'diagnostics', 'cpu', 'scope', 'spectrum', 'debug']),
  _E.more('about.licences', _C.about, 'Licences', 'Open-source licences, JetBrains Mono included', ['license', 'licence', 'open source']),
  _E('about.updates', _C.updates, 'Updates', 'This version, the last check, Check now and Update now',
      ['update', 'upgrade', 'new version', 'release', 'download']),
  _E('about.updates.check', _C.updates, 'Check for updates automatically', 'Once a day at most, after the app has opened',
      ['update', 'check', 'automatic']),
  _E('about.updates.prompts', _C.updates, 'Ask when an update is found', 'A small prompt after the app opens: Update, Not now or Don\'t ask again',
      ['update', 'prompt', 'ask', 'notify']),
  _E.more('about.updates.channel', _C.updates, 'Update channel', 'Stable, Beta or Every change', ['update', 'channel', 'beta', 'stable', 'alpha']),
  _E.more('about.updates.install', _C.updates, 'Install updates automatically', 'Off by default: downloads and installs new releases when the app is idle',
      ['update', 'automatic', 'install', 'background']),
  _E.more('about.updates.versions', _C.updates, 'Install another version…', 'Every release in the channel, older ones too',
      ['downgrade', 'older', 'version', 'rollback', 'release']),
  _E('about.privacy', _C.privacy, 'Privacy', 'Anonymous telemetry on or off, exactly what is sent, My data, the Privacy Policy and Terms',
      ['privacy', 'telemetry', 'analytics', 'tracking', 'data', 'delete', 'receipts', 'my data', 'gdpr', 'policy',
       'terms', 'conditions', 'legal', 'dashboard']),
  _E('about.feedback', _C.privacy, 'Send feedback', 'A bug, an idea, something confusing or praise, posted publicly',
      ['feedback', 'idea', 'suggestion', 'bug', 'praise', 'contact']),
  _E('about.report', _C.privacy, 'Report a problem', 'Copies a report to paste into a new issue', ['bug', 'issue', 'feedback']),
  _E.page('privacy.telemetry', _C.privacy, 'Send anonymous telemetry', 'One report a day about how C.A.W runs, published openly'),
  _E.page('privacy.whatsSent', _C.privacy, 'Show exactly what\'s sent', 'The reports waiting to be sent and today\'s so far, as JSON'),
  _E.page('privacy.myData', _C.privacy, 'My data', 'Your reports: check them on the server, export the receipts, delete them'),
  _E.page('privacy.policy', _C.privacy, 'Privacy Policy', 'What is sent, where it goes and how to delete it (bundled copy)'),
  _E.page('privacy.terms', _C.privacy, 'Terms', 'The beta\'s terms of use (bundled copy)'),
  _E.page('privacy.dashboard', _C.privacy, 'Public dashboard', 'Everything collected, from every device'),
];

/// Ids the settings rework (#244) folded into another, each to the one place it now lives.
const Map<String, String> mergedSettings = {
  'about.policy': 'privacy.policy',
  'about.terms': 'privacy.terms',
  'privacy.feedback': 'about.feedback',
};

/// Settings that exist only on Android (their rows hide elsewhere, so search leaves them out there).
const androidOnlySettings = {'audio.background', 'audio.bufferTuning'};

/// Whether [e]'s row is on its page on this platform and build (the Play build has no Updates rows).
bool settingAvailable(SettingEntry e) =>
    (!androidOnlySettings.contains(e.id) || Platform.isAndroid) && (selfUpdates || !e.id.startsWith('about.updates'));

/// The entries matching [query], grouped by section in page order.
Map<SettingsSection, List<SettingEntry>> searchSettings(String query) {
  final out = <SettingsSection, List<SettingEntry>>{};
  for (final e in settingEntries) {
    if (e.searchable && settingAvailable(e) && e.matches(query)) (out[e.section] ??= []).add(e);
  }
  return out;
}

SettingEntry? settingEntry(String id) => settingEntries.where((e) => e.id == id).firstOrNull;
