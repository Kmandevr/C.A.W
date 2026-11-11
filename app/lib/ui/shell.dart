// App shell: the frame (Build, Files, Arrange; bottom transport on phones, a rail and docking panels when wide) and
// the project menu.
import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../actions/actions.dart';
import '../model/cpp_workbench.dart';
import '../model/automation_writer.dart';
import '../model/live_midi.dart';
import '../model/app_state.dart';
import '../model/settings.dart';
import '../model/audio_edit.dart' show audioExtensions;
import '../platform/desktop_window.dart';
import '../platform/system_bars.dart';
import 'audio_file_actions.dart' show AudioSource, importAudioSources;
import 'arranger_screen.dart';
import 'audio_record_ui.dart';
import 'export_page.dart';
import 'cpp/build_section.dart';
import 'dock/dock_controller.dart';
import 'dock/dock_view.dart';
import 'dock/floating_window.dart';
import 'dock/layout.dart';
import 'file_manager_screen.dart';
import 'files/project_file_actions.dart';
import 'key_router.dart';
import 'page_closer.dart';
import 'theme.dart';
import 'settings/settings_page.dart';
import 'widgets.dart';
import 'feedback.dart';
import 'glass.dart';
import 'haptics.dart';
import 'frame/bars_handle.dart';
import 'frame/frame_widgets.dart';
import 'frame/live_keys.dart';
import 'frame/record_tools.dart';
import 'frame/sections.dart';
import 'frame/strain.dart';
import 'adaptive_sheet.dart';
import 'arrange/templates_ui.dart';
import '../model/templates.dart';
import 'pointer_input.dart';

/// The panel each view shortcut shows, by the index KeyRouter's `onView` passes.
const _viewPanels = [Panels.builder, Panels.arrangement, Panels.files];

/// The keyboard area of each panel.
Area _areaOf(String panel) => switch (panel) {
      Panels.builder => Area.builder,
      Panels.arrangement => Area.arranger,
      _ => Area.global,
    };

/// The screen shape that keeps its own layout, from the shell's size in logical pixels (the window's pixels over its
/// density, so a DeX window, an external display or a freeform window counts by its real room, not by the device).
/// [LayoutMode.auto]: the desktop frame when the window is big enough (a shortest side of 600 dp, as a tablet, owner
/// 2026-11-09; or 900 dp wide and 480 dp tall, so a phone in landscape stays a phone). [LayoutMode.desktop] forces
/// it and [LayoutMode.phone] never uses it (owner, 2026-11-10).
FormFactor formFactorFor(Size size, {LayoutMode mode = LayoutMode.auto}) {
  final big = size.shortestSide >= 600 || (size.width >= 900 && size.height >= 480);
  if (mode == LayoutMode.desktop || (mode == LayoutMode.auto && big)) return FormFactor.desktop;
  return size.width > size.height ? FormFactor.phoneLandscape : FormFactor.phonePortrait;
}

/// The section a docked panel belongs to (the rail highlights it), or null for the others.
Section? sectionOfPanel(String panel) => switch (panel) {
      Panels.builder => Section.build,
      Panels.files => Section.files,
      Panels.arrangement => Section.arrange,
      _ => null,
    };

/// The docked panel that shows [section] on desktop.
String panelOfSection(Section section) => switch (section) {
      Section.build => Panels.builder,
      Section.files => Panels.files,
      Section.arrange => Panels.arrangement,
    };

class Shell extends StatefulWidget {
  const Shell({super.key, required this.state});
  final AppState state;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  late final AppLifecycleListener _life;
  late final DockController _dock = DockController(s.settings);
  final SectionController _sections = SectionController();
  Section _lastSection = Section.arrange;

  // Phone: the top row brought down within thumb reach (a downward swipe on the bottom bar); a tap anywhere ends it.
  bool _reach = false;

  // The arrangement is home (UI plan U1): shown in front once at launch, whatever panel the saved layout had there.
  bool _homeShown = false;

  AppState get s => widget.state;

  // Settings › Layout, followed while running.
  late LayoutMode _layoutMode = s.settings.layoutMode;

  void _onSettings() {
    if (s.settings.layoutMode != _layoutMode && mounted) setState(() => _layoutMode = s.settings.layoutMode);
  }

  StreamSubscription<List<String>>? _opened;

