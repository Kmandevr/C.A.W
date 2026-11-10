// What the preset UI does: save (with a name and a tag, asking before replacing), quick save, track presets, and
// presets exported and imported as .cawpreset files through the system file picker; each saves with an Undo toast.
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../model/app_state.dart';
import '../../../model/device_target.dart';
import '../../../model/project.dart';
import '../../../model/user_presets.dart';
import '../../haptics.dart';
import '../../theme.dart';
import 'presets.dart';

/// The file picker behind export and import; tests replace both.
class PresetFiles {
  PresetFiles._();

  /// Asks where to save [bytes] as [name]; true when saved.
  static Future<bool> Function(String name, Uint8List bytes) save = _save;

  /// Asks for a preset file; null when the picker was closed. [length] is checked before [read].
  static Future<({String name, int length, Future<String> Function() read})?> Function() pick = _pick;

  static Future<bool> _save(String name, Uint8List bytes) async => await FilePicker.saveFile(
        fileName: name,
        bytes: bytes,
        mimeType: 'application/json',
        type: FileType.custom,
        allowedExtensions: const ['cawpreset'],
      ) != null;

  static Future<({String name, int length, Future<String> Function() read})?> _pick() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: const ['cawpreset', 'json']);
    if (f == null) return null;
    return (name: f.name, length: await f.xFile.length(), read: f.xFile.readAsString);
  }
}

/// The extension of an exported preset.
const presetExtension = 'cawpreset';

void _toast(BuildContext context, String text, {VoidCallback? undo, bool error = false}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    content: Text(text, style: TextStyle(color: error ? Neon.pink : null)),
    duration: const Duration(seconds: 4),
    action: undo == null ? null : SnackBarAction(label: 'Undo', onPressed: () {
      Haptics.tap();
      undo();
    }),
  ));
}

/// What the save dialog returns.
typedef PresetName = ({String name, String category});

/// Asks for a preset's name (starting at [initial]) and an optional tag; [tags] are offered as chips. Null when
/// cancelled.
Future<PresetName?> askPresetName(BuildContext context, {required String title, required String initial,
    String category = '', List<String> tags = const []}) => showDialog<PresetName>(
      context: context,
      builder: (context) => _PresetNameDialog(title: title, initial: initial, category: category, tags: tags));

class _PresetNameDialog extends StatefulWidget {
  const _PresetNameDialog({required this.title, required this.initial, required this.category, required this.tags});
  final String title, initial, category;
  final List<String> tags;

  @override
  State<_PresetNameDialog> createState() => _PresetNameDialogState();
}

class _PresetNameDialogState extends State<_PresetNameDialog> {
  late final name = TextEditingController(text: widget.initial)
    ..selection = TextSelection(baseOffset: 0, extentOffset: widget.initial.length);
  late final tag = TextEditingController(text: widget.category);

  @override
  void dispose() {
    name.dispose();
    tag.dispose();
    super.dispose();
  }

  void _done() {
    final n = UserPreset.cleanName(name.text, PresetLimits.name);
    if (n.isEmpty) return;
    Navigator.pop(context, (name: n, category: UserPreset.cleanName(tag.text, PresetLimits.category)));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        key: const ValueKey('preset-save-dialog'),
        title: Text(widget.title),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(key: const ValueKey('preset-save-name'), controller: name, autofocus: true,
            maxLength: PresetLimits.name, decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (_) => _done()),
          TextField(key: const ValueKey('preset-save-tag'), controller: tag, maxLength: PresetLimits.category,
            decoration: const InputDecoration(labelText: 'Tag (optional)', hintText: 'Bass, Pad, Drums…'),
            onSubmitted: (_) => _done()),
          if (widget.tags.isNotEmpty) Align(alignment: Alignment.centerLeft, child: Wrap(spacing: 6, children: [
            for (final t in widget.tags.take(8)) ActionChip(
              label: Text(t, style: const TextStyle(fontSize: 11)),
              visualDensity: VisualDensity.compact,
              onPressed: () => setState(() => tag.text = t)),
          ])),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('preset-save-ok'), onPressed: _done, child: const Text('Save')),
        ],
      );
}

