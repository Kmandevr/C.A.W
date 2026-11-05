// App shell: transport, project menu, and the eight workspaces as docking panels (one layout per screen shape).
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../actions/actions.dart';
import '../model/app_state.dart';
import 'arranger_screen.dart';
import 'builder_screen.dart';
import 'exporter_screen.dart';
import 'mixer_screen.dart';
import 'automation_screen.dart';
import 'dock/dock_controller.dart';
import 'dock/dock_view.dart';
import 'dock/layout.dart';
import 'engine_lab_screen.dart';
import 'file_manager_screen.dart';
import 'plugin_builder_screen.dart';
import 'key_router.dart';
import 'theme.dart';
import 'theme_editor.dart';
import 'widgets.dart';
import 'glass.dart';

/// The panel each view shortcut shows, by the index KeyRouter's `onView` passes.
const _viewPanels = [
  Panels.builder,
  Panels.arrangement,
  Panels.mixer,
  Panels.engineLab,
  Panels.automation,
  Panels.exporter,
  Panels.files,
  Panels.pluginBuilder,
];

/// The keyboard area of each panel.
Area _areaOf(String panel) => switch (panel) {
      Panels.builder => Area.builder,
      Panels.arrangement => Area.arranger,
      Panels.exporter => Area.exporter,
      _ => Area.global,
    };

/// The screen shape that keeps its own layout, from the shell's size.
FormFactor formFactorFor(Size size) => size.width >= 900
    ? FormFactor.desktop
    : size.width > size.height
        ? FormFactor.phoneLandscape
        : FormFactor.phonePortrait;

class Shell extends StatefulWidget {
  const Shell({super.key, required this.state});
  final AppState state;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  late final AppLifecycleListener _life;
  late final DockController _dock = DockController(s.settings);

  // The arrangement is home (UI plan U1): shown in front once at launch, whatever panel the saved layout had there.
  bool _homeShown = false;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(
      onPause: () {
        _dock.flush();
        s.lifecycle(foreground: false);
      },
      onResume: () => s.lifecycle(foreground: true),
      onExitRequested: () async {
        await _dock.flush();
        await s.flush();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _life.dispose();
    _dock.dispose();
    super.dispose();
  }

  void _openBuilder() => _dock.reveal(Panels.builder);

  Map<String, Widget> _screens() => {
        Panels.builder: BuilderScreen(state: s),
        Panels.arrangement: ArrangerScreen(
          state: s,
          onOpenPattern: _openBuilder,
          onOpenModule: (id) {
            s.selectModule(id);
            _openBuilder();
          },
        ),
        Panels.mixer: MixerScreen(state: s, onOpenBuilder: _openBuilder),
        Panels.engineLab: EngineLabScreen(state: s, onOpenBuilder: _openBuilder),
        Panels.automation: AutomationScreen(state: s),
        Panels.exporter: ExporterScreen(state: s),
        Panels.files: FileManagerScreen(state: s, onOpenBuilder: _openBuilder),
        Panels.pluginBuilder: PluginBuilderScreen(state: s, onOpenBuilder: _openBuilder),
      };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: s,
        builder: (context, _) {
          if (!s.ready) return const Scaffold(body: Center(child: CrowLogo(size: 64)));
          // Built once per app-state change; a layout change (a divider drag, a tab) reuses them, so it rebuilds
          // only the dock, not the screens.
          final screens = _screens();
          return DockScope(
            controller: _dock,
            child: Scaffold(
              body: SafeArea(
                child: LayoutBuilder(builder: (context, box) {
                  _dock.form = formFactorFor(box.biggest);
                  if (!_homeShown) {
                    _homeShown = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _dock.reveal(Panels.arrangement);
                    });
                  }
                  return ListenableBuilder(
                    listenable: _dock,
                    builder: (context, _) => KeyRouter(
                      state: s,
                      screenArea: _areaOf(_dock.keyPanel),
                      onView: (i) => _dock.reveal(_viewPanels[i]),
                      child: Column(children: [
                        _TransportBar(state: s, dock: _dock),
                        if (s.engineError != null || s.audioError != null || s.openError != null)
                          Container(
                            width: double.infinity,
                            color: Neon.pink.withValues(alpha: 0.15),
                            padding: const EdgeInsets.all(8),
                            child: Text(s.engineError ?? s.audioError ?? s.openError!,
                                style: const TextStyle(color: Neon.pink)),
                          ),
                        Expanded(
                          child: DockView(
                            layout: _dock.layout,
                            onChanged: _dock.set,
                            panelBuilder: (_, id) => Listener(
                              behavior: HitTestBehavior.translucent,
                              onPointerDown: (_) => _dock.touch(id),
                              child: screens[id] ?? const SizedBox.shrink(),
                            ),
                          ),
                        ),
                      ]),
                    ),
                  );
                }),
              ),
            ),
          );
        },
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
                  ButtonSegment(value: DockPreset.mix, label: Text('Mix')),
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
      Panels.mixer => Icons.tune,
      Panels.engineLab => Icons.account_tree,
      Panels.automation => Icons.show_chart,
      Panels.exporter => Icons.ios_share,
      Panels.files => Icons.folder_open,
      Panels.pluginBuilder => Icons.extension,
      _ => Icons.dashboard,
    };

