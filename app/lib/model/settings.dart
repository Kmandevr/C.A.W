// App-wide settings (audio, MIDI, recording, editing, look, projects, export) saved as settings.json, plus themes/
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../ui/code_prefs.dart';
import '../ui/glass.dart';
import '../ui/haptics.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart' show PeakMeter;

enum Density { comfortable, compact }

/// The frame (owner, 2026-11-10): Auto (the desktop frame on a big window: DeX, an external display, a tablet),
/// Phone (always the phone frame) or Desktop (the rail, docking panels and floating windows, even on a phone).
enum LayoutMode {
  auto('Auto'),
  phone('Phone'),
  desktop('Desktop');

  const LayoutMode(this.label);
  final String label;
}

/// How a long-press menu opens (owner, 2026-11-09): a compact list near the finger, or a Bitwig-style ring.
enum LongPressMenuStyle { list, ring }

/// When a code change swaps into the playing sound.
enum SwapTiming { now, beat, bar }

enum PerformanceMode { fullExperience, balanced, lightweight, minimal }

extension PerformanceModeDetails on PerformanceMode {
  String get label => switch (this) {
    PerformanceMode.fullExperience => 'Full Experience',
    PerformanceMode.balanced => 'Balanced',
    PerformanceMode.lightweight => 'Lightweight',
    PerformanceMode.minimal => 'Minimal',
  };

  String get description => switch (this) {
    PerformanceMode.fullExperience => 'All visual features and full-strength active glow.',
    PerformanceMode.balanced => 'Reduced decorative glow with full editing and meter responsiveness.',
    PerformanceMode.lightweight => 'No decorative glow and a smaller voice budget; editing and meters stay responsive.',
    PerformanceMode.minimal => 'Minimal visual effects and no scope panels; audio and editing responsiveness are preserved.',
  };
}

int _settingInt(Object? value, int fallback) => value is num ? value.toInt() : fallback;
double _settingDouble(Object? value, double fallback) => value is num ? value.toDouble() : fallback;
String _settingText(Object? value, int maxLength) {
  if (value is! String) return '';
  return value.substring(0, value.length > maxLength ? maxLength : value.length);
}

class ExportProfile {
  const ExportProfile({
    required this.name,
    required this.kind,
    this.sampleRate = 48000,
    this.float32 = false,
    this.seconds = 8,
    this.frames = 64,
  });

  final String name, kind;
  final int sampleRate, frames;
  final bool float32;
  final double seconds;

  Map<String, dynamic> toJson() => {
    'name': name, 'kind': kind, 'sample_rate': sampleRate,
    'float32': float32, 'seconds': seconds, 'frames': frames,
  };

  static ExportProfile? fromJson(Object? raw) {
    if (raw is! Map || raw['name'] is! String || raw['kind'] is! String) return null;
    final name = (raw['name'] as String).trim();
    final kind = raw['kind'] as String;
    if (name.isEmpty || name.length > 64 ||
        !const {'loop', 'free', 'oneShot', 'wavetable', 'midi'}.contains(kind)) {
      return null;
    }
    final rate = _settingInt(raw['sample_rate'], 48000);
    final frames = _settingInt(raw['frames'], 64);
    return ExportProfile(
      name: name,
      kind: kind,
      sampleRate: rate == 44100 ? 44100 : 48000,
      float32: raw['float32'] == true,
      seconds: _settingDouble(raw['seconds'], 8).clamp(1.0, 120.0).toDouble(),
      frames: const [1, 8, 16, 32, 64, 128, 256].contains(frames) ? frames : 64,
    );
  }
}

class ExportHistoryEntry {
  const ExportHistoryEntry({
    required this.fileName,
    required this.kind,
    required this.createdAtMs,
    this.sampleRate = 48000,
    this.float32 = false,
    this.seconds = 8,
    this.frames = 64,
    this.target = '',
    this.param = '',
  });

  final String fileName, kind, target, param;
  final int createdAtMs, sampleRate, frames;
  final bool float32;
  final double seconds;

  Map<String, dynamic> toJson() => {
    'file_name': fileName, 'kind': kind, 'created_at_ms': createdAtMs,
    'sample_rate': sampleRate, 'float32': float32, 'seconds': seconds, 'frames': frames,
    'target_id': target, 'param': param,
  };

  static ExportHistoryEntry? fromJson(Object? raw) {
    if (raw is! Map || raw['file_name'] is! String || raw['kind'] is! String ||
        raw['created_at_ms'] is! num) {
      return null;
    }
    final fileName = (raw['file_name'] as String).trim();
    final kind = raw['kind'] as String;
    if (fileName.isEmpty || fileName.length > 160 ||
        !const {'loop', 'free', 'oneShot', 'wavetable', 'midi'}.contains(kind)) {
      return null;
    }
    final rate = _settingInt(raw['sample_rate'], 48000);
    final frames = _settingInt(raw['frames'], 64);
    return ExportHistoryEntry(
      fileName: fileName,
      kind: kind,
      createdAtMs: (raw['created_at_ms'] as num).toInt().clamp(0, 4102444800000).toInt(),
      sampleRate: rate == 44100 ? 44100 : 48000,
      float32: raw['float32'] == true,
      seconds: _settingDouble(raw['seconds'], 8).clamp(1.0, 120.0).toDouble(),
      frames: const [1, 8, 16, 32, 64, 128, 256].contains(frames) ? frames : 64,
      target: _settingText(raw['target_id'], 128),
      param: _settingText(raw['param'], 128),
    );
  }
}

/// When the metronome clicks: never, while recording (and its count-in), or whenever the song plays.
enum Metronome { off, recording, always }

