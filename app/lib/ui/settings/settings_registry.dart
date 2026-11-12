// Every setting's id, section, title, description and search words, so Settings' search finds any of them.
import 'package:flutter/material.dart';

import '../../model/settings.dart';
import '../../model/templates.dart' show templateLabel;
import '../../version.dart';
import '../motion.dart';
import '../theme.dart';

/// The Settings sections, in the category list's order.
enum SettingsSection {
  audio('Audio', Icons.speaker_outlined),
  midi('MIDI and input', Icons.piano_outlined),
  recording('Metronome and recording', Icons.fiber_manual_record_outlined),
  editing('Editing', Icons.edit_note),
  code('Code editor', Icons.code),
  look('Look', Icons.palette_outlined),
  feel('Feel', Icons.vibration),
  performance('Performance', Icons.speed),
  projects('Projects and files', Icons.folder_outlined),
  export('Export', Icons.ios_share),
  keys('Keys and shortcuts', Icons.keyboard_alt_outlined),
  about('About and beta', Icons.info_outline);

  const SettingsSection(this.title, this.icon);
  final String title;
  final IconData icon;

  /// The section's accent, cycling through the theme's neon colours.
  Color get color => [Neon.green, Neon.blue, Neon.pink, Neon.yellow, Neon.violet][index % 5];

  /// One line of the section's current values, for the category list.
  String summary(Settings s) {
    String rate(int r) => '${(r / 1000).toStringAsFixed(r % 1000 == 0 ? 0 : 1)} kHz';
    return switch (this) {
      audio => [
          s.audioDevice.isEmpty ? 'System default' : s.audioDevice,
          rate(s.sampleRate),
          s.bufferFrames == 0 ? 'buffer ${s.audioBuffer.label}' : '${s.bufferFrames} frames',
          s.soundQuality.label,
        ].join(' · '),
      midi => [
          s.midiDevice.isEmpty ? 'Every keyboard' : s.midiDevice,
          s.midiChannel == 0 ? 'all channels' : 'channel ${s.midiChannel}',
          s.velocityCurve.label,
        ].join(' · '),
      recording => [
          switch (s.metronome) {
            Metronome.off => 'Click off',
            Metronome.recording => 'Click while recording',
            Metronome.always => 'Click always',
          },
          s.countInBars == 0 ? 'no count-in' : '${s.countInBars}-bar count-in',
          if (s.preRollBars > 0) '${s.preRollBars}-bar pre-roll',
        ].join(' · '),
      editing => [
          'Grid 1/${s.rollGrid}',
          s.rollSnap ? 'snap on' : 'snap off',
          s.rollTool.label,
          if (s.followPlayhead) 'follows the playhead',
        ].join(' · '),
      code => [
          s.liveUpdate ? 'Auto-update ${s.liveDelayMs} ms' : 'Auto-update off',
          '${s.codeFontSize.round()} pt',
          if (s.vimCode) 'Vim',
        ].join(' · '),
      look => [s.themeName, s.lookMode.label, s.compact ? 'Compact' : 'Comfortable', s.layoutMode.label].join(' · '),
      feel => [
          'Motion ${s.motion.name}',
          if (s.motion != MotionLevel.off) 'edits ${s.editMotionStyle.label}',
          s.haptics ? 'haptics ${(s.hapticStrength * 100).round()}%' : 'haptics off',
        ].join(' · '),
      performance => [s.performanceMode.label, if (s.lightAuto) 'auto Lightweight'].join(' · '),
      projects => [
          'Autosave ${s.autosaveMs < 1000 ? '${s.autosaveMs} ms' : '${s.autosaveMs ~/ 1000} s'}',
          '${s.restorePointsKept} restore points',
          'new: ${templateLabel(s.newProjectTemplate)}',
        ].join(' · '),
      export => [
          exportKindLabel(s.exportKind),
          rate(s.exportSampleRate),
          s.exportFloat32 ? '32-bit float' : '24-bit',
        ].join(' · '),
      keys => [s.vimCode ? 'Vim keys on' : 'Vim keys off', '${s.editor.keyRow.length} keys in the row'].join(' · '),
      about => 'Version $appVersion · open beta',
    };
  }
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
  const SettingEntry(this.id, this.section, this.title, this.description, [this.keywords = const []]);
  final String id;
  final SettingsSection section;
  final String title, description;
  final List<String> keywords;

