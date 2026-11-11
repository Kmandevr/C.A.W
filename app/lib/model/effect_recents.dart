// The effects picked lately in the effect browser, newest first, kept app-wide in `fx-recents.json` (in memory without a folder).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_state.dart';

class EffectRecents {
  EffectRecents(this.file);
  final File? file;
  static const maxIds = 12;
  final List<String> ids = [];
  Future<void>? _loading;
  Future<void> _saving = Future.value();

  Future<void> load() => _loading ??= () async {
        try {
          final f = file;
          if (f == null || !await f.exists()) return;
          final j = jsonDecode(await f.readAsString());
          if (j is Map && j['recent'] is List) {
            ids.addAll((j['recent'] as List).whereType<String>().where((k) => k.length <= 200).take(maxIds));
          }
        } catch (_) {
          // An unreadable file starts empty.
        }
      }();

  /// Puts [id] first (once), keeping at most [maxIds].
  void use(String id) {
    ids.remove(id);
    ids.insert(0, id);
    if (ids.length > maxIds) ids.removeRange(maxIds, ids.length);
    final f = file;
    if (f == null) return;
    final text = jsonEncode({'recent': ids});
    _saving = _saving.catchError((_) {}).then((_) async {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(text, flush: true);
      await tmp.rename(f.path);
    });
    unawaited(_saving.catchError((_) {}));
  }
}

final Expando<EffectRecents> _recents = Expando('effect recents');

extension EffectRecentsState on AppState {
  EffectRecents get effectRecents => _recents[this] ??= EffectRecents(
      settings.dir == null ? null : File('${settings.dir!.path}${Platform.pathSeparator}fx-recents.json'));
}