  // The window's title follows the project's name (desktop; DesktopWindow ignores it elsewhere).
  void _syncTitle() {
    if (!s.ready) return;
    DesktopWindow.current.setProjectTitle(s.project.name);
    if (_waiting.isNotEmpty) {
      final paths = List.of(_waiting);
      _waiting.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) => _openFiles(paths));
    }
  }

  final List<String> _waiting = []; // files that came before the project was ready

  /// Files opened with the app or dropped on its window: audio files are imported, each onto a new audio track, as
  /// Files' import does. Other kinds (.mid, projects) are left to other listeners of [DesktopWindow.openedFiles].
  void _openFiles(List<String> paths) {
    final audio = [
      for (final p in paths)
        if (audioExtensions.contains(p.split('.').last.toLowerCase())) File(p),
    ];
    final others = paths.length - audio.length;
    if (others > 0) debugPrint('Opened files not imported here: ${paths.where((p) => !audio.any((f) => f.path == p))}');
    if (audio.isEmpty || !mounted) return;
    if (!s.ready) {
      _waiting.addAll(audio.map((f) => f.path));
      return;
    }
    final sources = <AudioSource>[
      for (final f in audio)
        if (f.existsSync())
          (name: f.uri.pathSegments.last, size: f.lengthSync(), read: () => f.openRead()),
    ];
    if (sources.isNotEmpty) unawaited(importAudioSources(context, s, sources));
  }

  @override
  void initState() {
    super.initState();
    s.addListener(_syncTitle);
    _syncTitle();
    _opened = DesktopWindow.current.openedFiles.listen(_openFiles);
    s.settings.addListener(_onSettings);
    _sections.addListener(_onSection);
    _life = AppLifecycleListener(
      onPause: () {
        _dock.flush();
        // Code typed in Build is saved before Android may stop the app in the background.
        unawaited(s.saveCppWorkbenches());
        s.lifecycle(foreground: false);
      },
      onResume: () => s.lifecycle(foreground: true),
      onExitRequested: () async {
        await _dock.flush();
        await s.saveCppWorkbenches();
        await s.flush();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    s.removeListener(_syncTitle);
    unawaited(_opened?.cancel());
    s.settings.removeListener(_onSettings);
    _life.dispose();
    _dock.dispose();
    _sections.removeListener(_onSection);
    _sections.dispose();
    super.dispose();
  }

  /// On desktop a section change (an "open in Build" from another screen) shows its docked panel.
  void _onSection() {
    final now = _sections.current;
    if (now == _lastSection) return;
    _lastSection = now;
    if (_dock.form == FormFactor.desktop) _dock.reveal(panelOfSection(now));
  }

  /// A change of frame while running (Settings › Layout, a rotation, a window or display change): the section in
  /// front stays in front. Desktop shows its docked panel; a phone shows the section of the panel last used.
  void _switchForm(FormFactor form) {
    final was = _dock.form;
    _dock.form = form;
    if (!_homeShown) return;
    // After this frame: both notify listeners that are being built now.
    if (form == FormFactor.desktop) {
      final section = _sections.current;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _dock.form == FormFactor.desktop) _dock.reveal(panelOfSection(section));
      });
    } else if (was == FormFactor.desktop) {
      final section = sectionOfPanel(_dock.keyPanel);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && section != null && _dock.form != FormFactor.desktop) _sections.show(section);
      });
    }
  }

  /// Opens the selected pattern in Build (Arrange's "Open in Sounds" on a clip).
  void _openPattern() {
    final id = s.selectedModuleId;
    id == null || !s.isPattern(id)
        ? _sections.show(Section.build)
        : _sections.openBuild(BuildTab(BuildTabKind.pattern, id));
    if (_dock.form == FormFactor.desktop) _dock.reveal(Panels.builder);
  }

  /// Shows [panel]: docked on desktop; on a phone its section.
  void _reveal(BuildContext context, String panel) {
    if (_dock.form == FormFactor.desktop) return _dock.reveal(panel);
    final section = sectionOfPanel(panel);
    if (section != null) _sections.show(section);
  }

  Map<String, Widget> _screens() => {
        Panels.builder: BuildSection(state: s),
        Panels.arrangement: ArrangerScreen(
          state: s,
          onOpenPattern: _openPattern,
          onOpenModule: (id) {
            s.selectModule(id);
            _openPattern();
          },
        ),
        Panels.files: FileManagerScreen(state: s, onOpenBuilder: _openPattern),
      };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: s,
        builder: (context, _) {
          if (!s.ready) return const Scaffold(body: Center(child: CrowLogo(size: 64)));
          // Build opens on its start page (what it is for, new code, examples) until something is opened.
          // Built once per app-state change; a layout change (a divider drag, a tab) reuses them, so it rebuilds
          // only the dock, not the screens.
          final screens = _screens();
          return SectionScope(
            controller: _sections,
            child: DockScope(
              controller: _dock,
              child: GlassStrainWatcher(
                state: s,
                child: Scaffold(
                  // Phones draw edge to edge (owner, 2026-11-10): the bars' backgrounds reach under the system bars
                  // and the camera cutout, and each part pads its controls clear of them. Desktop keeps a safe area.
                  body: Builder(builder: (context) {
                    final pad = MediaQuery.paddingOf(context);
                    return LayoutBuilder(builder: (context, box) {
                      final room = pad.deflateSize(box.biggest);
                      final form = formFactorFor(room, mode: _layoutMode);
                      _dock.narrow = formFactorFor(room) != FormFactor.desktop;
                      if (form != _dock.form) _switchForm(form);
                      SystemBars.apply(fullScreen: _dock.form == FormFactor.phoneLandscape);
                      if (!_homeShown) {
                        _homeShown = true;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted && _dock.form == FormFactor.desktop) _dock.reveal(Panels.arrangement);
                        });
                      }
                      return ListenableBuilder(
                        listenable: Listenable.merge([_dock, _sections]),
                        builder: (context, _) => KeyRouter(
                          state: s,
                          screenArea: _dock.form == FormFactor.desktop
                              ? _areaOf(_dock.keyPanel)
                              : _areaOf(panelOfSection(_sections.current)),
                          onView: (i) => _reveal(context, _viewPanels[i]),
                          onExport: () => showExportPage(context, s),
                          child: _dock.form == FormFactor.desktop
                              ? SafeArea(child: _desktop(context, screens))
                              : _phone(context, screens, pad, landscape: _dock.form == FormFactor.phoneLandscape),
                        ),
                      );
                    });
                  }),
                ),
              ),
            ),
          );
        },
      );

  /// What the transport shows from the app state: it rebuilds only when one of these changes (frame_widgets.dart,
  /// Selected), not on every app-state change.
  Object _transportLook() => (s.transportOn, s.canUndo, s.canRedo, s.pausedStep, s.project, s.project.bpm,
      s.project.name, LiveMidi.current, AutomationWriter.current);

  Widget? _banner() {
    final error = s.engineError ?? s.audioError ?? s.openError;
    // A note about the project just opened (its .caw sounds were left out), one line, until the next project opens.
    final notice = error == null ? s.openNotice : null;
    // Files the project plays that aren't here: one line with Locate… and Replace… (project_file_actions.dart).
    if (error == null && notice == null && s.missingFiles.isNotEmpty) return MissingFilesBanner(state: s);
    if (error == null && notice == null) return null;
    final color = error != null ? Neon.pink : Neon.yellow;
    return Container(
      key: ValueKey(error != null ? 'banner-error' : 'banner-notice'),
      width: double.infinity,
      color: color.withValues(alpha: 0.15),
      padding: const EdgeInsets.all(8),
      child: Text(error ?? notice!, maxLines: error != null ? null : 1, overflow: error != null ? null : TextOverflow.ellipsis,
          style: TextStyle(color: color)),
    );
  }

  /// Desktop and tablets: the rail, the transport bar and the docking panels.
  Widget _desktop(BuildContext context, Map<String, Widget> screens) => Row(children: [
        Selected(
          select: () => sectionOfPanel(_dock.keyPanel),
          builder: (_) => SectionRail(
            current: sectionOfPanel(_dock.keyPanel),
            onSelect: (section) {
              _sections.show(section);
              _dock.reveal(panelOfSection(section));
            },
          ),
        ),
        Expanded(
          child: Column(children: [
            Selected(select: _transportLook, builder: (_) => _TransportBar(state: s, dock: _dock)),
            ?_banner(),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => Stack(children: [
                  Positioned.fill(
                    child: DockView(
                      layout: _dock.layout,
                      onChanged: _dock.set,
                      onFloat: _dock.float,
                      panelBuilder: (_, id) => Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: (_) => _dock.touch(id),
                        child: screens[id] ?? const SizedBox.shrink(),
                      ),
                    ),
                  ),
                  // Panels floating over the layout, front last.
                  for (final f in _dock.floating)
                    FloatingWindow(
                      key: ValueKey('float-${f.id}'),
                      panel: f,
                      area: box.biggest,
                      title: dockPanelTitle(f.id),
                      onPlace: (r, {save = true}) => _dock.placeFloating(f.id, r, save: save),
                      onDock: () => _dock.unfloat(f.id),
                      onRaise: () {
                        _dock.touch(f.id);
                        _dock.raise(f.id);
                      },
                      child: screens[f.id] ?? const SizedBox.shrink(),
                    ),
                ]),
              ),
            ),
            // The on-screen keys and pads slide up from the bottom edge here.
            if (LiveMidi.current case final m?)
              TakeToast(midi: m, child: AudioRecordFeedback(state: s, child: LiveKeysPanel(midi: m, state: s))),
          ]),
        ),
      ]);

  /// Phones: one section at a time. Portrait has the status row on top and the transport and section bar at the
  /// bottom (both hide while the keyboard is open); landscape has a narrow rail on the left with the project and More,
  /// the tempo and CPU in the transport, and no status row, so the tracks get the height (owner, 2026-11-10). The
  /// top bars hide when their grip is pulled up and come back when it is pulled down (or its tab tapped).
  Widget _phone(BuildContext context, Map<String, Widget> screens, EdgeInsets pad, {required bool landscape}) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom > 0;
    // The content is padded clear of the edges here, so the screens inside see no padding of their own.
    final content = MediaQuery.removePadding(
      context: context,
      removeLeft: true,
      removeTop: true,
      removeRight: true,
      removeBottom: true,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) {
          if (_reach) setState(() => _reach = false);
        },
        child: SectionSwitcher(
          index: sectionOrder.indexOf(_sections.current),
          children: [
            for (final section in sectionOrder) screens[panelOfSection(section)] ?? const SizedBox.shrink(),
          ],
        ),
      ),
    );
    // The top bars hide only on a deliberate pull of this grip (owner, 2026-11-10); in landscape only Arrange has a
    // bar to hide (its toolbar). It hides while the keyboard is open, which keeps the bars shown.
    final grip = !keyboard && !_reach && (!landscape || _sections.current == Section.arrange);
    final body = !grip ? content : Stack(children: [
      Positioned.fill(child: content),
      Positioned(top: 0, left: 0, right: 0, child: Center(child: BarsHandle(sections: _sections))),
    ]);
    if (landscape) {
      final small = IconButton.styleFrom(iconSize: 18, visualDensity: VisualDensity.compact,
          minimumSize: const Size(34, 34), padding: const EdgeInsets.all(6));
      return Theme(
        // Compact landscape: smaller icons and denser controls everywhere in it.
        data: Theme.of(context).copyWith(
          visualDensity: VisualDensity.compact,
          iconButtonTheme: IconButtonThemeData(style: small.merge(Theme.of(context).iconButtonTheme.style)),
        ),
        child: Row(children: [
          Selected(select: () => (_sections.current, pad, s.project.name), builder: (_) => SectionRail(
            compact: true,
            inset: EdgeInsets.only(left: pad.left, top: pad.top, bottom: pad.bottom),
            current: _sections.current,
            onSelect: _sections.show,
            top: Tooltip(
              message: '${s.project.name}: project menu',
              child: InkWell(
                key: const ValueKey('project-menu'),
                onTap: () => showProjectMenu(context, s),
                child: const Pressable(child: SizedBox(height: 40, child: Center(child: CrowLogo(size: 22)))),
              ),
            ),
          )),
          Expanded(
            child: Column(children: [
              SizedBox(height: pad.top),
              ?_banner(),
              Expanded(child: Padding(padding: EdgeInsets.only(right: pad.right), child: body)),
              if (!keyboard)
                Selected(select: () => (_transportLook(), pad), builder: (_) => BottomTransport(
                  state: s,
                  midi: LiveMidi.current,
                  compact: true,
                  inset: EdgeInsets.only(right: pad.right, bottom: pad.bottom),
                  extras: [
                    _BpmButton(state: s),
                    const SizedBox(width: 8),
                    _CpuReadout(state: s),
                    const SizedBox(width: 8),
                  ],
                )),
            ]),
          ),
        ]),
      );
    }
    final status = Selected(select: () => (s.project, s.project.name, s.project.bpm),
        builder: (_) => _StatusRow(state: s));
    final bar = Glass.active ? Neon.panel.withValues(alpha: 0.6) : Neon.panel;
    return Column(children: [
      // The system status bar's strip keeps the bar colour; the status row tucks away under it.
      if (pad.top > 0) Container(height: pad.top, color: bar),
      if (!_reach)
        ValueListenableBuilder<bool>(
          valueListenable: _sections.barsShown,
          builder: (context, shown, child) => TuckAway(shown: shown || keyboard, child: child!),
          child: status,
        ),
      ?_banner(),
      Expanded(child: Padding(padding: EdgeInsets.only(left: pad.left, right: pad.right), child: body)),
      if (_reach) status,
      if (!keyboard) ...[
        Selected(select: () => (_transportLook(), pad), builder: (_) =>
            BottomTransport(state: s, midi: LiveMidi.current, inset: EdgeInsets.only(left: pad.left, right: pad.right))),
        Selected(select: () => (_sections.current, pad.bottom), builder: (_) =>
            SectionBar(sections: _sections, bottomInset: pad.bottom, onReach: () => setState(() => _reach = true))),
      ],
    ]);
  }
}

