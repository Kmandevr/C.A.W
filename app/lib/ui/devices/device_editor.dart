// Opens a device's editor: full screen with tabs on a phone, a floating glass window on wide screens; the shared frame of every editor.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/arrange_fx.dart';
import '../../model/device_target.dart';
import '../../model/mod_matrix.dart';
import '../../model/project.dart';
import '../arrange/track_color.dart';
import '../glass.dart';
import '../motion.dart';
import '../theme.dart';
import '../tokens.dart';
import 'device_registry.dart';
import 'device_scope.dart';
import 'visuals/mod_routing.dart';

/// True when [size] gets the floating window instead of the full-screen page.
bool deviceEditorWindowed(Size size) => size.width >= 720 && size.height >= 520;

/// The hook the FX stack calls: opens the editor of [layer]'s device [index] (`DeviceTarget.instrumentSlot`, -1,
/// for its instrument). A phone gets a full-screen page (Back returns); a wide screen a floating window.
Future<void> openDeviceEditor(BuildContext context, AppState state, LayerDoc layer, int index) {
  final target = DeviceTarget(state, layer.id, index);
  if (target.use == null) return Future.value();
  final level = Motion.of(context);
  if (deviceEditorWindowed(MediaQuery.sizeOf(context))) {
    return showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close the device',
      barrierColor: Colors.black.withValues(alpha: 0.25),
      transitionDuration: Motion.fade(Motion.standard, level),
      transitionBuilder: (context, a, _, child) => FadeTransition(opacity: a, child: ScaleTransition(
        scale: Tween(begin: level == MotionLevel.full ? 0.97 : 1.0, end: 1.0).animate(
          CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
        child: child)),
      pageBuilder: (context, _, _) => _DeviceWindow(target: target),
    );
  }
  return Navigator.of(context).push(PageRouteBuilder<void>(
    transitionDuration: Motion.fade(Motion.panel, level),
    reverseTransitionDuration: Motion.fade(Motion.standard, level),
    pageBuilder: (context, _, _) => GlassPage(child: Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(child: DeviceEditor(target: target, onClose: () => Navigator.of(context).maybePop())),
    )),
    transitionsBuilder: (context, a, _, child) => FadeTransition(opacity: a, child: SlideTransition(
      position: Tween(begin: Offset(0, level == MotionLevel.full ? 0.04 : 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
      child: child)),
  ));
}

/// The floating window on wide screens: drag its header to move it.
class _DeviceWindow extends StatefulWidget {
  const _DeviceWindow({required this.target});
  final DeviceTarget target;

  @override
  State<_DeviceWindow> createState() => _DeviceWindowState();
}

class _DeviceWindowState extends State<_DeviceWindow> {
  Offset _offset = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final size = Size(math.min(1120, screen.width * 0.86), math.min(780, screen.height * 0.86));
    return Stack(children: [
      Positioned(
        left: (screen.width - size.width) / 2 + _offset.dx,
        top: (screen.height - size.height) / 2 + _offset.dy,
        width: size.width,
        height: size.height,
        child: Material(type: MaterialType.transparency, child: DecoratedBox(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(Radii.l),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.5), blurRadius: 30)]),
          child: GlassOverlay(radius: Radii.l, child: DeviceEditor(
            target: widget.target,
            onClose: () => Navigator.of(context).maybePop(),
            onHeaderDrag: (d) => setState(() {
              final max = Offset((screen.width - size.width) / 2 + size.width - 80, (screen.height - size.height) / 2);
              _offset = Offset((_offset.dx + d.dx).clamp(-max.dx, max.dx), (_offset.dy + d.dy).clamp(-max.dy, max.dy + size.height - 60));
            }),
          )),
        )),
      ),
    ]);
  }
}

/// A device's editor: a slim header (name, track, presets, bypass, close), its tabs, the mod source strip when
/// the device has a mod matrix, and the selected tab. It reads the device afresh on every change (live edits,
/// undo), and says so when the device is gone.
class DeviceEditor extends StatefulWidget {
  const DeviceEditor({super.key, required this.target, required this.onClose, this.onHeaderDrag});
  final DeviceTarget target;
  final VoidCallback onClose;
  final ValueChanged<Offset>? onHeaderDrag;

  @override
  State<DeviceEditor> createState() => _DeviceEditorState();
}

class _DeviceEditorState extends State<DeviceEditor> {
  int _tab = 0;
  final _dragging = ValueNotifier<ModSource?>(null);
  final _focus = ValueNotifier<ModSource>(ModSource.env1);

  DeviceTarget get t => widget.target;
  AppState get s => t.state;

