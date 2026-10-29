// App-wide settings (theme, density, live coding) saved as settings.json, plus custom theme files in themes/.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../ui/theme.dart';

enum Density { comfortable, compact }

/// When a code change swaps into the playing sound.
enum SwapTiming { now, beat, bar }

class Settings extends ChangeNotifier {
  /// Settings kept in [dir] (settings.json and themes/); with no folder they live in memory only.
  Settings({this.dir}) {
    Neon.active = activeTheme;
    Neon.light = lightMode;
  }

  final Directory? dir;

  String themeName = calmNeon.name;
  Density density = Density.comfortable;

  /// Live coding: code swaps in by itself [liveDelayMs] after the last edit, at [swapTiming].
  bool liveUpdate = true;
  int liveDelayMs = 400;
  SwapTiming swapTiming = SwapTiming.now;

  /// Light mode for slow devices: no glow or scopes, meters at 15 fps, 4 voices per pattern layer, and auto-update
  /// waits while playing. [lightAuto] turns it on by itself the first time the engine reports an overload.
  bool lightMode = false;
  bool lightAuto = true;

  /// Vim editing in the code editor (WASD moves; I types). Off by default.
  bool vimCode = false;

  /// The piano roll's sizes, look and touch choices.
  RollLook roll = const RollLook();

  /// The code editor's key row, completion chips, buttons and Controls panel.
  EditorLook editor = const EditorLook();

  /// Themes the user made or imported, saved one file each in themes/.
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
        'light_mode': lightMode,
        'light_auto': lightAuto,
        'vim_code': vimCode,
        'roll': roll.toJson(),
        'editor': editor.toJson(),
      };

  void fromJson(Map<String, dynamic> j) {
    T pick<T extends Enum>(List<T> values, Object? v, T fallback) =>
        values.where((e) => e.name == v).firstOrNull ?? fallback;
    themeName = (j['theme'] as String?) ?? themeName;
    density = pick(Density.values, j['density'], density);
    liveUpdate = (j['live_update'] as bool?) ?? liveUpdate;
    liveDelayMs = ((j['live_delay_ms'] as num?)?.toInt() ?? liveDelayMs).clamp(0, 10000);
    swapTiming = pick(SwapTiming.values, j['swap_timing'], swapTiming);
    lightMode = (j['light_mode'] as bool?) ?? lightMode;
    lightAuto = (j['light_auto'] as bool?) ?? lightAuto;
    vimCode = (j['vim_code'] as bool?) ?? vimCode;
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
    Neon.light = lightMode;
    _shownLook = activeTheme.toFile();
  }

  /// Writes through a temporary file so a crash mid-save never leaves half a file.
  Future<void> save() async {
    final f = _file;
    if (f == null) return;
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent(' ').convert(toJson()), flush: true);
    await tmp.rename(f.path);
  }

  /// Changes settings, shows them and saves them.
  Future<void> update(void Function(Settings) change) async {
    change(this);
    Neon.active = activeTheme;
    Neon.light = lightMode;
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
  });

  final double rowHeight, velocityLane, chanceLane, gridStrength;
  final KeyLabels keyLabels;

  /// How close to a note's end (px) a touch resizes it instead of moving it; notes shorter than twice this are
  /// also easier to hit, since a touch this close beside one counts as on it.
  final double grab;
  final EmptyDrag emptyDrag;

  /// How long holding a note takes to open its extras.
  final int holdMs;

  RollLook copyWith({
    double? rowHeight,
    double? velocityLane,
    double? chanceLane,
    double? gridStrength,
    KeyLabels? keyLabels,
    double? grab,
    EmptyDrag? emptyDrag,
    int? holdMs,
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