/// What a MIDI recording does where the track already has clips (REAPER's record modes, UG 3.32): a new clip whose
/// loop passes are takes, notes added into the clips there (overdub), or the notes there replaced over the time
/// recorded (replace).
enum MidiRecordMode {
  takes('New clip, takes'),
  overdub('Overdub'),
  replace('Replace');

  const MidiRecordMode(this.label);
  final String label;
}

/// Sound quality (owner, 2026-11-10), in the engine's order (CAW_QUALITY_*): Eco spends less on oversampling,
/// unison copies, reverb density and display updates; High oversamples the saturator further.
enum SoundQuality { eco, normal, high }

/// The device buffer (owner, 2026-11-10), in the engine's order (CAW_BUFFER_*): Auto uses a larger one while not
/// recording (fewer wake-ups, less battery), Low latency always the smallest, Battery always the larger.
enum AudioBuffer { auto, lowLatency, battery }

/// The metronome's click, in the engine's order (CAW_CLICK_*).
enum ClickSound {
  classic('Classic'),
  wood('Wood'),
  tick('Tick');

  const ClickSound(this.label);
  final String label;
}

/// How a MIDI keyboard's velocity becomes a note's: as played, softer touches louder (Soft), harder needed (Hard),
/// or always [Settings.midiFixedVelocity].
enum VelocityCurve {
  linear('Linear'),
  soft('Soft'),
  hard('Hard'),
  fixed('Fixed');

  const VelocityCurve(this.label);
  final String label;

  /// [v] (0..1) through the curve.
  double apply(double v, double fixed) => switch (this) {
        VelocityCurve.linear => v,
        VelocityCurve.soft => math.sqrt(v.clamp(0.0, 1.0)),
        VelocityCurve.hard => v * v,
        VelocityCurve.fixed => fixed,
      };
}

/// What New project starts from: an empty project, or the First loop template.
/// How the exporter names a file: project, tempo and length (the default), the project alone, or the project and
/// the date and time.
enum ExportNaming {
  detailed('Project, tempo, length'),
  project('Project only'),
  dated('Project, date and time');

  const ExportNaming(this.label);
  final String label;
}

/// The piano roll's tool when it opens.
enum StartTool {
  draw('Draw'),
  select('Select');

  const StartTool(this.label);
  final String label;
}

class Settings extends ChangeNotifier {
  /// Settings kept in [dir] (settings.json and themes/); with no folder they live in memory only.
  Settings({this.dir}) {
    Neon.active = activeTheme;
    _applyPerformanceMode();
  }

  final Directory? dir;

  String themeName = calmNeon.name;
  Density density = Density.compact; // owner, 2026-11-09: compact, not oversized

  /// Live coding: code swaps in by itself [liveDelayMs] after the last edit, at [swapTiming].
  bool liveUpdate = true;
  int liveDelayMs = 400;
  SwapTiming swapTiming = SwapTiming.now;

  /// Legacy compatibility: true for Lightweight/Minimal profiles. [lightAuto] selects Lightweight after overload.
  PerformanceMode performanceMode = PerformanceMode.balanced;
  bool get lightMode => performanceMode == PerformanceMode.lightweight || performanceMode == PerformanceMode.minimal;
  set lightMode(bool value) => performanceMode = value ? PerformanceMode.lightweight : PerformanceMode.balanced;
  bool lightAuto = true;

  void _applyPerformanceMode() {
    Neon.performanceMode = performanceMode.index;
    Neon.light = lightMode;
    Neon.showScopes = performanceMode != PerformanceMode.minimal;
    Motion.setting = motion;
    Motion.haptics = haptics;
    Haptics.strength = hapticStrength;
    Glass.enabled = glass;
    Glass.blurEnabled = glassBlur;
    Motion.minimalProfile = performanceMode == PerformanceMode.minimal;
    PeakMeter.fallDbPerSecond = meterFall;
    CodePrefs.fontSize = codeFontSize;
    CodePrefs.tabWidth = codeTabWidth;
    CodePrefs.lineNumbers = codeLineNumbers;
    CodePrefs.wrap = codeWrap;
  }

  /// Motion (owner, 2026-11-04): Full, Reduced (fades only) or Off. Minimal and the system setting lower it further.
  MotionLevel motion = MotionLevel.full;

  /// Haptics on every touch, step and drag; on by default (owner).
  bool haptics = true;

  /// How strong the haptics are, 0 to 1 (owner, 2026-11-10: "a little bit more, just barely"; 0.5 is the base).
  double hapticStrength = 0.5;

  /// Which frame the app uses (owner, 2026-11-10): Auto picks the desktop frame on a big enough window.
  LayoutMode layoutMode = LayoutMode.auto;

  /// Phone landscape: the focus view's side panel's share of the width (owner, 2026-11-10: resizable, 2/3).
  double focusPanelShare = defaultFocusPanelShare;
  static const defaultFocusPanelShare = 2 / 3, minFocusPanelShare = 0.3, maxFocusPanelShare = 0.8;

  /// The docking layouts by screen shape (`phonePortrait`, `phoneLandscape`, `desktop`), kept as raw JSON: the dock
  /// reads them and falls back to a preset when one is missing or damaged.
  Map<String, Object?> dockLayouts = {};

  /// The gap between tracks in the arrangement, in logical pixels (owner, 2026-11-04: tracks shouldn't sit on top
  /// of each other with no room).
  double trackGap = 6;
  static const maxTrackGap = 24.0;

