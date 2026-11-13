// Engine diagnostics' Display modes block: what the phone reports about its screen, raw and copyable.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../frame_rate.dart';
import '../theme.dart';
import '../widgets.dart';

/// The raw `caw/display` read ([DisplayInfo.report]) with a Copy button, so a frame-rate problem can be reported
/// with exactly what the phone says (owner, 2026-11-13). It reads the screen again when it shows.
class DisplayModesPanel extends StatefulWidget {
  const DisplayModesPanel({super.key, this.controller});

  /// The app's frame-rate controller ([FrameRateController.current] when null).
  final FrameRateController? controller;

  @override
  State<DisplayModesPanel> createState() => _DisplayModesPanelState();
}

class _DisplayModesPanelState extends State<DisplayModesPanel> {
  FrameRateController? get _c => widget.controller ?? FrameRateController.current;

  @override
  void initState() {
    super.initState();
    final c = _c;
    if (c != null) unawaited(c.refresh());
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    Widget body() {
      final text = c == null ? 'Not available: no frame-rate controller' : c.info.report(requested: c.requested);
      return NeonPanel(
        color: Neon.violet,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Expanded(
                child: Text('DISPLAY MODES', style: TextStyle(color: Neon.violet, fontWeight: FontWeight.w800))),
            TextButton.icon(
              key: const ValueKey('display-modes-copy'),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Display modes copied')));
              },
            ),
          ]),
          SelectableText(text, key: const ValueKey('display-modes-text'), style: Neon.code(size: 12)),
        ]),
      );
    }

    return c == null ? body() : ListenableBuilder(listenable: c, builder: (_, _) => body());
  }
}
