// Startup screen: continue the last project, start a blank one or the "First loop" template, or open a saved one.
import 'package:flutter/material.dart';

import '../model/app_state.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

class StartupScreen extends StatefulWidget {
  const StartupScreen({super.key, required this.state});
  final AppState state;

  @override
  State<StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<StartupScreen> {
  bool _busy = false;

  AppState get s => widget.state;

  Future<void> _go(Future<void> Function() open) async {
    if (_busy) return;
    setState(() => _busy = true);
    await open();
  }

  @override
  Widget build(BuildContext context) {
    final choices = startupChoices(s.lastProjectId, s.savedProjects);
    final last = choices.last;
    final others = choices.projects.where((p) => p.id != last?.id).toList();
    Widget choice(IconData icon, Color color, String title, String subtitle, Future<void> Function() open,
            {bool autofocus = false}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: Neon.panel,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10), side: const BorderSide(color: Neon.line)),
            child: ListTile(
              autofocus: autofocus,
              enabled: !_busy,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              leading: Icon(icon, color: color),
              title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(subtitle, style: const TextStyle(color: Neon.dim)),
              onTap: () => _go(open),
            ),
          ),
        );
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: FocusTraversalGroup(
              child: ListView(padding: const EdgeInsets.all(16), children: [
                const SizedBox(height: 12),
                const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  CrowLogo(size: 48),
                  SizedBox(width: 10),
                  Text('C.A.W', style: TextStyle(fontSize: 22, letterSpacing: 3, fontWeight: FontWeight.w800)),
                ]),
                const SizedBox(height: 20),
                if (s.engineError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(s.engineError!, style: const TextStyle(color: Neon.pink)),
                  ),
                if (last != null)
                  choice(Icons.play_arrow, Neon.green, 'Continue "${last.name}"', 'The project you had open last',
                      s.startLast,
                      autofocus: true),
                choice(Icons.add, Neon.yellow, 'New blank project', 'No modules and no layers yet',
                    () => s.start(s.blankProject()),
                    autofocus: last == null),
                choice(
                    Icons.auto_awesome_mosaic,
                    Neon.blue,
                    'From a template: First loop',
                    'Kick, bass, hats and a byte lead over a 4-bar loop, plus a muted acid line',
                    () => s.start(s.starterProject())),
                if (others.isNotEmpty) ...[
                  const Heading('Open a project'),
                  for (final p in others)
                    choice(Icons.folder_open, Neon.dim, p.name,
                        'Changed ${p.modified.toLocal().toString().substring(0, 16)}', () => s.startProject(p.id)),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