/// Asks before replacing preset [name]; true to go on.
Future<bool> confirmReplace(BuildContext context, String name) async => await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace the preset?'),
        content: Text('"$name" already exists. Replace it with these settings?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(key: const ValueKey('preset-replace'), onPressed: () => Navigator.pop(context, true),
            child: const Text('Replace')),
        ],
      ),
    ) == true;

/// Saves [p] into the library with an Undo toast (which brings back what it replaced, or removes it). False when
/// the library refused it.
bool _put(BuildContext context, UserPresetStore store, UserPreset p, {String? verb, VoidCallback? afterUndo}) {
  final UserPreset? old;
  try {
    old = store.put(p);
  } catch (e) {
    Haptics.error();
    _toast(context, 'Not saved: ${e is FormatException ? e.message : e}', error: true);
    return false;
  }
  Haptics.drop();
  _toast(context, '${verb ?? 'Saved'} "${p.name}"', undo: () {
    old == null ? store.remove(p.id) : store.put(old);
    afterUndo?.call();
  });
  return true;
}

/// The name "Save preset…" starts with: the current user preset's (saving over it), else the first free
/// "DEVICE 1", "DEVICE 2"...
String defaultPresetName(DeviceTarget t) =>
    DevicePresets.currentUser(t)?.name ??
    t.state.userPresets.freeName(t.label, UserPresetKind.device, componentId: t.componentId);

/// "Save preset…": asks for a name and tag, asks before replacing one of that name, saves the device's values and
/// state, and makes it the current preset. Returns the saved preset.
Future<UserPreset?> savePresetAs(BuildContext context, DeviceTarget t) async {
  final store = t.state.userPresets;
  final id = t.componentId;
  if (id == null) return null;
  final current = DevicePresets.currentUser(t);
  final tags = {for (final p in store.all) if (p.category.isNotEmpty) p.category}.toList()..sort();
  final picked = await askPresetName(context, title: 'Save ${t.label} preset', initial: defaultPresetName(t),
      category: current?.category ?? '', tags: tags);
  if (picked == null || !context.mounted) return null;
  final existing = store.named(UserPresetKind.device, picked.name, componentId: id);
  if (existing != null && !await confirmReplace(context, existing.name)) return null;
  if (!context.mounted) return null;
  final device = t.state.captureDevice(t);
  if (device == null) return null;
  final p = UserPreset(id: existing?.id ?? store.newId(), kind: UserPresetKind.device, name: picked.name,
      category: picked.category, device: device, modified: DateTime.now());
  if (!_put(context, store, p)) return null;
  DevicePresets.remember(t, DevicePreset.user(p));
  return p;
}

/// Quick save (Ctrl+S, the header's save icon): the device's values over its current user preset. False when the
/// current preset isn't the user's.
bool quickSavePreset(BuildContext context, DeviceTarget t) {
  final p = DevicePresets.currentUser(t);
  final device = t.state.captureDevice(t);
  if (p == null || device == null) return false;
  final next = p.copyWith(device: device, modified: DateTime.now());
  final ok = _put(context, t.state.userPresets, next);
  if (ok) DevicePresets.remember(t, DevicePreset.user(next));
  return ok;
}