  /// Arrange's track header width and track row height in logical pixels, dragged from the header's right edge and
  /// a row's bottom edge (owner, 2026-11-10: narrower, thinner headers); 0 uses the screen's default.
  double headerWidth = 0, trackHeight = 0;
  static const minHeaderWidth = 96.0, maxHeaderWidth = 320.0;
  static const minTrackHeight = 40.0, maxTrackHeight = 160.0;

  /// How fast peak meters fall, in dB per second (owner, 2026-11-10: faster than the old 24, still smooth).
  double meterFall = 96;
  static const meterFalls = [48.0, 96.0, 144.0, 192.0];

  /// Long-press menus on tracks, clips and effects: a list by default, a ring as a choice.
  LongPressMenuStyle longPressMenu = LongPressMenuStyle.list;

  /// Frosted blur on floating surfaces while glass is on; off keeps the glass look with no blur (much cheaper).
  bool glassBlur = true;

  /// The phone's floating quick-actions bar (owner, 2026-11-04: not very useful yet, so off by default).
  bool quickActions = false;

  /// Glass surfaces (owner, 2026-11-04): frosted blur on floating things, a glass look on panels; on by default.
  bool glass = true;

  /// How strongly clips and track headers glow with their track's level: 0 is off, 1 is strong; subtle by default.
  double reactiveGlow = 0.35;

  /// Vim editing in the code editor (WASD moves; I types). Off by default.
  bool vimCode = false;

  /// Recording (owner, 2026-11-10): when the metronome clicks, and how many bars the count-in has (0: none).
  Metronome metronome = Metronome.recording;
  int countInBars = 1;

  /// The transport's Automate button's write mode ('touch', 'latch', 'write', 'read'; owner, 2026-11-10: Touch).
  String automationMode = 'touch';

  /// Sound quality and the device buffer (owner, 2026-11-10).
  SoundQuality soundQuality = SoundQuality.normal;
  AudioBuffer audioBuffer = AudioBuffer.auto;

  /// Settings › Audio: the playback device by the backend's id (two identical interfaces share a name) and by name,
  /// which opens it when the id has changed (a driver reinstall) ('' both: the system default), the engine's sample
  /// rate (fixed when the engine is made, so a change applies at the next start), a callback size in frames (0: the
  /// buffer mode chooses) and exclusive mode where the backend takes it (WASAPI, AAudio).
  String audioDevice = '';
  String audioDeviceId = '';
  int sampleRate = 48000;
  static const sampleRates = [44100, 48000, 88200, 96000];
  int bufferFrames = 0;
  static const bufferSizes = [0, 16, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 2048, 4096, 8192];
  bool exclusiveAudio = false;

  /// Settings › MIDI and input: the keyboard read ('' every connected one), its channel (0 every channel, else 1-16),
  /// the velocity curve (and the Fixed value), and whether notes play the selected track outside a recording.
  String midiDevice = '';
  int midiChannel = 0;
  VelocityCurve velocityCurve = VelocityCurve.linear;
  double midiFixedVelocity = 0.8;
  bool midiThru = true;

  /// The MIDI devices turned off in Settings › MIDI (by name; the others are read), MPE, and the semitones a full
  /// pitch bend moves (MPE: the master channel's; member channels and MIDI 2.0 per-note bend use 48).
  Set<String> midiClosed = {};
  bool midiMpe = false;
  int midiBendRange = 2;

  /// The on-screen keys: velocity from where a key is touched (0), else this fixed velocity; the octave they open on.
  double keysVelocity = 0;
  int keysOctave = 3;

  /// The metronome's click: its sound and volume (0..1).
  ClickSound clickSound = ClickSound.classic;
  double clickVolume = 1;

  /// Recording: bars played before the record point when Record starts from a stop (not recorded), and how much
  /// earlier than heard (ms) a played note is written, for the output's delay.
  int preRollBars = 0;
  double recordOffsetMs = 0;

  /// The MIDI record mode (Record's long-press).
  MidiRecordMode midiRecordMode = MidiRecordMode.takes;
  static const maxRecordOffsetMs = 250.0;

  /// Settings › Editing: the piano roll opens with this grid (1/n note), snapping, tool and note length (steps; 0
  /// follows the grid); the arrangement follows the playhead; the mouse wheel zooms without Ctrl; deleting a track asks.
  int rollGrid = 16;
  static const rollGrids = [4, 8, 16, 32, 64];
  bool rollSnap = true;
  StartTool rollTool = StartTool.draw;
  double rollNoteSteps = 0;
  static const rollNoteLengths = [0.0, 1.0, 2.0, 4.0, 8.0, 16.0];
  bool followPlayhead = true;
  bool wheelZooms = false;
  bool confirmDelete = false;

  /// Settings › Code editor: the code font size (the C++ editor's is scaled from it), tab width, line numbers and
  /// soft wrap (the C++ editor; the .caw editor always wraps).
  double codeFontSize = 15;
  static const minCodeFontSize = 10.0, maxCodeFontSize = 24.0;
  int codeTabWidth = 4;
  bool codeLineNumbers = true;
  bool codeWrap = false;

  /// Settings › Projects and files: how long after the last edit the project is saved, how many restore points each
  /// project keeps, and what New project starts with.
  int autosaveMs = 500;
  static const autosaveDelays = [500, 2000, 5000, 15000, 30000];
  int restorePointsKept = 20;
  double newProjectBpm = 140; // ProjectDoc's own default
  int newProjectBeatsPerBar = 4;
  /// The template New project opens (`lib/model/templates.dart` ids; '' is a blank project).
  String newProjectTemplate = '';

