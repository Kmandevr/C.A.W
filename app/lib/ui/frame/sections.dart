// The app's three main sections (Build, Files, Arrange), which one is in front, Build's open files, and what can be
// dragged between them. Screens reach it with SectionController.of(context); the frame (shell.dart) shows it.
import 'package:flutter/widgets.dart';

/// The three main tab types (owner, 2026-11-09, `docs/decisions.md` "The app's layout").
enum Section { build, files, arrange }

/// What a Build tab edits: a project C++ component (by its component id) or a .caw module (by its module id).
enum BuildTabKind { cpp, caw }

@immutable
class BuildTab {
  const BuildTab(this.kind, this.id);
  final BuildTabKind kind;
  final String id;

  @override
  bool operator ==(Object other) => other is BuildTab && other.kind == kind && other.id == id;
  @override
  int get hashCode => Object.hash(kind, id);
}

/// The section in front and Build's open tabs. A screen that opens something elsewhere (Files opening a C++
/// source, an FX card opening its code) calls [openBuild] or [show]; the frame follows.
class SectionController extends ChangeNotifier {
  Section _current = Section.arrange;
  Section get current => _current;

  final List<BuildTab> _tabs = [];
  List<BuildTab> get buildTabs => List.unmodifiable(_tabs);
  BuildTab? _activeTab;
  BuildTab? get activeBuildTab => _activeTab != null && _tabs.contains(_activeTab) ? _activeTab : _tabs.lastOrNull;

  /// The track Arrange is focused on (the focus view), or null for all tracks.
  String? _focusedLayer;
  String? get focusedLayer => _focusedLayer;

  /// The top bars (the status row, a section's toolbar): scrolling down tucks them away, scrolling up brings them
  /// back (owner, 2026-11-10). A section change shows them again.
  final ValueNotifier<bool> barsShown = ValueNotifier(true);

  void show(Section s) {
    barsShown.value = true;
    if (_current == s) return;
    _current = s;
    notifyListeners();
  }

  @override
  void dispose() {
    barsShown.dispose();
    super.dispose();
  }

  /// Opens [tab] in Build (adding it when new) and brings Build to the front.
  void openBuild(BuildTab tab) {
    if (!_tabs.contains(tab)) _tabs.add(tab);
    _activeTab = tab;
    _current = Section.build;
    notifyListeners();
  }

  /// Adds [tab] to Build without bringing Build to the front (the shell opens the selected .caw module at start).
  void addBuild(BuildTab tab) {
    if (_tabs.contains(tab)) return;
    _tabs.add(tab);
    _activeTab ??= tab;
    notifyListeners();
  }

  void activateBuild(BuildTab tab) {
    if (!_tabs.contains(tab) || _activeTab == tab) return;
    _activeTab = tab;
    notifyListeners();
  }

  void closeBuild(BuildTab tab) {
    if (!_tabs.remove(tab)) return;
    if (_activeTab == tab) _activeTab = _tabs.lastOrNull;
    notifyListeners();
  }

  /// Drops tabs whose component or module is gone ([exists] says which still are).
  void pruneBuild(bool Function(BuildTab tab) exists) {
    final before = _tabs.length;
    _tabs.removeWhere((t) => !exists(t));
    if (_tabs.length != before) notifyListeners();
  }

  /// Focuses Arrange on [layerId] (null: back to all tracks) and brings Arrange to the front.
  void focusLayer(String? layerId) {
    if (_focusedLayer == layerId && _current == Section.arrange) return;
    _focusedLayer = layerId;
    _current = Section.arrange;
    notifyListeners();
  }

  static SectionController of(BuildContext context) => maybeOf(context)!;

  static SectionController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SectionScope>()?.notifier;
}

class SectionScope extends InheritedNotifier<SectionController> {
  const SectionScope({super.key, required SectionController controller, required super.child})
      : super(notifier: controller);
}

/// What can be dragged from Files (or a browser sheet) onto a track or an effect slot.
enum AssetKind {
  nativeEffect, // a native stereo effect: a built-in (org.caw.*) or a project C++ component, by component id
  cawModule,    // a project .caw module, by module id
  pattern,      // a MIDI pattern source, by module id
}

@immutable
class AssetDrag {
  const AssetDrag(this.kind, this.id, this.name);
  final AssetKind kind;
  final String id;
  final String name;
}
