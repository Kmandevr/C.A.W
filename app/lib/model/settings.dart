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