  /// Settings › Export: what the exporter opens with.
  String exportKind = 'loop';
  int exportSampleRate = 48000;
  bool exportFloat32 = false;
  double exportSeconds = 8;
  ExportNaming exportNaming = ExportNaming.detailed;

  /// The piano roll's sizes, look and touch choices.
  RollLook roll = const RollLook();

  /// The code editor's key row, completion chips, buttons and Controls panel.
  EditorLook editor = const EditorLook();

  /// Themes the user made or imported, saved one file each in themes/.
  /// User-saved export presets and the most recent successful exports.
  List<ExportProfile> exportProfiles = [];
  List<ExportHistoryEntry> exportHistory = [];

  List<CawTheme> customThemes = [];

  /// A theme being edited, shown live instead of the chosen one until it is saved or dropped.
  CawTheme? _draft;

  /// Bumped when the look changed so the screens rebuild from scratch (fixed `const` colours repaint then).
  int lookRevision = 0;
  String _shownLook = '';

  List<CawTheme> get themes => [...starterThemes, ...customThemes];
  bool isStarter(String name) => starterThemes.any((t) => t.name == name);
  CawTheme themeNamed(String name) => themes.firstWhere((t) => t.name == name, orElse: () => calmNeon);
  CawTheme get theme => themeNamed(themeName);
  CawTheme get activeTheme => _draft ?? theme;
  bool get compact => density == Density.compact;

  /// Opens the settings next to the projects folder (the app support folder), or [base] in tests.
  static Future<Settings> open({Directory? base}) async {
    try {
      base ??= await getApplicationSupportDirectory();
    } catch (_) {
      return Settings();
    }
    final s = Settings(dir: base);
    try {
      await s._load();
    } catch (_) {
      // Unreadable settings: start with the defaults.
    }
    return s;
  }

  File? get _file => dir == null ? null : File('${dir!.path}${Platform.pathSeparator}settings.json');
  Directory? get _themesDir => dir == null ? null : Directory('${dir!.path}${Platform.pathSeparator}themes');

  Map<String, dynamic> toJson() => {
        'theme': themeName,
        'density': density.name,
        'live_update': liveUpdate,
        'live_delay_ms': liveDelayMs,
        'swap_timing': swapTiming.name,
        'performance_mode': performanceMode.name,
        'light_mode': lightMode, // retained for older builds that read settings.json
        'light_auto': lightAuto,
        'vim_code': vimCode,
        'motion': motion.name,
        'haptics': haptics,
        'haptic_strength': hapticStrength,
        'layout_mode': layoutMode.name,
        'focus_panel_share': focusPanelShare,
        'glass': glass,
        'quick_actions': quickActions,
        'track_gap': trackGap,
        if (headerWidth > 0) 'header_width': headerWidth,
        if (trackHeight > 0) 'track_height': trackHeight,
        'meter_fall': meterFall,
        'long_press_menu': longPressMenu.name,
        'glass_blur': glassBlur,
        'dock_layouts': dockLayouts,
        'reactive_glow': reactiveGlow,
        'export_profiles': [for (final profile in exportProfiles) profile.toJson()],
        'export_history': [for (final entry in exportHistory) entry.toJson()],
        'roll': roll.toJson(),
        'editor': editor.toJson(),
        'metronome': metronome.name,
        'count_in_bars': countInBars,
        'automation_mode': automationMode,
        'sound_quality': soundQuality.name,
        'audio_buffer': audioBuffer.name,
        'settings_version': version,
        'audio_device': audioDevice,
        'audio_device_id': audioDeviceId,
        'sample_rate': sampleRate,
        'buffer_frames': bufferFrames,
        'exclusive_audio': exclusiveAudio,
        'midi_device': midiDevice,
        'midi_channel': midiChannel,
        'velocity_curve': velocityCurve.name,
        'midi_fixed_velocity': midiFixedVelocity,
        'midi_thru': midiThru,
        'midi_closed': midiClosed.toList(),
        'midi_mpe': midiMpe,
        'midi_bend_range': midiBendRange,
        'keys_velocity': keysVelocity,
        'keys_octave': keysOctave,
        'click_sound': clickSound.name,
        'click_volume': clickVolume,
        'pre_roll_bars': preRollBars,
        'record_offset_ms': recordOffsetMs,
        'midi_record_mode': midiRecordMode.name,
        'roll_grid': rollGrid,
        'roll_snap': rollSnap,
        'roll_tool': rollTool.name,
        'roll_note_steps': rollNoteSteps,
        'follow_playhead': followPlayhead,
        'wheel_zooms': wheelZooms,
        'confirm_delete': confirmDelete,
        'code_font_size': codeFontSize,
        'code_tab_width': codeTabWidth,
        'code_line_numbers': codeLineNumbers,
        'code_wrap': codeWrap,
        'autosave_ms': autosaveMs,
        'restore_points_kept': restorePointsKept,
        'new_project_bpm': newProjectBpm,
        'new_project_beats_per_bar': newProjectBeatsPerBar,
        'new_project_template': newProjectTemplate,
        'export_kind': exportKind,
        'export_sample_rate': exportSampleRate,
        'export_float32': exportFloat32,
        'export_seconds': exportSeconds,
        'export_naming': exportNaming.name,
      };

  /// The settings file's layout: 1 (no `settings_version`) had no Audio, MIDI, Editing, Projects or Export pages; 2
  /// adds them. Every version-1 key keeps its name and meaning, so an older build still reads a newer file.
  static const version = 2;

  /// The file's version when it was read (1 for a file from before `settings_version`).
  int loadedVersion = version;