  @override
  void dispose() {
    _dragging.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    s.componentCatalog.refreshIfStale();
    return ListenableBuilder(
      listenable: Listenable.merge([s, s.componentCatalog, t.tick]),
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final use = t.use, layer = t.layer;
    if (use == null || layer == null) {
      return _frame(context, title: 'Device', color: Neon.dim, body: const Center(child: Text(
        'This device is no longer on the track.', style: TextStyle(color: Neon.dim))));
    }
    final info = t.info;
    final entry = DeviceEditors.of(use.id, info);
    final color = entry.accent ?? trackColor(s, layer);
    if (info == null) {
      return _frame(context, title: t.label, color: color, body: Center(child: Text(
        s.engine == null ? 'Controls appear when the engine runs' : 'Loading controls…',
        style: const TextStyle(color: Neon.dim))));
    }
    final sections = entry.sections(t);
    final tab = _tab.clamp(0, sections.length - 1);
    final matrix = ModMatrix(t);
    final hasMatrix = matrix.slotCount > 0;
    final modTab = sections.indexWhere((x) => x.id == 'mod');
    return DeviceScope(
      target: t,
      matrix: hasMatrix ? matrix : null,
      dragging: _dragging,
      accent: color,
      focusSource: _focus,
      openSource: modTab < 0 ? null : (src) {
        _focus.value = src;
        setState(() => _tab = modTab);
      },
      child: Builder(builder: (context) => _frame(context, title: t.label, color: color, bypass: true,
        tabs: sections.length > 1 ? sections : null, tab: tab,
        strip: hasMatrix ? ValueListenableBuilder<ModSource>(
          valueListenable: _focus,
          builder: (context, focus, _) => ModSourceStrip(
            selected: sections[tab].id == 'mod' ? focus : null,
            onSelect: (src) => DeviceScope.of(context).openSource?.call(src)),
        ) : null,
        body: AnimatedSwitcher(
          duration: Motion.fade(Motion.standard, Motion.of(context)),
          child: KeyedSubtree(key: ValueKey('device-page-${sections[tab].id}'), child: sections[tab].builder(context)),
        ),
      )),
    );
  }

  Widget _frame(BuildContext context, {required String title, required Color color, required Widget body,
      bool bypass = false, List<DeviceSection>? tabs, int tab = 0, Widget? strip}) {
    final layer = t.layer;
    final header = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: widget.onHeaderDrag == null ? null : (d) => widget.onHeaderDrag!(d.delta),
      child: SizedBox(height: 44, child: Row(children: [
        IconButton(key: const ValueKey('device-close'), tooltip: 'Close', iconSize: 20,
          onPressed: widget.onClose,
          icon: Icon(widget.onHeaderDrag == null ? Icons.arrow_back : Icons.close)),
        Container(width: 4, height: 18, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2),
          boxShadow: Neon.glow(color, strength: 0.4))),
        const SizedBox(width: 8),
        Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
            if (layer != null) Text(layer.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9, color: color)),
          ])),
        if (bypass) ...[
          PopupMenuButton<String>(
            key: const ValueKey('device-presets'),
            tooltip: 'Presets',
            iconSize: 18,
            icon: const Icon(Icons.bookmarks_outlined),
            onSelected: (v) {
              if (v == 'reset') t.resetAll();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(enabled: false, value: 'none', child: Text('Presets come later', style: TextStyle(fontSize: 12))),
              PopupMenuItem(value: 'reset', child: Text('Reset to defaults', style: TextStyle(fontSize: 12))),
            ],
          ),
          IconButton(
            key: const ValueKey('device-bypass'),
            tooltip: t.bypass ? 'Turn on' : 'Bypass',
            iconSize: 18,
            color: t.bypass ? Neon.dim : Neon.green,
            onPressed: () {
              Motion.tick();
              t.setBypass(!t.bypass);
            },
            icon: Icon(Icons.power_settings_new, shadows: t.bypass ? null : [Shadow(color: Neon.green, blurRadius: 6)])),
        ],
        const SizedBox(width: 4),
      ])),
    );
    return Column(key: const ValueKey('device-editor'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header,
      if (tabs != null) SizedBox(height: 34, child: Row(children: [
        for (var i = 0; i < tabs.length; i++)
          Expanded(child: _Tab(section: tabs[i], selected: i == tab, color: color, onTap: () => setState(() => _tab = i))),
      ])),
      Container(height: 1, color: Colors.white.withValues(alpha: 0.06)),
      ?strip,
      Expanded(child: AnimatedOpacity(
        duration: Motion.fade(Motion.small, Motion.of(context)),
        opacity: t.bypass ? 0.55 : 1,
        child: body)),
    ]);
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.section, required this.selected, required this.color, required this.onTap});
  final DeviceSection section;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    button: true,
    child: InkWell(
      key: ValueKey('device-tab-${section.id}'),
      onTap: () {
        Motion.tick();
        onTap();
      },
      child: AnimatedContainer(
        duration: Motion.fade(Motion.small, Motion.of(context)),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: selected ? color : Colors.transparent, width: 2))),
        alignment: Alignment.center,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(section.icon, size: 15, color: selected ? color : Neon.dim),
          const SizedBox(width: 4),
          Flexible(child: Text(section.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(
            fontSize: 11, letterSpacing: 0.8, fontWeight: FontWeight.w800, color: selected ? Neon.text : Neon.dim))),
        ]),
      ),
    ),
  );
}