/// The phone's slim top row: the project (tap for its menu, Export among it), the tempo, and CPU.
class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final p = state.project;
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: Glass.active
          ? BoxDecoration(
              color: Neon.panel.withValues(alpha: 0.6),
              border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
            )
          : const BoxDecoration(color: Neon.panel, border: Border(bottom: BorderSide(color: Neon.line))),
      child: Row(children: [
        const CrowLogo(size: 22),
        const SizedBox(width: 6),
        Expanded(
          child: InkWell(
            key: const ValueKey('project-menu'),
            borderRadius: BorderRadius.circular(8),
            onTap: () => showProjectMenu(context, state),
            child: Pressable(child: Row(children: [
              Flexible(
                child: Text(p.name,
                    overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              ),
              const Icon(Icons.arrow_drop_down, color: Neon.dim, size: 18),
            ])),
          ),
        ),
        _BpmButton(state: state),
        const SizedBox(width: 8),
        _CpuReadout(state: state),
        const SizedBox(width: 8),
      ]),
    );
  }
}

/// The engine's CPU load, in percent; pink over 85%.
class _CpuReadout extends StatelessWidget {
  const _CpuReadout({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => SizedBox(
        // A live island (widgets.dart) of a fixed size: read about 30 times a second while playing, it rebuilds, lays
        // out and repaints alone, not the bar around it.
        width: 58,
        height: 16,
        child: LiveIsland(
          child: ValueListenableBuilder<int>(
            valueListenable: state.tick,
            builder: (context, _, _) {
              final cpu = (state.meters.cpu * 100).clamp(0, 999).toStringAsFixed(0);
              return Align(
                alignment: Alignment.centerRight,
                child: Text('CPU $cpu%', maxLines: 1, softWrap: false,
                    style: Neon.code(size: 11, color: state.meters.cpu > 0.85 ? Neon.pink : Neon.dim)),
              );
            },
          ),
        ),
      );
}

/// The layout menu: the presets, and every panel (tap to show it).
Future<void> showLayoutMenu(BuildContext context, DockController dock) => showGlassSheet<void>(
      context: context,
      backgroundColor: Neon.panel,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(sheet).size.height * 0.75),
          child: ListView(shrinkWrap: true, children: [
            const Heading('Layout'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: SegmentedButton<DockPreset>(
                showSelectedIcon: false,
                emptySelectionAllowed: true,
                segments: const [
                  ButtonSegment(value: DockPreset.arrange, label: Text('Arrange')),
                  ButtonSegment(value: DockPreset.code, label: Text('Code')),
                ],
                selected: const {},
                onSelectionChanged: (v) {
                  Navigator.pop(sheet);
                  dock.usePreset(v.first);
                },
              ),
            ),
            const Heading('Panels'),
            for (final id in Panels.all)
              ListTile(
                leading: Icon(_panelIcon(id), color: dock.layout.visible.contains(id) ? Neon.green : Neon.dim),
                title: Text(dockPanelTitle(id)),
                subtitle: dock.layout.contains(id) ? null : const Text('Closed', style: TextStyle(color: Neon.dim)),
                selected: dock.layout.visible.contains(id),
                onTap: () {
                  Navigator.pop(sheet);
                  dock.reveal(id);
                },
              ),
          ]),
        ),
      ),
    );

