// Entry point: starts the app state (engine, audio, last project) and shows the shell in the neon theme.
import 'package:flutter/material.dart';

import 'model/app_state.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  runApp(CawApp(state: state));
  state.init();
}

class CawApp extends StatelessWidget {
  const CawApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'C.A.W',
        debugShowCheckedModeBanner: false,
        theme: Neon.theme(),
        home: Shell(state: state),
      );
}