  void fromJson(Map<String, dynamic> j) {
    T pick<T extends Enum>(List<T> values, Object? v, T fallback) =>
        values.where((e) => e.name == v).firstOrNull ?? fallback;
    themeName = (j['theme'] as String?) ?? themeName;
    density = pick(Density.values, j['density'], density);
    liveUpdate = (j['live_update'] as bool?) ?? liveUpdate;
    liveDelayMs = ((j['live_delay_ms'] as num?)?.toInt() ?? liveDelayMs).clamp(0, 10000);
    swapTiming = pick(SwapTiming.values, j['swap_timing'], swapTiming);
    final savedMode = j['performance_mode'];
    if (savedMode is String) {
      performanceMode = PerformanceMode.values.where((m) => m.name == savedMode).firstOrNull ?? performanceMode;
    } else if (j['light_mode'] is bool) {
      performanceMode = j['light_mode'] == true ? PerformanceMode.lightweight : PerformanceMode.balanced;
    }
    lightAuto = (j['light_auto'] as bool?) ?? lightAuto;
    vimCode = (j['vim_code'] as bool?) ?? vimCode;
    motion = pick(MotionLevel.values, j['motion'], motion);
    if (j['haptics'] is bool) haptics = j['haptics'] as bool;
    final hs = j['haptic_strength'];
    if (hs is num && hs.isFinite) hapticStrength = hs.toDouble().clamp(0.0, 1.0);
    layoutMode = pick(LayoutMode.values, j['layout_mode'], layoutMode);
    final fs = j['focus_panel_share'];
    if (fs is num && fs.isFinite) focusPanelShare = fs.toDouble().clamp(minFocusPanelShare, maxFocusPanelShare);
    if (j['glass'] is bool) glass = j['glass'] as bool;
    if (j['quick_actions'] is bool) quickActions = j['quick_actions'] as bool;
    final gap = j['track_gap'];
    if (gap is num && gap.isFinite) trackGap = gap.toDouble().clamp(0.0, maxTrackGap);
    final hw = j['header_width'];
    if (hw is num && hw.isFinite && hw > 0) headerWidth = hw.toDouble().clamp(minHeaderWidth, maxHeaderWidth);
    final th = j['track_height'];
    if (th is num && th.isFinite && th > 0) trackHeight = th.toDouble().clamp(minTrackHeight, maxTrackHeight);
    final fall = j['meter_fall'];
    if (fall is num && fall.isFinite) meterFall = fall.toDouble().clamp(6.0, 240.0);
    longPressMenu = pick(LongPressMenuStyle.values, j['long_press_menu'], longPressMenu);
    metronome = pick(Metronome.values, j['metronome'], metronome);
    soundQuality = pick(SoundQuality.values, j['sound_quality'], soundQuality);
    audioBuffer = pick(AudioBuffer.values, j['audio_buffer'], audioBuffer);
    final countIn = j['count_in_bars'];
    if (countIn is num && countIn.isFinite) countInBars = countIn.toInt().clamp(0, 4);
    if (const ['touch', 'latch', 'write', 'read'].contains(j['automation_mode'])) automationMode = j['automation_mode'] as String;
    if (j['glass_blur'] is bool) glassBlur = j['glass_blur'] as bool;
    final dock = j['dock_layouts'];
    if (dock is Map) dockLayouts = {for (final e in dock.entries) if (e.key is String) e.key as String: e.value};
    final glow = j['reactive_glow'];
    if (glow is num && glow.isFinite) reactiveGlow = glow.toDouble().clamp(0.0, 1.0);
    exportProfiles = ((j['export_profiles'] is List ? j['export_profiles'] as List : const []))
        .map(ExportProfile.fromJson).whereType<ExportProfile>().take(32).toList();
    exportHistory = ((j['export_history'] is List ? j['export_history'] as List : const []))
        .map(ExportHistoryEntry.fromJson).whereType<ExportHistoryEntry>().take(20).toList();
    final r = j['roll'];
    if (r is Map<String, dynamic>) roll = RollLook.fromJson(r);
    final e = j['editor'];
    if (e is Map<String, dynamic>) editor = EditorLook.fromJson(e);
    _fromJsonV2(j, pick);
  }