/// "Save track preset…": the track's instrument and native effects with their values.
Future<UserPreset?> saveTrackPreset(BuildContext context, AppState state, LayerDoc layer) async {
  final store = state.userPresets;
  final initial = store.named(UserPresetKind.track, layer.name) == null
      ? UserPreset.cleanName(layer.name, PresetLimits.name)
      : store.freeName(layer.name, UserPresetKind.track);
  final probe = state.captureTrack(layer, name: initial.isEmpty ? 'Track' : initial);
  if (probe == null) {
    _toast(context, 'This track has no instrument or effects to save.', error: true);
    return null;
  }
  final picked = await askPresetName(context, title: 'Save track preset', initial: probe.name);
  if (picked == null || !context.mounted) return null;
  final existing = store.named(UserPresetKind.track, picked.name);
  if (existing != null && !await confirmReplace(context, existing.name)) return null;
  if (!context.mounted) return null;
  final p = state.captureTrack(layer, name: picked.name, category: picked.category, id: existing?.id ?? store.newId());
  if (p == null || !_put(context, store, p)) return null;
  return p;
}

/// Loads track preset [p] onto [layer] (one undo step) with an Undo toast.
void loadTrackPreset(BuildContext context, AppState state, LayerDoc layer, UserPreset p) {
  state.endUndoStep();
  if (!state.applyTrackPreset(layer, p)) return;
  state.endUndoStep();
  Haptics.drop();
  _toast(context, 'Loaded "${p.name}" on ${layer.name}', undo: state.undo);
}

String _fileName(String name) {
  final base = name.replaceAll(RegExp(r'[\\/:*?"<>|#\x00-\x1F]'), ' ').trim();
  return '${base.isEmpty ? 'Preset' : base}.$presetExtension';
}

/// Exports [p] as a .cawpreset file where the user picks.
Future<void> exportPreset(BuildContext context, UserPreset p) async {
  try {
    final saved = await PresetFiles.save(_fileName(p.name), Uint8List.fromList(utf8.encode(p.encode())));
    if (context.mounted) _toast(context, saved ? 'Exported "${p.name}"' : 'Not exported (picker closed).');
  } catch (e) {
    if (context.mounted) _toast(context, 'Could not export: $e', error: true);
  }
}

/// Imports a .cawpreset file into the library (a taken name gets a number). The file is checked as untrusted input:
/// its size first, then its format, types and bounds.
Future<UserPreset?> importPreset(BuildContext context, UserPresetStore store) async {
  try {
    final f = await PresetFiles.pick();
    if (f == null) return null;
    if (f.length > PresetLimits.fileBytes) throw const FormatException('the file is bigger than 4 MB');
    final p = store.importText(await f.read());
    if (p == null) throw const FormatException('this is not a C.A.W preset this app can read');
    Haptics.drop();
    if (context.mounted) _toast(context, 'Imported "${p.name}"', undo: () => store.remove(p.id));
    return p;
  } on FormatException catch (e) {
    Haptics.error();
    if (context.mounted) _toast(context, 'Not imported: ${e.message}', error: true);
  } catch (e) {
    Haptics.error();
    if (context.mounted) _toast(context, 'Could not import: $e', error: true);
  }
  return null;
}

/// Asks for a new name (and tag) for [p], asking before taking another preset's name.
Future<void> renamePreset(BuildContext context, UserPresetStore store, UserPreset p) async {
  final picked = await askPresetName(context, title: 'Rename preset', initial: p.name, category: p.category);
  if (picked == null || !context.mounted) return;
  final other = store.named(p.kind, picked.name, componentId: p.componentId);
  if (other != null && other.id != p.id) {
    if (!await confirmReplace(context, other.name) || !context.mounted) return;
    store.remove(other.id);
  }
  store.rename(p.id, picked.name, category: picked.category);
  Haptics.tap();
}

/// Deletes [p] with an Undo toast.
void deletePreset(BuildContext context, UserPresetStore store, UserPreset p) {
  final old = store.remove(p.id);
  if (old == null) return;
  Haptics.tap();
  _toast(context, 'Deleted "${p.name}"', undo: () => store.put(old));
}

void duplicatePreset(BuildContext context, UserPresetStore store, UserPreset p) {
  final copy = store.duplicate(p.id);
  if (copy == null) return;
  Haptics.tap();
  _toast(context, 'Duplicated as "${copy.name}"', undo: () => store.remove(copy.id));
}