  /// Whether every word of [query] is in the title, description, keywords or section name.
  bool matches(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (words.isEmpty) return false;
    final text = '$title $description ${keywords.join(' ')} ${section.title}'.toLowerCase();
    return words.every(text.contains);
  }
}

typedef _E = SettingEntry;
const _a = SettingsSection.audio, _m = SettingsSection.midi, _r = SettingsSection.recording,
    _ed = SettingsSection.editing, _c = SettingsSection.code, _l = SettingsSection.look, _f = SettingsSection.feel,
    _p = SettingsSection.performance, _pr = SettingsSection.projects, _x = SettingsSection.export,
    _k = SettingsSection.keys, _ab = SettingsSection.about;

/// Every setting on every page, in page order.
const List<SettingEntry> settingEntries = [
  _E('audio.status', _a, 'Device now', 'What the audio device runs at: backend, device, rate, buffer and latency',
      ['latency', 'ms', 'running', 'backend', 'aaudio', 'wasapi']),
  _E('audio.device', _a, 'Output device', 'Where the sound plays; the system default follows the phone',
      ['speaker', 'headphones', 'usb', 'interface', 'output', 'sound card']),
  _E('audio.rate', _a, 'Sample rate', 'The rate the engine runs at: 44.1, 48, 88.2 or 96 kHz',
      ['khz', 'hz', 'quality', '44100', '48000', '96000']),
  _E('audio.buffer', _a, 'Buffer size', 'The callback size in frames, down to the smallest the device gives',
      ['latency', 'frames', 'period', 'samples', 'ms', 'delay']),
  _E('audio.mode', _a, 'Buffer mode', 'Auto, Low latency or Battery: the size and power path when Buffer size is Auto',
      ['latency', 'battery', 'power', 'low latency', 'mmap']),
  _E('audio.exclusive', _a, 'Exclusive mode', 'Take the device for C.A.W alone: AAudio exclusive, WASAPI exclusive',
      ['latency', 'mmap', 'wasapi', 'aaudio', 'low latency', 'exclusive']),
  _E('audio.quality', _a, 'Sound quality', 'Eco, Normal or High: oversampling, unison copies and reverb density',
      ['eco', 'battery', 'oversampling', 'cpu']),
  _E('audio.background', _a, 'Background playback', 'Whether Android restricts C.A.W\'s battery behind other apps (Android)',
      ['battery', 'unrestricted', 'background', 'optimization', 'samsung', 'sleep']),
  _E('audio.test', _a, 'Test tone', 'Plays 440 Hz for a moment to check the output', ['beep', 'sine', 'check', 'a4']),
  _E('audio.input', _a, 'Audio input', 'Record and monitor audio tracks: asks for the microphone the first time',
      ['microphone', 'mic', 'record', 'input', 'interface', 'permission']),
  _E('audio.inputDevice', _a, 'Input device', 'Where audio tracks record from', ['microphone', 'usb', 'interface', 'capture']),
  _E('audio.inputChannels', _a, 'Input channels', 'How many of the device\'s channels open (tracks pick theirs)',
      ['mono', 'stereo', 'channels']),
  _E('audio.latency', _a, 'Measure recording latency', 'A short noise burst finds the round trip, so takes land in time',
      ['latency', 'ping', 'calibrate', 'offset', 'delay', 'loopback']),
  _E('audio.latencyOffset', _a, 'Recording offset', 'The round trip typed in, in milliseconds (instead of the measured one)',
      ['latency', 'offset', 'delay', 'manual', 'compensation']),
  _E('audio.outputLatency', _a, 'Latency', 'How late Bluetooth, USB or HDMI output and the microphone are, per device',
      ['bluetooth', 'delay', 'late', 'offset', 'compensation', 'a2dp', 'headphones', 'calibrate', 'tap along',
       'loopback', 'microphone', 'sync', 'playhead', 'meters']),
  _E('audio.punch', _a, 'Punch in and out', 'Record only over the loop range or the time selection',
      ['punch', 'loop', 'selection', 'range']),
  _E('audio.recordFormat', _a, 'Recording format', '32-bit float or 24-bit WAV takes', ['wav', 'bits', 'float', 'format']),
  _E('midi.devices', _m, 'MIDI devices', 'The connected keyboards and pad controllers: on or off, and a light as each plays',
      ['usb', 'bluetooth', 'controller', 'pads', 'keyboard', 'device', 'connect']),
  _E('midi.bluetooth', _m, 'Scan for Bluetooth MIDI', 'Find and connect a Bluetooth LE MIDI keyboard or controller',
      ['bluetooth', 'ble', 'pair', 'wireless']),
  _E('midi.mpe', _m, 'MPE', 'MIDI Polyphonic Expression: each note on its own channel bends and presses alone',
      ['mpe', 'expression', 'seaboard', 'linnstrument', 'per-note']),
  _E('midi.bendRange', _m, 'Pitch bend range', 'Semitones a full pitch bend moves', ['bend', 'wheel', 'range', 'semitones']),
  _E('midi.mappings', _m, 'Controller mappings', 'Hardware knobs mapped with Learn MIDI CC; remove them here',
      ['learn', 'cc', 'knob', 'map', 'controller']),
  _E('midi.device', _m, 'MIDI keyboard', 'Which connected keyboard plays; every one by default',
      ['controller', 'usb', 'bluetooth', 'input', 'device']),
  _E('midi.channel', _m, 'MIDI channel', 'Listen on every channel or on one of 1 to 16', ['channel', 'omni']),
  _E('midi.velocity', _m, 'Velocity curve', 'How hard you play becomes how loud: Linear, Soft, Hard or Fixed',
      ['velocity', 'dynamics', 'touch', 'sensitivity']),
  _E('midi.fixedVelocity', _m, 'Fixed velocity', 'The velocity every note gets with the Fixed curve',
      ['velocity', 'fixed']),
  _E('midi.thru', _m, 'MIDI thru', 'A keyboard plays the selected track when not recording',
      ['thru', 'through', 'monitor', 'play']),
  _E('midi.keysVelocity', _m, 'On-screen keys velocity', 'From where a key is touched, or one fixed velocity',
      ['piano', 'pads', 'touch', 'keys']),
  _E('midi.keysFixedVelocity', _m, 'On-screen keys fixed velocity', 'The keys\' and pads\' velocity when not by touch',
      ['piano', 'pads', 'velocity']),
  _E('midi.keysOctave', _m, 'On-screen keys octave', 'The octave the keys and pads open on', ['piano', 'pads', 'range']),
  _E('recording.metronome', _r, 'Metronome', 'Off, click while recording, or click whenever playing',
      ['click', 'beat', 'tempo']),
  _E('recording.clickSound', _r, 'Click sound', 'Classic, Wood or Tick', ['metronome', 'beep', 'sound']),
  _E('recording.clickVolume', _r, 'Click volume', 'How loud the metronome and count-in click', ['metronome', 'level']),
  _E('recording.countIn', _r, 'Count-in', 'Bars of clicks before a recording starts from a stop', ['metronome', 'bars']),
  _E('recording.preRoll', _r, 'Pre-roll', 'Bars played before the record point; heard, not recorded',
      ['punch', 'bars', 'lead in']),
  _E('recording.offset', _r, 'Recording offset', 'Writes played notes this much earlier, for the output delay',
      ['latency', 'compensation', 'delay', 'ms', 'timing']),
  _E('recording.automation', _r, 'Automation write mode', 'What the transport\'s Automate writes: Touch, Latch, Write or Read',
      ['automate', 'touch', 'latch', 'write', 'read']),
  _E('editing.grid', _ed, 'Piano roll grid', 'The grid the roll opens with', ['snap', 'quantize', 'resolution', '1/16']),
  _E('editing.snap', _ed, 'Snap to grid', 'Whether the roll opens with snapping on', ['quantize', 'grid']),
  _E('editing.tool', _ed, 'Starting tool', 'Draw (a tap draws a note) or Select (a tap selects)',
      ['tap to draw', 'select', 'pencil', 'tool']),
  _E('editing.noteLength', _ed, 'New note length', 'Follow the grid, or always this length', ['note', 'length', 'draw']),
  _E('editing.follow', _ed, 'Follow the playhead', 'The arrangement scrolls to keep the playhead in view while playing',
      ['auto scroll', 'autoscroll', 'scroll', 'playback']),
  _E('editing.followStyle', _ed, 'Follow style', 'Page: the view jumps on near the edge. Smooth: it scrolls on, the '
      'playhead a third in', ['smooth scroll', 'page', 'follow', 'continuous']),
  _E('editing.followResume', _ed, 'Resume after',
      'After you scroll, zoom, drag or select, how long the view waits before following again; Never waits for Play',
      ['auto scroll', 'follow', 'pause', 'delay', 'playback']),
  _E('editing.wheel', _ed, 'Wheel zooms', 'The mouse wheel zooms the arrangement; Ctrl + wheel then scrolls',
      ['mouse', 'zoom', 'scroll', 'ctrl']),
  _E('editing.confirmDelete', _ed, 'Ask before deleting a track', 'A question before a track or folder goes',
      ['delete', 'confirm', 'remove']),
  _E('editing.rowHeight', _ed, 'Row height', 'The piano roll\'s key rows', ['piano roll', 'size']),
  _E('editing.velocityLane', _ed, 'Velocity lane', 'The roll\'s velocity lane height', ['piano roll', 'size']),
  _E('editing.chanceLane', _ed, 'Chance lane', 'The roll\'s chance lane height', ['piano roll', 'size', 'probability']),
  _E('editing.gridLines', _ed, 'Grid lines', 'How strong the roll\'s grid lines are', ['piano roll', 'contrast']),
  _E('editing.grab', _ed, 'Grab zone', 'How close to a note\'s end a touch resizes it', ['piano roll', 'resize', 'touch']),
  _E('editing.hold', _ed, 'Hold for extras', 'How long holding a note opens its extras', ['piano roll', 'long press']),
  _E('editing.keyNames', _ed, 'Key names', 'Note names on the roll\'s keyboard: none, C, or all', ['piano roll', 'labels']),
  _E('editing.emptyDrag', _ed, 'Drag on empty grid', 'With Draw: scroll, select or draw', ['piano roll', 'touch', 'scroll']),
  _E('editing.valueGrid', _ed, 'Value grid', 'What velocity, chance and timbre snap to', ['piano roll', 'snap']),
  _E('editing.hearNotes', _ed, 'Hear notes while editing', 'Notes sound as you place, move or bend them',
      ['piano roll', 'preview', 'audition']),
  _E('code.autoUpdate', _c, 'Auto-update', 'Code swaps in by itself after you stop typing', ['live coding', 'run']),
  _E('code.delay', _c, 'Auto-update delay', 'How long after the last key the code swaps in', ['live coding', 'ms']),
  _E('code.swap', _c, 'Swap timing', 'When new code takes over: now, on the beat or on the bar', ['live coding', 'quantize']),
  _E('code.fontSize', _c, 'Font size', 'The code editors\' text size', ['text', 'size', 'zoom']),
  _E('code.tabWidth', _c, 'Tab width', 'Spaces per indent in the C++ editor', ['indent', 'spaces', 'tab']),
  _E('code.lineNumbers', _c, 'Line numbers', 'Numbers in the C++ editor\'s gutter', ['gutter']),
  _E('code.wrap', _c, 'Wrap long lines', 'The C++ editor wraps instead of scrolling sideways', ['word wrap', 'soft wrap']),
  _E('code.solo', _c, 'Solo preview button', 'The pattern editor\'s Solo button', ['audition', 'preview']),
  _E('code.scope', _c, 'Scope', 'The pattern editor\'s oscilloscope', ['oscilloscope', 'waveform']),
  _E('code.barOnTop', _c, 'Run bar on top', 'The key row and Run above the pattern text', ['layout', 'toolbar']),
  _E('look.family', _l, 'Theme family', 'Neon, Flat, Dusk, Dawn, Amber or one of your own themes',
      ['colour', 'color', 'palette', 'neon', 'flat', 'dusk', 'dawn', 'amber']),
  _E('look.mode', _l, 'Mode', 'Dark, Light or Follow system: only the palette changes',
      ['dark mode', 'light mode', 'night', 'day', 'system', 'brightness']),
  _E('look.theme', _l, 'Edit theme', 'A whole profile: colours, look, layout and behaviour; edit, import or export',
      ['colour', 'color', 'dark', 'palette', 'profile', 'font', 'corners', 'roundness']),
  _E('look.density', _l, 'Density', 'Compact or Comfortable (48 dp touch targets)', ['size', 'compact', 'touch targets']),
  _E('look.layout', _l, 'Layout', 'Auto, Phone or Desktop frame', ['desktop', 'phone', 'tablet', 'dex', 'frame']),
  _E('look.glass', _l, 'Glass', 'See-through panels over a soft background', ['transparency', 'frosted']),
  _E('look.blur', _l, 'Frosted blur', 'Blur behind sheets and menus', ['glass', 'blur', 'performance']),
  _E('look.glow', _l, 'Music-reactive glow', 'Clips and headers glow with their track\'s level', ['glow', 'meter', 'neon']),
  _E('look.meterFall', _l, 'Meter fall', 'How fast peak meters fall', ['meters', 'peak', 'db']),
  _E('look.trackGap', _l, 'Gap between tracks', 'Space between the arrangement\'s tracks', ['arrange', 'spacing']),
  _E('look.headerWidth', _l, 'Track header width', 'The arrangement\'s header width; Default follows the screen',
      ['arrange', 'size', 'width']),
  _E('look.trackHeight', _l, 'Track height', 'Every track\'s row height; Default follows the screen', ['arrange', 'size']),
  _E('look.focusShare', _l, 'Focus panel width', 'Phone landscape: the focus view\'s side panel share', ['landscape', 'panel']),
  _E('feel.motion', _f, 'Motion', 'Full, Reduced (fades only) or Off (drags, snapping and presses still move)',
      ['animation', 'reduce motion']),
  _E('feel.editStyle', _f, 'Edit animations', 'How edits animate: Subtle or Playful', ['animation', 'style', 'playful']),
  _E('feel.edit.notes', _f, 'Animate notes', 'Notes added, deleted and moved', ['animation', 'piano roll']),
  _E('feel.edit.clips', _f, 'Animate clips', 'Clips added, deleted and moved', ['animation', 'arrange']),
  _E('feel.edit.tracks', _f, 'Animate tracks', 'Tracks added, deleted and reordered', ['animation', 'arrange']),
  _E('feel.edit.lengths', _f, 'Animate lengths and sizes', 'Lengths and sizes changing', ['animation', 'resize']),
  _E('feel.edit.panels', _f, 'Animate panels', 'Panels, menus, sheets and pages opening', ['animation', 'sheet', 'page']),
  _E('feel.haptics', _f, 'Haptics', 'A light touch on presses, steps, snaps, grabs and drops', ['vibration', 'feedback']),
  _E('feel.hapticStrength', _f, 'Haptic strength', 'How strong the haptics are', ['vibration', 'intensity']),
  _E('feel.quickActions', _f, 'Quick actions bar', 'A floating row of shortcut buttons on a phone', ['shortcuts', 'buttons']),
  _E('feel.longPress', _f, 'Long-press menus', 'A list near the finger, or a ring', ['menu', 'ring', 'context menu']),
  _E('performance.profile', _p, 'Performance profile', 'Full Experience, Balanced, Lightweight or Minimal',
      ['battery', 'speed', 'light mode', 'voices']),
  _E('performance.lightAuto', _p, 'Lightweight on overload', 'Switch to Lightweight by itself when the audio runs out of time',
      ['overload', 'cpu', 'automatic']),
  _E('performance.frameRate', _p, 'Frame rate',
      'Auto: the screen\'s highest rate while anything moves, its lowest when still. Or a cap, to save battery',
      ['fps', 'hz', 'refresh rate', '120', '90', '60', '144', '240', 'smooth', 'battery', 'display', 'screen']),
  _E('performance.hardware', _p, 'Hardware profile', 'Cores, work-memory budget, SIMD and GPU compute the engine found',
      ['cpu', 'cores', 'memory', 'simd']),
  _E('performance.plan', _p, 'Workload plan', 'Workers, jobs and batch size the engine plans for live work',
      ['threads', 'workers', 'jobs']),
  _E('projects.autosave', _pr, 'Autosave', 'How soon after an edit the project is saved', ['save', 'interval', 'delay']),
  _E('projects.restorePoints', _pr, 'Restore points kept', 'How many restore points each project keeps',
      ['history', 'backup', 'versions', 'undo']),
  _E('projects.newStart', _pr, 'New project starts from', 'Blank, or the Mid tempo template', ['template', 'new']),
  _E('projects.newTempo', _pr, 'New project tempo', 'A blank project\'s BPM', ['bpm', 'tempo', 'new']),
  _E('projects.newMeter', _pr, 'New project time signature', 'A blank project\'s beats per bar', ['meter', '4/4', 'beats']),
  _E('projects.storage', _pr, 'Storage used', 'What projects, restore points, themes and caches take', ['space', 'disk', 'size']),
  _E('projects.clearCaches', _pr, 'Clear caches', 'Deletes temporary renders waiting to be saved', ['cache', 'space', 'temp']),
  _E('export.kind', _x, 'Default export', 'What the exporter opens on: loop, free length, one-shot, wavetable or MIDI',
      ['format', 'render', 'wav', 'midi']),
  _E('export.rate', _x, 'Export sample rate', '44.1 or 48 kHz', ['khz', 'render']),
  _E('export.depth', _x, 'Bit depth', '24-bit PCM or 32-bit float', ['bits', 'float', 'pcm', 'wav']),
  _E('export.seconds', _x, 'Free length', 'How long a free-length export runs', ['duration', 'seconds', 'tail']),
  _E('export.naming', _x, 'File names', 'Project, tempo and length; the project alone; or with the date',
      ['name', 'file', 'naming', 'date']),
  _E('keys.bindings', _k, 'Key bindings', 'Choose what each key does', ['shortcuts', 'keyboard', 'hotkeys']),
  _E('keys.vim', _k, 'Vim keys in the code editor', 'With a keyboard: WASD moves, I types, Esc stops typing',
      ['vim', 'modal', 'wasd']),
  _E('keys.hints', _k, 'Key hints', 'A strip of the keys that work where the keyboard focus is',
      ['which-key', 'hints', 'shortcuts', 'help', 'keyboard']),
  _E('keys.vimKeys', _k, 'Vim keys everywhere', 'H J K L move like the arrows in effects, mixer, Files and Settings',
      ['vim', 'hjkl', 'arrows', 'navigation']),
  _E('keys.keyRow', _k, 'Key row', 'The symbol keys above the phone keyboard', ['symbols', 'toolbar', 'keyboard']),
  _E('about.beta', _ab, 'Version', 'The open beta\'s version', ['version', 'beta', 'build']),
  _E('about.report', _ab, 'Report a problem', 'Copies a report to paste into a new issue', ['bug', 'issue', 'feedback']),
  _E('about.diagnostics', _ab, 'Engine diagnostics', 'CPU, peaks, the master scope and spectrum, and signal paths',
      ['engine', 'lab', 'diagnostics', 'cpu', 'scope', 'spectrum', 'debug']),
  _E('about.licences', _ab, 'Licences', 'Open-source licences, JetBrains Mono included', ['license', 'licence', 'open source']),
];

/// The entries matching [query], grouped by section in page order.
Map<SettingsSection, List<SettingEntry>> searchSettings(String query) {
  final out = <SettingsSection, List<SettingEntry>>{};
  for (final e in settingEntries) {
    if (e.matches(query)) (out[e.section] ??= []).add(e);
  }
  return out;
}

SettingEntry? settingEntry(String id) => settingEntries.where((e) => e.id == id).firstOrNull;