  void _fromJsonV2(Map<String, dynamic> j, T Function<T extends Enum>(List<T>, Object?, T) pick) {
    double? num_(String k, double min, double max) {
      final v = j[k];
      return v is num && v.isFinite ? v.toDouble().clamp(min, max) : null;
    }
    String? text(String k, int max) => j[k] is String ? _settingText(j[k], max) : null;
    bool? flag(String k) => j[k] is bool ? j[k] as bool : null;
    final v = j['settings_version'];
    loadedVersion = v is num ? v.toInt() : 1;
    // Version 1 files: the old exporter opened at 48 kHz, 24-bit, 8 s and the loop, as the version-2 defaults do;
    // "Low latency" chose the smallest buffer, which version 2's 0 frames (the mode chooses) still means.
    audioDevice = text('audio_device', 255) ?? audioDevice;
    audioDeviceId = text('audio_device_id', 511) ?? audioDeviceId;
    final rate = j['sample_rate'];
    if (rate is num && sampleRates.contains(rate.toInt())) sampleRate = rate.toInt();
    final frames = j['buffer_frames'];
    if (frames is num && bufferSizes.contains(frames.toInt())) bufferFrames = frames.toInt();
    exclusiveAudio = flag('exclusive_audio') ?? exclusiveAudio;
    midiDevice = text('midi_device', 255) ?? midiDevice;
    midiChannel = num_('midi_channel', 0, 16)?.round() ?? midiChannel;
    velocityCurve = pick(VelocityCurve.values, j['velocity_curve'], velocityCurve);
    midiFixedVelocity = num_('midi_fixed_velocity', 0.05, 1) ?? midiFixedVelocity;
    midiThru = flag('midi_thru') ?? midiThru;
    final closed = j['midi_closed'];
    if (closed is List) midiClosed = {for (final n in closed.take(64)) if (n is String && n.length <= 255) n};
    midiMpe = flag('midi_mpe') ?? midiMpe;
    midiBendRange = num_('midi_bend_range', 1, 48)?.round() ?? midiBendRange;
    keysVelocity = num_('keys_velocity', 0, 1) ?? keysVelocity;
    keysOctave = num_('keys_octave', 1, 6)?.round() ?? keysOctave;
    clickSound = pick(ClickSound.values, j['click_sound'], clickSound);
    clickVolume = num_('click_volume', 0, 1) ?? clickVolume;
    preRollBars = num_('pre_roll_bars', 0, 4)?.round() ?? preRollBars;
    recordOffsetMs = num_('record_offset_ms', 0, maxRecordOffsetMs) ?? recordOffsetMs;
    midiRecordMode = pick(MidiRecordMode.values, j['midi_record_mode'], midiRecordMode);
    final grid = j['roll_grid'];
    if (grid is num && rollGrids.contains(grid.toInt())) rollGrid = grid.toInt();
    rollSnap = flag('roll_snap') ?? rollSnap;
    rollTool = pick(StartTool.values, j['roll_tool'], rollTool);
    final len = j['roll_note_steps'];
    if (len is num && rollNoteLengths.contains(len.toDouble())) rollNoteSteps = len.toDouble();
    followPlayhead = flag('follow_playhead') ?? followPlayhead;
    wheelZooms = flag('wheel_zooms') ?? wheelZooms;
    confirmDelete = flag('confirm_delete') ?? confirmDelete;
    codeFontSize = num_('code_font_size', minCodeFontSize, maxCodeFontSize) ?? codeFontSize;
    final tab = j['code_tab_width'];
    if (tab is num && const [2, 4, 8].contains(tab.toInt())) codeTabWidth = tab.toInt();
    codeLineNumbers = flag('code_line_numbers') ?? codeLineNumbers;
    codeWrap = flag('code_wrap') ?? codeWrap;
    final save = j['autosave_ms'];
    if (save is num && autosaveDelays.contains(save.toInt())) autosaveMs = save.toInt();
    restorePointsKept = num_('restore_points_kept', 1, 100)?.round() ?? restorePointsKept;
    newProjectBpm = num_('new_project_bpm', 20, 400) ?? newProjectBpm;
    newProjectBeatsPerBar = num_('new_project_beats_per_bar', 1, 16)?.round() ?? newProjectBeatsPerBar;
    final template = j['new_project_template'];
    if (template is String && template.length <= 128) {
      newProjectTemplate = template;
    } else if (j['new_project_start'] == 'firstLoop') {
      newProjectTemplate = 'builtin:first-loop';  // the setting's earlier form
    }
    if (const {'loop', 'free', 'oneShot', 'wavetable', 'midi'}.contains(j['export_kind'])) {
      exportKind = j['export_kind'] as String;
    }
    final er = j['export_sample_rate'];
    if (er is num && (er == 44100 || er == 48000)) exportSampleRate = er.toInt();
    exportFloat32 = flag('export_float32') ?? exportFloat32;
    exportSeconds = num_('export_seconds', 1, 120) ?? exportSeconds;
    exportNaming = pick(ExportNaming.values, j['export_naming'], exportNaming);
  }

  Future<void> _load() async {
    final themes = _themesDir;
    if (themes != null && await themes.exists()) {
      final found = <CawTheme>[];
      await for (final f in themes.list()) {
        if (f is! File || !f.path.endsWith('.theme')) continue;
        try {
          final t = CawTheme.parse(await f.readAsString());
          if (!isStarter(t.name) && !found.any((x) => x.name == t.name)) found.add(t);
        } catch (_) {
          // A damaged theme file is skipped, not fatal.
        }
      }
      found.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      customThemes = found;
    }
    try {
      final f = _file;
      if (f != null && await f.exists()) fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      // Damaged settings fall back to the defaults.
    }
    Neon.active = activeTheme;
    _applyPerformanceMode();
    _shownLook = _lookKey;
  }

  /// What a look change compares: the theme and the code editor's font, tabs, numbers and wrap (they are read when
  /// an editor builds, so a change rebuilds the screens once on leaving Settings, as a theme change does).
  String get _lookKey => '${activeTheme.toFile()}|$codeFontSize|$codeTabWidth|$codeLineNumbers|$codeWrap';

