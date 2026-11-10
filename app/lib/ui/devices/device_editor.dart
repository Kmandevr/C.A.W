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
import 'kit/device_style.dart';
import 'kit/feel.dart';
import 'kit/presets.dart';
import 'visuals/mod_routing.dart';
import 'visuals/mod_sheet.dart';

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

/// A device's editor: the faceplate header (the family's badge, name, track, preset browser, A/B compare, bypass,
/// close), its tabs, the mod source strip when
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
  final _assigning = ValueNotifier<ModSource?>(null);
  final _selected = ValueNotifier<int?>(null);

  DeviceTarget get t => widget.target;
  AppState get s => t.state;

  @override
  void dispose() {
    _dragging.dispose();
    _focus.dispose();
    _assigning.dispose();
    _selected.dispose();
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
    if (entry.presets.isNotEmpty) DevicePresets.register(use.id, entry.presets);
    final style = entry.family == null ? null : deviceStyle(entry.family!);
    final color = entry.accent ?? style?.primary ?? trackColor(s, layer);
    if (info == null) {
      return _frame(context, title: t.label, color: color, style: style, body: Center(child: Text(
        s.engine == null ? 'Controls appear when the engine runs' : 'Loading controls…',
        style: const TextStyle(color: Neon.dim))));
    }
    final sections = entry.sections(t);
    final tab = _tab.clamp(0, sections.length - 1);
    final matrix = ModMatrix(t);
    final hasMatrix = matrix.slotCount > 0;
    final modTab = sections.indexWhere((x) => x.showsSources || x.id == 'mod');
    return DeviceScope(
      target: t,
      matrix: hasMatrix ? matrix : null,
      dragging: _dragging,
      accent: color,
      secondary: style?.secondary ?? color,
      focusSource: _focus,
      assigning: hasMatrix ? _assigning : null,
      selectedSlot: _selected,
      openSource: modTab < 0 ? null : (src) {
        _focus.value = src;
        setState(() => _tab = modTab);
      },
      child: Builder(builder: (context) => _frame(context, title: t.label, color: color, style: style, bypass: true,
        tabs: sections.length > 1 ? sections : null, tab: tab,
        strip: hasMatrix ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const ModSourceStrip(),
          const ModAssignBanner(),
        ]) : null,
        body: AnimatedSwitcher(
          duration: Motion.fade(Motion.standard, Motion.of(context)),
          child: KeyedSubtree(key: ValueKey('device-page-${sections[tab].id}'), child: sections[tab].builder(context)),
        ),
      )),
    );
  }

  Widget _frame(BuildContext context, {required String title, required Color color, required Widget body,
      DeviceStyle? style, bool bypass = false, List<DeviceSection>? tabs, int tab = 0, Widget? strip}) {
    final layer = t.layer;
    final second = style?.secondary ?? color;
    final header = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: widget.onHeaderDrag == null ? null : (d) => widget.onHeaderDrag!(d.delta),
      child: SizedBox(height: 48, child: Row(children: [
        IconButton(key: const ValueKey('device-close'), tooltip: 'Close', iconSize: 20,
          onPressed: widget.onClose,
          icon: Icon(widget.onHeaderDrag == null ? Icons.arrow_back : Icons.close)),
        Container(
          key: const ValueKey('device-badge'),
          width: 30, height: 30,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(9),
            gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [color.withValues(alpha: 0.9), second.withValues(alpha: 0.75)]),
            boxShadow: Neon.glow(color, strength: 0.35)),
          child: Icon(style?.icon ?? Icons.extension_outlined, size: 17, color: Neon.bg)),
        const SizedBox(width: 8),
        Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
            if (layer != null) Text(layer.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9, color: color)),
          ])),
        if (bypass) ...[
          DevicePresetChip(target: t, color: color),
          const SizedBox(width: 4),
          _ABSwitch(target: t, color: color),
          IconButton(
            key: const ValueKey('device-bypass'),
            tooltip: t.bypass ? 'Turn on' : 'Bypass',
            iconSize: 18,
            color: t.bypass ? Neon.dim : Neon.green,
            onPressed: () {
              DeviceFeel.tap();
              t.setBypass(!t.bypass);
            },
            icon: Icon(Icons.power_settings_new, shadows: t.bypass ? null : [Shadow(color: Neon.green, blurRadius: 6)])),
        ],
        const SizedBox(width: 4),
      ])),
    );
    return DeviceFingers.counter(child: Column(key: const ValueKey('device-editor'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header,
      Container(height: 2, decoration: BoxDecoration(gradient: LinearGradient(colors: [
        color.withValues(alpha: 0.0), color.withValues(alpha: 0.8), second.withValues(alpha: 0.8), second.withValues(alpha: 0.0)]))),
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
    ]));
  }
}