class _TransportBar extends StatelessWidget {
  const _TransportBar({required this.state, required this.dock});
  final AppState state;
  final DockController dock;

  @override
  Widget build(BuildContext context) {
    final p = state.project;
    final playing = state.meters.playing;
    return Container(
      padding: EdgeInsets.fromLTRB(10, Neon.compact(context) ? 3 : 6, 10, Neon.compact(context) ? 3 : 6),
      // Glass: see-through over the backdrop, with a thin bright edge underneath.
      decoration: Glass.active
          ? BoxDecoration(
              color: Neon.panel.withValues(alpha: 0.6),
              border: Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
            )
          : const BoxDecoration(color: Neon.panel, border: Border(bottom: BorderSide(color: Neon.line))),
      child: Row(children: [
        const CrowLogo(size: 30),
        const SizedBox(width: 8),
        Expanded(
          child: InkWell(
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
        ValueListenableBuilder<int>(
          valueListenable: state.tick,
          builder: (context, _, _) {
            final m = state.meters;
            final cpu = (m.cpu * 100).clamp(0, 999).toStringAsFixed(0);
            final beat = m.playing ? (m.position / (m.loopLength / p.loopSteps) / 4).floor() + 1 : 0;
            return Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
              Text('${p.bpm.toStringAsFixed(p.bpm == p.bpm.roundToDouble() ? 0 : 1)} BPM',
                  style: Neon.code(size: 14, color: Neon.blue)),
              Text(m.playing ? 'beat $beat · CPU $cpu%' : 'CPU $cpu%',
                  style: Neon.code(size: 11, color: m.cpu > 0.85 ? Neon.pink : Neon.dim)),
            ]);
          },
        ),
        IconButton(
          tooltip: 'Layout and panels',
          color: Neon.dim,
          icon: const Icon(Icons.dashboard_customize),
          onPressed: () => showLayoutMenu(context, dock),
        ),
        Tooltip(
          message: playing ? 'Stop (Space)' : 'Play (Space)',
          child: InkWell(
            borderRadius: BorderRadius.circular(28),
            onTap: state.togglePlay,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: playing ? Neon.green : Colors.transparent,
                border: Border.all(color: Neon.green, width: 2),
                boxShadow: Neon.glow(Neon.green, strength: playing ? 0.8 : 0.3),
              ),
              child: Icon(playing ? Icons.stop : Icons.play_arrow, color: playing ? Neon.bg : Neon.green, size: 30),
            ),
          ),
        ),
      ]),
    );
  }
}

Future<void> showProjectMenu(BuildContext context, AppState s) async {
  final projects = await s.listProjects();
  if (!context.mounted) return;
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
            title: const Text('New blank project'),
            onTap: () {
              Navigator.pop(context);
              s.newProject();
            },
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome_mosaic, color: Neon.green),
            title: const Text('New from template'),
            subtitle: const Text('First loop: drums, bass, a byte lead and an acid line', style: TextStyle(color: Neon.dim)),
            onTap: () {
              Navigator.pop(context);
              s.newProjectFromTemplate();
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
            subtitle: const Text('Theme, density, live coding', style: TextStyle(color: Neon.dim)),
            onTap: () async {
              final nav = Navigator.of(context);
              nav.pop();
              await nav.push(MaterialPageRoute<void>(builder: (_) => GlassPage(child: SettingsPage(settings: s.settings))));
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

/// The crow mark, drawn in neon so it needs no image asset.
class CrowLogo extends StatelessWidget {
  const CrowLogo({super.key, this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(width: size, height: size, child: CustomPaint(painter: _CrowPainter()));
}

class _CrowPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final body = Path()
      ..moveTo(0.12 * w, 0.62 * h) // tail
      ..lineTo(0.34 * w, 0.52 * h)
      ..quadraticBezierTo(0.40 * w, 0.30 * h, 0.62 * w, 0.28 * h) // back to head
      ..quadraticBezierTo(0.70 * w, 0.20 * h, 0.78 * w, 0.26 * h) // crown
      ..lineTo(0.96 * w, 0.32 * h) // beak tip
      ..lineTo(0.78 * w, 0.37 * h)
      ..quadraticBezierTo(0.74 * w, 0.62 * h, 0.50 * w, 0.68 * h) // breast
      ..lineTo(0.30 * w, 0.66 * h)
      ..close();
    final legs = Path()
      ..moveTo(0.48 * w, 0.68 * h)
      ..lineTo(0.46 * w, 0.86 * h)
      ..moveTo(0.56 * w, 0.66 * h)
      ..lineTo(0.58 * w, 0.86 * h);
    final glow = Paint()
      ..color = Neon.green.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.09
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, w * 0.06);
    final line = Paint()
      ..color = Neon.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.05
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(body, glow);
    canvas.drawPath(body, Paint()..color = Neon.bg);
    canvas.drawPath(body, line);
    canvas.drawPath(legs, line);
    canvas.drawCircle(Offset(0.72 * w, 0.29 * h), w * 0.035, Paint()..color = Neon.pink);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
