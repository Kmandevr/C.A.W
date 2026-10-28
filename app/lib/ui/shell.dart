// App shell: the crow logo, transport bar (play, BPM, CPU), project menu and navigation between the three areas.
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../model/app_state.dart';
import 'arranger_screen.dart';
import 'builder_screen.dart';
import 'exporter_screen.dart';
import 'startup_screen.dart';
import 'theme.dart';
import 'theme_editor.dart';
import 'widgets.dart';

/// The open area, kept when the shell is rebuilt after a theme change.
int _lastTab = 1;

class Shell extends StatefulWidget {
  const Shell({super.key, required this.state});
  final AppState state;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = _lastTab;
  late final AppLifecycleListener _life;

  AppState get s => widget.state;

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(
      onPause: () => s.lifecycle(foreground: false),
      onResume: () => s.lifecycle(foreground: true),
      onExitRequested: () async {
        await s.flush();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _lastTab = _tab;
  }

  bool _editingText() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx != null && (ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  KeyEventResult _key(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey == LogicalKeyboardKey.space && !_editingText()) {
      s.togglePlay();
      return KeyEventResult.handled;
    }
    final ctrl = HardwareKeyboard.instance.isControlPressed || HardwareKeyboard.instance.isMetaPressed;
    final digit = [LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3].indexOf(e.logicalKey);
    if (ctrl && digit >= 0) {
      setState(() => _tab = digit);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  static const _dest = [
    (Icons.code, 'Builder'),
    (Icons.layers, 'Arranger'),
    (Icons.ios_share, 'Exporter'),
  ];

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: s,
        builder: (context, _) {
          if (!s.ready) return const Scaffold(body: Center(child: CrowLogo(size: 64)));
          if (s.starting) return StartupScreen(state: s);
          final screens = [
            BuilderScreen(state: s),
            ArrangerScreen(state: s),
            ExporterScreen(state: s),
          ];
          return LayoutBuilder(builder: (context, box) {
            final wide = box.maxWidth >= 900;
            final body = Column(children: [
              _TransportBar(state: s),
              if (s.engineError != null || s.audioError != null)
                Container(
                  width: double.infinity,
                  color: Neon.pink.withValues(alpha: 0.15),
                  padding: const EdgeInsets.all(8),
                  child: Text(s.engineError ?? s.audioError!, style: const TextStyle(color: Neon.pink)),
                ),
              Expanded(child: IndexedStack(index: _tab, children: screens)),
            ]);
            return Focus(
              autofocus: true,
              onKeyEvent: _key,
              child: Scaffold(
                body: SafeArea(
                  child: wide
                      ? Row(children: [
                          NavigationRail(
                            selectedIndex: _tab,
                            labelType: NavigationRailLabelType.all,
                            onDestinationSelected: (i) => setState(() => _tab = i),
                            destinations: [
                              for (final d in _dest) NavigationRailDestination(icon: Icon(d.$1), label: Text(d.$2)),
                            ],
                          ),
                          const VerticalDivider(width: 1),
                          Expanded(child: body),
                        ])
                      : body,
                ),
                bottomNavigationBar: wide
                    ? null
                    : NavigationBar(
                        height: Neon.compact(context) ? 52 : 64,
                        selectedIndex: _tab,
                        onDestinationSelected: (i) => setState(() => _tab = i),
                        destinations: [for (final d in _dest) NavigationDestination(icon: Icon(d.$1), label: d.$2)],
                      ),
              ),
            );
          });
        },
      );
}

class _TransportBar extends StatelessWidget {
  const _TransportBar({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final p = state.project;
    final playing = state.meters.playing;
    return Container(
      padding: EdgeInsets.fromLTRB(10, Neon.compact(context) ? 3 : 6, 10, Neon.compact(context) ? 3 : 6),
      decoration: const BoxDecoration(color: Neon.panel, border: Border(bottom: BorderSide(color: Neon.line))),
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
        const SizedBox(width: 10),
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
  await showModalBottomSheet<void>(
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
              await nav.push(MaterialPageRoute<void>(builder: (_) => SettingsPage(settings: s.settings)));
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