IconData _panelIcon(String id) => switch (id) {
      Panels.builder => Icons.code,
      Panels.arrangement => Icons.view_timeline,
      Panels.files => Icons.folder_open,
      _ => Icons.dashboard,
    };

class _TransportBar extends StatelessWidget {
  const _TransportBar({required this.state, required this.dock});
  final AppState state;
  final DockController dock;

  @override
  Widget build(BuildContext context) {
    final p = state.project;
    final playing = state.transportOn;
    return Container(
      padding: EdgeInsets.fromLTRB(10, Neon.compact(context) ? 3 : 6, 10, Neon.compact(context) ? 3 : 6),
      // Glass: see-through over the backdrop, with a thin bright edge underneath.
      decoration: Glass.active
          ? BoxDecoration(
              color: Neon.panel.withValues(alpha: 0.6),
              border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
            )
          : const BoxDecoration(color: Neon.panel, border: Border(bottom: BorderSide(color: Neon.line))),
      // Desktop on a phone (Settings › Layout) can make the bar narrow: the project name then keeps a modest width and
      // the readouts and buttons scroll sideways instead of overflowing.
      child: LayoutBuilder(builder: (context, box) {
        final narrow = box.maxWidth < 720;
        Widget name(Widget c) =>
            narrow ? ConstrainedBox(constraints: const BoxConstraints(maxWidth: 120), child: c) : Expanded(child: c);
        final tail = <Widget>[
          Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
            _BpmButton(state: state),
            // The position and CPU change about 30 times a second while playing: a live island (widgets.dart).
            SizedBox(width: 170, height: 15, child: LiveIsland(child: ValueListenableBuilder<int>(
              valueListenable: state.tick,
              builder: (context, _, _) {
                final m = state.meters;
                final cpu = (m.cpu * 100).clamp(0, 999).toStringAsFixed(0);
                // Paused, it shows where play will resume.
                return Align(alignment: Alignment.centerRight, child: Text(maxLines: 1, softWrap: false, m.playing
                    ? '${transportPosition(m.position, m.loopLength, p.engineLoopSteps, p.stepsPerBar)} · CPU $cpu%'
                    : state.pausedStep != null
                        ? '${transportPosition(state.pausedStep!, p.engineLoopSteps, p.engineLoopSteps, p.stepsPerBar)} paused'
                          ' · CPU $cpu%'
                    : 'CPU $cpu%',
                    style: Neon.code(size: 11, color: m.cpu > 0.85 ? Neon.pink : Neon.dim)));
              },
            ))),
          ]),
          // Undo and redo of project edits (Ctrl+Z, Ctrl+Shift+Z); an editor with its own history keeps its keys.
          Pressable(child: IconButton(
            key: const ValueKey('transport-undo'),
            tooltip: 'Undo (Ctrl+Z)',
            color: Neon.text,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 44),
            icon: const Icon(Icons.undo),
            onPressed: state.canUndo ? state.undo : null,
          )),
          Pressable(child: IconButton(
            key: const ValueKey('transport-redo'),
            tooltip: 'Redo (Ctrl+Shift+Z)',
            color: Neon.text,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 44),
            icon: const Icon(Icons.redo),
            onPressed: state.canRedo ? state.redo : null,
          )),
          Pressable(child: IconButton(
            tooltip: 'Layout and panels',
            color: Neon.dim,
            icon: const Icon(Icons.dashboard_customize),
            onPressed: () => showLayoutMenu(context, dock),
          )),
          if (AutomationWriter.current case final w?) AutomateButton(writer: w, state: state, size: 40),
          if (LiveMidi.current case final m?) KeysButton(midi: m),
          // Only while there is somewhere to stop from, so a phone's transport keeps room for the project name.
          if (playing || state.pausedStep != null) Pressable(child: IconButton(
            key: const ValueKey('transport-stop'),
            tooltip: 'Stop, back to the start (Shift+Space)',
            color: Neon.green,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 44),
            icon: const Icon(Icons.stop),
            onPressed: state.stopPlayback,
          )),
          Tooltip(
            message: playing ? 'Pause (Space)' : state.pausedStep != null ? 'Resume (Space)' : 'Play (Space)',
            child: InkWell(
              borderRadius: BorderRadius.circular(28),
              onTap: () {
                Haptics.tap();
                state.togglePlay();
              },
              child: Pressable(circle: true, child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: playing ? Neon.green : Colors.transparent,
                  border: Border.all(color: Neon.green, width: 2),
                  boxShadow: Neon.glow(Neon.green, strength: playing ? 0.8 : 0.3),
                ),
                child: Icon(playing ? Icons.pause : Icons.play_arrow, color: playing ? Neon.bg : Neon.green, size: 30),
              )),
            ),
          ),
          RecordButton(midi: LiveMidi.current, state: state),
        ];
        return Row(children: [
          const CrowLogo(size: 30),
          const SizedBox(width: 8),
          name(
            InkWell(
              onTap: () => showProjectMenu(context, state),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                const Text('C.A.W', style: TextStyle(fontSize: 11, letterSpacing: 2, color: Neon.dim, fontWeight: FontWeight.w800)),
                Row(children: [
                  Flexible(
                    child: Text(p.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                  const Icon(Icons.arrow_drop_down, color: Neon.dim),
                ]),
              ]),
            ),
          ),
          if (narrow)
            Expanded(child: SingleChildScrollView(scrollDirection: Axis.horizontal, reverse: true,
                child: Row(mainAxisSize: MainAxisSize.min, children: tail)))
          else
            ...tail,
        ]);
      }),
    );
  }
}

