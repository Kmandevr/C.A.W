// App-wide settings (theme, density, motion, live coding) saved as settings.json, plus custom theme files in themes/
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../ui/glass.dart';
import '../ui/motion.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart' show PeakMeter;

enum Density { comfortable, compact }

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

/// Sound quality (owner, 2026-11-10), in the engine's order (CAW_QUALITY_*): Eco spends less on oversampling,
/// unison copies, reverb density and display updates; High oversamples the saturator further.
enum SoundQuality { eco, normal, high }

/// The device buffer (owner, 2026-11-10), in the engine's order (CAW_BUFFER_*): Auto uses a larger one while not
/// recording (fewer wake-ups, less battery), Low latency always the smallest, Battery always the larger.
enum AudioBuffer { auto, lowLatency, battery }

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
    Glass.enabled = glass;
    Glass.blurEnabled = glassBlur;
    Motion.minimalProfile = performanceMode == PerformanceMode.minimal;
    PeakMeter.fallDbPerSecond = meterFall;
  }

  /// Motion (owner, 2026-11-04): Full, Reduced (fades only) or Off. Minimal and the system setting lower it further.
  MotionLevel motion = MotionLevel.full;

  /// Haptic ticks on snaps, detents and placed notes; on by default (owner).
  bool haptics = true;

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
      };

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
    _shownLook = activeTheme.toFile();
  }

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
  Future<void> setRecording({Metronome? metronome, int? countInBars}) async {
    if (metronome != null) this.metronome = metronome;
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

  /// Changes settings and shows them without saving, for continuous controls; [save] when the drag ends.
  void adjust(void Function(Settings) change) {
    change(this);
    Neon.active = activeTheme;
    _applyPerformanceMode();
    notifyListeners();
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
    final now = activeTheme.toFile();
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
