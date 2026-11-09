// The filtered browser sheet that "+ effect" and "+ on a wire" open: pick an asset of the given kinds, or nothing.
import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../frame/sections.dart';

/// Slides up a half sheet listing [kinds] of assets (effects: built-in, the project's C++ effects, .caw effect
/// modules), with search and preview; returns the one tapped, or null when dismissed.
Future<AssetDrag?> showAssetPicker(BuildContext context, AppState state, {required Set<AssetKind> kinds,
    String title = 'Add effect'}) async {
  // Placeholder until the Files browser lands (Layout 5, #146): no assets listed.
  return showModalBottomSheet<AssetDrag>(
    context: context,
    builder: (sheet) => SafeArea(child: ListTile(title: Text(title), subtitle: const Text('No assets yet'))),
  );
}