/// The playhead as bar.beat ("2.3"), counting from 1: [position] of [loopLength] (engine units) over the engine's
/// loop of [loopSteps] sixteenth steps (`engineLoopSteps`: the loop grows to cover the arrangement), [stepsPerBar] to
/// the bar.
String transportPosition(num position, num loopLength, int loopSteps, int stepsPerBar) {
  if (loopLength <= 0 || loopSteps <= 0 || stepsPerBar <= 0) return '1.1';
  // A read during the wrap can land on the end itself: that is still the last step.
  final step = (position / (loopLength / loopSteps)).floor().clamp(0, loopSteps - 1);
  return '${step ~/ stepsPerBar + 1}.${(step % stepsPerBar) ~/ 4 + 1}';
}

/// A typed tempo: a finite number, clamped to the engine's 20 to 400 BPM and rounded to 0.1; null if not.
double? parseBpm(String text) {
  final v = double.tryParse(text.trim().replaceAll(',', '.'));
  if (v == null || !v.isFinite) return null;
  return double.parse(v.clamp(20.0, 400.0).toStringAsFixed(1));
}

String _bpmText(double bpm) => bpm.toStringAsFixed(bpm == bpm.roundToDouble() ? 0 : 1);

/// The transport's tempo (#19): tap to type it, long-press for a tap-tempo pad. The T key taps too; both use
/// [AppState.tapTempo].
class _BpmButton extends StatelessWidget {
  const _BpmButton({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final bpm = state.project.bpm;
    void type() => typeValue(context,
        title: 'Tempo (20 to 400 BPM)',
        initial: _bpmText(bpm),
        parse: parseBpm,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        apply: (v) => state.editProject((p) => p.bpm = v));
    void pad() => showDialogOrSheet<void>(context: context, builder: (_) => _TapTempoPad(state: state));
    // A screen reader gets both actions: double-tap types, a long-press opens the pad.
    return Semantics(
      button: true,
      label: 'Tempo ${_bpmText(bpm)} BPM',
      hint: 'Type the tempo',
      onTap: type,
      onLongPress: pad,
      onLongPressHint: 'Tap tempo',
      excludeSemantics: true,
      child: Tooltip(
        message: '${PointerInput.tapCap} to type the tempo, ${PointerInput.hold} to tap it (T)',
        child: InkWell(
          key: const ValueKey('transport-bpm'),
          onTap: type,
          onLongPress: pad,
          onSecondaryTap: pad,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text('${_bpmText(bpm)} BPM', style: Neon.code(size: 14, color: Neon.blue)),
          ),
        ),
      ),
    );
  }
}