  Future<bool> saveExportProfile(ExportProfile profile) async {
    final name = profile.name.trim();
    if (name.isEmpty || name.length > 64) return false;
    final exists = exportProfiles.any((item) => item.name.toLowerCase() == name.toLowerCase());
    if (!exists && exportProfiles.length >= 32) return false;
    exportProfiles = [
      ...exportProfiles.where((item) => item.name.toLowerCase() != name.toLowerCase()),
      ExportProfile(name: name, kind: profile.kind, sampleRate: profile.sampleRate,
        float32: profile.float32, seconds: profile.seconds, frames: profile.frames),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    notifyListeners();
    await save();
    return true;
  }

  /// Record's long-press: the metronome and the count-in, saved at once.
  Future<void> setRecording({Metronome? metronome, int? countInBars, MidiRecordMode? mode}) async {
    if (metronome != null) this.metronome = metronome;
    if (mode != null) midiRecordMode = mode;
    if (countInBars != null) this.countInBars = countInBars.clamp(0, 4);
    notifyListeners();
    await save();
  }

  Future<void> deleteExportProfile(String name) async {
    final next = exportProfiles.where((profile) => profile.name != name).toList();
    if (next.length == exportProfiles.length) return;
    exportProfiles = next;
    notifyListeners();
    await save();
  }

  Future<void> recordExport(ExportHistoryEntry entry) async {
    exportHistory = [entry, ...exportHistory.where((item) =>
      item.fileName != entry.fileName || item.createdAtMs != entry.createdAtMs)].take(20).toList();
    notifyListeners();
    await save();
  }

  /// The save in progress; each save waits for the one before it, so two never share the temporary file.
  Future<void> _saving = Future.value();

  /// Writes through a temporary file so a crash mid-save never leaves half a file. Saves run one after another.
  Future<void> save() => _saving = _saving.catchError((_) {}).then((_) => _write());

  Future<void> _write() async {
    final f = _file;
    if (f == null) return;
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(toJson()), flush: true);
    await tmp.rename(f.path);
  }

  /// True while [adjust] tells its listeners: a continuous control on the Settings page is moving, which the app's
  /// frame doesn't need to rebuild for (the page shows it).
  bool get adjusting => _adjusting;
  bool _adjusting = false;

  /// Changes settings and shows them without saving, for continuous controls; [save] when the drag ends.
  void adjust(void Function(Settings) change) {
    change(this);
    Neon.active = activeTheme;
    _applyPerformanceMode();
    _adjusting = true;
    try {
      notifyListeners();
    } finally {
      _adjusting = false;
    }
  }

  /// Changes settings, shows them and saves them.
  Future<void> update(void Function(Settings) change) async {
    change(this);
    Neon.active = activeTheme;
    _applyPerformanceMode();
    notifyListeners();
    await save();
  }

  /// Shows [draft] live everywhere while it is edited; null goes back to the chosen theme.
  void preview(CawTheme? draft) {
    _draft = draft;
    Neon.active = activeTheme;
    notifyListeners();
  }

  /// After leaving the settings: if the look changed, rebuild every screen once so fixed colours repaint too.
  void commitLook() {
    final now = _lookKey;
    if (now == _shownLook) return;
    _shownLook = now;
    lookRevision++;
    notifyListeners();
  }

  /// A name not used by any theme yet, based on [name].
  String freeName(String name, {String? except}) {
    var out = name;
    var n = 2;
    while (themes.any((t) => t.name == out && t.name != except)) {
      out = '$name ${n++}';
    }
    return out;
  }

  String _fileName(String name) => '${name.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '_').trim()}.theme';

  /// Saves [t] as a custom theme (replacing one of the same name) and makes it the chosen theme.
  /// A starter theme's name is never overwritten: the copy gets a new name. Returns the saved theme.
  Future<CawTheme> saveTheme(CawTheme t, {String? replacing}) async {
    if (isStarter(t.name)) t = t.copyWith(name: freeName('${t.name} copy'));
    if (replacing != null && replacing != t.name && !isStarter(replacing)) await deleteTheme(replacing, save: false);
    customThemes = [...customThemes.where((x) => x.name != t.name), t]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final d = _themesDir;
    if (d != null) {
      await d.create(recursive: true);
      await File('${d.path}${Platform.pathSeparator}${_fileName(t.name)}').writeAsString(t.toFile(), flush: true);
    }
    _draft = null;
    await update((s) => s.themeName = t.name);
    return t;
  }

  Future<void> deleteTheme(String name, {bool save = true}) async {
    if (isStarter(name)) return;
    customThemes = customThemes.where((t) => t.name != name).toList();
    final d = _themesDir;
    if (d != null) {
      final f = File('${d.path}${Platform.pathSeparator}${_fileName(name)}');
      if (await f.exists()) await f.delete();
    }
    if (save) await update((s) => s.themeName = s.themeNamed(s.themeName).name);
  }
}

/// Which C keys of the roll's keyboard carry a note name.
enum KeyLabels { none, octaves, all }

/// What one finger dragged on empty grid does in the draw tool (owner's default: scroll).
enum EmptyDrag { scroll, select, draw }

/// The value grid that volume, timbre, velocity and chance snap to while snapping is on (owner, 2026-11-04).
enum ValueGrid {
  quarter(0.25, '1/4'),
  eighth(0.125, '1/8'),
  sixteenth(0.0625, '1/16'),
  tenPercent(0.1, '10%'),
  fivePercent(0.05, '5%');

  const ValueGrid(this.step, this.label);
  final double step;
  final String label;
}

/// The piano roll's sizes, look and touch choices, each clamped to a range that stays usable.
class RollLook {
  const RollLook({
    this.rowHeight = 16,
    this.velocityLane = 56,
    this.chanceLane = 40,
    this.gridStrength = 1,
    this.keyLabels = KeyLabels.octaves,
    this.grab = 12,
    this.emptyDrag = EmptyDrag.scroll,
    this.holdMs = 500,
    this.valueGrid = ValueGrid.eighth,
    this.hearNotes = true,
  });

  final double rowHeight, velocityLane, chanceLane, gridStrength;
  final KeyLabels keyLabels;

  /// How close to a note's end (px) a touch resizes it instead of moving it; notes shorter than twice this are
  /// also easier to hit, since a touch this close beside one counts as on it.
  final double grab;
  final EmptyDrag emptyDrag;

  /// How long holding a note takes to open its extras.
  final int holdMs;

  final ValueGrid valueGrid;

