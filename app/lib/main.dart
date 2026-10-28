// Entry point: loads the settings, starts the app state (engine, audio, startup choice) and shows the shell.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'model/app_state.dart';
import 'model/settings.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(['JetBrains Mono'], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  final settings = await Settings.open();
  final state = AppState(settings: settings);
  runApp(CawApp(state: state));
  state.init();
}

class CawApp extends StatelessWidget {
  const CawApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: state.settings,
        builder: (context, _) => MaterialApp(
          title: 'C.A.W',
          debugShowCheckedModeBanner: false,
          themeAnimationDuration: Duration.zero, // theme edits repaint once, with no animation frames
          theme: Neon.theme(look: state.settings.activeTheme, compact: state.settings.compact),
          // A new key after a theme change rebuilds every screen, so colours fixed at build time repaint too.
          home: Shell(key: ValueKey(state.settings.lookRevision), state: state),
        ),
      );
}