/// The header's preset button: the current preset's name; a tap opens the browser.
class DevicePresetChip extends StatelessWidget {
  const DevicePresetChip({super.key, required this.target, required this.color, this.maxWidth = 150, this.chipKey});
  final DeviceTarget target;
  final Color color;
  final double maxWidth;
  final Key? chipKey;

  @override
  Widget build(BuildContext context) {
    final name = DevicePresets.label(target);
    return Flexible(child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: InkWell(
      key: chipKey ?? const ValueKey('device-presets'),
      borderRadius: BorderRadius.circular(15),
      onTap: () {
        DeviceFeel.tap();
        showPresetBrowser(context, target, color);
      },
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(15), color: color.withValues(alpha: 0.1),
          border: Border.all(color: color.withValues(alpha: 0.45))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.bookmarks_outlined, size: 14, color: color),
          const SizedBox(width: 5),
          Flexible(child: Text(name, key: const ValueKey('device-preset-name'), maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700))),
          const Icon(Icons.arrow_drop_down, size: 16, color: Neon.dim),
        ]),
      ),
    )));
  }
}

/// The A/B compare switch.
class _ABSwitch extends StatelessWidget {
  const _ABSwitch({required this.target, required this.color});
  final DeviceTarget target;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final b = DeviceAB.isB(target);
    Widget side(String label, bool isB) => GestureDetector(
      key: ValueKey('device-ab-${label.toLowerCase()}'),
      behavior: HitTestBehavior.opaque,
      onTap: () {
        DeviceFeel.tap();
        DeviceAB.select(target, isB);
        (context as Element).markNeedsBuild();
      },
      child: Container(
        width: 24, height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(6),
          color: b == isB ? color.withValues(alpha: 0.25) : Colors.transparent),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: b == isB ? Neon.text : Neon.dim)),
      ),
    );
    return Tooltip(message: 'Compare two settings', waitDuration: const Duration(milliseconds: 600), child: Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: Neon.line)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [side('A', false), side('B', true)]),
    ));
  }
}

/// The preset browser: categories as chips, presets as a list; a tap loads one (one undo step).
Future<void> showPresetBrowser(BuildContext context, DeviceTarget target, Color color) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    backgroundColor: Neon.panel,
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (context) => _PresetBrowser(target: target, color: color),
  );
}

class _PresetBrowser extends StatefulWidget {
  const _PresetBrowser({required this.target, required this.color});
  final DeviceTarget target;
  final Color color;

  @override
  State<_PresetBrowser> createState() => _PresetBrowserState();
}

class _PresetBrowserState extends State<_PresetBrowser> {
  String? _category;

  @override
  Widget build(BuildContext context) {
    final t = widget.target;
    final all = DevicePresets.of(t);
    final cats = <String>{for (final p in all) if (p.category.isNotEmpty) p.category}.toList();
    final shown = [for (final p in all) if (_category == null || p.category == _category) p];
    final current = DevicePresets.label(t);
    final colors = spectrumColors();
    return SizedBox(height: MediaQuery.sizeOf(context).height * 0.6, child: Column(
      key: const ValueKey('preset-browser'),
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('${t.label} presets',
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800))),
      if (cats.length > 1) SizedBox(height: 40, child: ListView(scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          for (final c in [null, ...cats]) Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(
            label: Text(c ?? 'All', style: const TextStyle(fontSize: 11)),
            selected: _category == c,
            selectedColor: widget.color.withValues(alpha: 0.25),
            onSelected: (_) => setState(() => _category = c))),
        ])),
      Expanded(child: ListView(padding: const EdgeInsets.only(bottom: 16), children: [
        for (final p in shown)
          ListTile(
            key: ValueKey('preset-${p.name}'),
            dense: true,
            leading: Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle,
              color: colors[(cats.indexOf(p.category) + 1) % colors.length])),
            title: Text(p.name, style: TextStyle(fontSize: 13,
              fontWeight: current.startsWith(p.name) ? FontWeight.w800 : FontWeight.w500)),
            subtitle: p.category.isEmpty ? null : Text(p.category, style: const TextStyle(fontSize: 10, color: Neon.dim)),
            trailing: current == p.name ? Icon(Icons.check, size: 18, color: widget.color) : null,
            onTap: () {
              DeviceFeel.tap();
              DevicePresets.apply(t, p);
              Navigator.of(context).maybePop();
            },
          ),
      ])),
    ]));
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