  /// Notes sound while you place, move, hold or bend them (owner, 2026-11-05).
  final bool hearNotes;

  RollLook copyWith({
    double? rowHeight,
    double? velocityLane,
    double? chanceLane,
    double? gridStrength,
    KeyLabels? keyLabels,
    double? grab,
    EmptyDrag? emptyDrag,
    int? holdMs,
    ValueGrid? valueGrid,
    bool? hearNotes,
  }) =>
      RollLook(
        rowHeight: (rowHeight ?? this.rowHeight).clamp(10, 40).toDouble(),
        velocityLane: (velocityLane ?? this.velocityLane).clamp(32, 160).toDouble(),
        chanceLane: (chanceLane ?? this.chanceLane).clamp(24, 120).toDouble(),
        gridStrength: (gridStrength ?? this.gridStrength).clamp(0.2, 2).toDouble(),
        keyLabels: keyLabels ?? this.keyLabels,
        grab: (grab ?? this.grab).clamp(6, 40).toDouble(),
        emptyDrag: emptyDrag ?? this.emptyDrag,
        holdMs: (holdMs ?? this.holdMs).clamp(250, 1500),
        valueGrid: valueGrid ?? this.valueGrid,
        hearNotes: hearNotes ?? this.hearNotes,
      );

  Map<String, dynamic> toJson() => {
        'row_height': rowHeight,
        'velocity_lane': velocityLane,
        'chance_lane': chanceLane,
        'grid_strength': gridStrength,
        'key_labels': keyLabels.name,
        'grab': grab,
        'empty_drag': emptyDrag.name,
        'hold_ms': holdMs,
        'value_grid': valueGrid.name,
        'hear_notes': hearNotes,
      };

  static RollLook fromJson(Map<String, dynamic> j) {
    double? n(String k) => (j[k] as num?)?.toDouble();
    return const RollLook().copyWith(
      rowHeight: n('row_height'),
      velocityLane: n('velocity_lane'),
      chanceLane: n('chance_lane'),
      gridStrength: n('grid_strength'),
      keyLabels: KeyLabels.values.where((e) => e.name == j['key_labels']).firstOrNull,
      grab: n('grab'),
      emptyDrag: EmptyDrag.values.where((e) => e.name == j['empty_drag']).firstOrNull,
      holdMs: n('hold_ms')?.round(),
      valueGrid: ValueGrid.values.where((e) => e.name == j['value_grid']).firstOrNull,
      hearNotes: j['hear_notes'] is bool ? j['hear_notes'] as bool : null,
    );
  }
}

/// The code editor's layout: what the symbol key row holds, when completion chips show, which buttons and panels
/// show, and where the Run bar sits.
class EditorLook {
  const EditorLook({
    this.keyRow = defaultKeyRow,
    this.chips = true,
    this.chipLetters = 2,
    this.chipCount = 8,
    this.libraryButton = true,
    this.soloButton = true,
    this.scope = true,
    this.barOnTop = false,
    this.compactControls = false,
  });

  static const defaultKeyRow = [
    't', '>>', '<<', '&', '|', '^', '%', '(', ')', '?', ':', '~', '*', '+', '-', '/', '=', '255', 'let ', 'param ', //
  ];

  /// The symbol key row's keys, in order; a key may end in a space ("let ").
  final List<String> keyRow;

  /// Completion chips, after how many typed letters, and how many at most.
  final bool chips;
  final int chipLetters, chipCount;

  /// The Library and Solo preview buttons and the scope.
  final bool libraryButton, soloButton, scope;

  /// The key row and Run bar above the code instead of under it.
  final bool barOnTop;

  /// Denser control rows.
  final bool compactControls;

  EditorLook copyWith({
    List<String>? keyRow,
    bool? chips,
    int? chipLetters,
    int? chipCount,
    bool? libraryButton,
    bool? soloButton,
    bool? scope,
    bool? barOnTop,
    bool? compactControls,
  }) =>
      EditorLook(
        keyRow: List.unmodifiable([
          for (final k in keyRow ?? this.keyRow)
            if (k.trim().isNotEmpty && k.length <= 16) k
        ].take(64)),
        chips: chips ?? this.chips,
        chipLetters: (chipLetters ?? this.chipLetters).clamp(1, 4),
        chipCount: (chipCount ?? this.chipCount).clamp(3, 16),
        libraryButton: libraryButton ?? this.libraryButton,
        soloButton: soloButton ?? this.soloButton,
        scope: scope ?? this.scope,
        barOnTop: barOnTop ?? this.barOnTop,
        compactControls: compactControls ?? this.compactControls,
      );

  Map<String, dynamic> toJson() => {
        'key_row': keyRow,
        'chips': chips,
        'chip_letters': chipLetters,
        'chip_count': chipCount,
        'library_button': libraryButton,
        'solo_button': soloButton,
        'scope': scope,
        'bar_on_top': barOnTop,
        'compact_controls': compactControls,
      };

  static EditorLook fromJson(Map<String, dynamic> j) {
    final row = j['key_row'];
    return const EditorLook().copyWith(
      keyRow: row is List ? [for (final k in row) if (k is String) k] : null,
      chips: j['chips'] as bool?,
      chipLetters: (j['chip_letters'] as num?)?.toInt(),
      chipCount: (j['chip_count'] as num?)?.toInt(),
      libraryButton: j['library_button'] as bool?,
      soloButton: j['solo_button'] as bool?,
      scope: j['scope'] as bool?,
      barOnTop: j['bar_on_top'] as bool?,
      compactControls: j['compact_controls'] as bool?,
    );
  }
}