/// Tap in time on the big pad; the tempo follows. A pause of over two seconds starts a new measurement.
class _TapTempoPad extends StatelessWidget {
  const _TapTempoPad({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
      // The dialog is outside the key router, so T taps here too (Space and Enter press the focused pad).
      bindings: {const SingleActivator(LogicalKeyboardKey.keyT): state.tapTempo},
      child: AlertDialog(
        title: const Text('Tap tempo'),
        content: ListenableBuilder(
          listenable: state,
          builder: (context, _) => Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${_bpmText(state.project.bpm)} BPM', style: Neon.code(size: 22, color: Neon.blue)),
            const SizedBox(height: 12),
            SizedBox(
              width: 200,
              height: 120,
              child: FilledButton(
                key: const ValueKey('tap-pad'),
                autofocus: true,
                onPressed: () {
                  Haptics.tap();
                  state.tapTempo();
                },
                child: const Text('TAP', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
              ),
            ),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Done'))],
      ));
}

Future<void> showProjectMenu(BuildContext context, AppState s) async {
  final projects = await s.listProjects();
  if (!context.mounted) return;
  final keys = KeyRouter.of(context); // the sheet's own context is outside the router
  final outer = context; // for what opens after the sheet closes
  await showGlassSheet<void>(
    context: context,
    backgroundColor: Neon.panel,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
        child: ListView(shrinkWrap: true, children: [
          const Heading('Project'),
          ListTile(
            leading: const Icon(Icons.edit, color: Neon.blue),
            title: const Text('Rename'),
            onTap: () async {
              Navigator.pop(context);
              final c = TextEditingController(text: s.project.name);
              final name = await showDialog<String>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Rename project'),
                  content: TextField(controller: c, autofocus: true, onSubmitted: (v) => Navigator.pop(context, v)),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Rename')),
                  ],
                ),
              );
              if (name != null && name.trim().isNotEmpty) s.editProject((p) => p.name = name.trim());
            },
          ),
          ListTile(
            leading: const Icon(Icons.add, color: Neon.green),
            title: const Text('New project'),
            subtitle: Text(
                switch (s.templateById(s.settings.newProjectTemplate)) {
                  final t? => 'From the ${t.name} template (Settings › Projects and files)',
                  null => 'Blank, ${s.settings.newProjectBpm.toStringAsFixed(0)} BPM, ${s.settings.newProjectBeatsPerBar}/4',
                },
                style: const TextStyle(color: Neon.dim)),
            onTap: () {
              Navigator.pop(context);
              s.newProject();
            },
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome_mosaic, color: Neon.green),
            title: const Text('New from template…'),
            subtitle: const Text('The starters and the templates you saved', style: TextStyle(color: Neon.dim)),
            onTap: () {
              Navigator.pop(context);
              if (outer.mounted) showProjectTemplates(outer, s);
            },
          ),
          ListTile(
            leading: const Icon(Icons.bookmark_add_outlined, color: Neon.blue),
            title: const Text('Save as template…'),
            onTap: () {
              Navigator.pop(context);
              if (outer.mounted) saveProjectTemplate(outer, s);
            },
          ),
          ListTile(
            key: const ValueKey('project-export'),
            leading: const Icon(Icons.ios_share, color: Neon.yellow),
            title: const Text('Export…'),
            subtitle: const Text('The song or stems, a loop, a one-shot, a wavetable or MIDI',
                style: TextStyle(color: Neon.dim)),
            onTap: () {
              Navigator.pop(context);
              if (outer.mounted) showExportPage(outer, s);
            },
          ),
          ListTile(
            key: const ValueKey('project-export-file'),
            leading: const Icon(Icons.file_upload_outlined, color: Neon.yellow),
            title: const Text('Export project…'),
            subtitle: const Text('A .caw file, with the samples, builds, presets and theme you tick',
                style: TextStyle(color: Neon.dim)),
            onTap: () {
              Navigator.pop(context);
              if (outer.mounted) exportPortableProject(outer, s);
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy, color: Neon.yellow),
            title: const Text('Duplicate'),
            onTap: () {
              Navigator.pop(context);
              s.duplicateProject();
            },
          ),
          ListTile(
            leading: const Icon(Icons.settings, color: Neon.dim),
            title: const Text('Settings…'),
            subtitle: const Text('Audio, MIDI, recording, editing, look, projects, export and more',
                style: TextStyle(color: Neon.dim)),
            onTap: () async {
              final nav = Navigator.of(context);
              nav.pop();
              await nav.push(MaterialPageRoute<void>(settings: closablePage, builder: (_) => GlassPage(child: SettingsPage(settings: s.settings, state: s,
                  engineProfile: s.hardwareProfile, executionPlan: s.auditionPlan,
                  onEditKeys: keys == null ? null : (c) => keys.showKeyBindings(c)))));
              s.settings.commitLook();
            },
          ),
          const Heading('Open'),
          for (final p in projects)
            ListTile(
              selected: p.id == s.project.id,
              title: Text(p.name),
              subtitle: Text(p.modified.toLocal().toString().substring(0, 16), style: const TextStyle(color: Neon.dim)),
              onTap: () {
                Navigator.pop(context);
                s.openProject(p.id);
              },
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, color: Neon.pink),
                tooltip: 'Delete',
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text('Delete ${p.name}?'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                        TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Delete', style: TextStyle(color: Neon.pink))),
                      ],
                    ),
                  );
                  if (ok == true && context.mounted) {
                    Navigator.pop(context);
                    await s.deleteProject(p.id);
                  }
                },
              ),
            ),
        ]),
      ),
    ),
  );
}

/// The crow mark: a faceted black-glass crow head with a feather sheen, a neon-green beak edge and a pink eye.
/// Its source drawing is `assets/logo/caw_mark.svg`; the launcher icons are rendered from `caw_icon.svg`.
class CrowLogo extends StatelessWidget {
  const CrowLogo({super.key, this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) => Image.asset('assets/logo/caw_mark.png',
      width: size, height: size, filterQuality: FilterQuality.medium, semanticLabel: 'C.A.W.');
}
