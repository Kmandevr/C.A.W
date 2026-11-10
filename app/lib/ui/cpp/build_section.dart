// The Build section: its open tabs (C++ components and .caw modules). Placeholder until the C++ Builder lands.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../builder_screen.dart';

class BuildSection extends StatelessWidget {
  const BuildSection({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => BuilderScreen(state: state);
}
