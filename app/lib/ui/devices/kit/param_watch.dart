// Rebuilds a device editor's part only when a value it shows moves: it notes which parameters its build reads.
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../../model/device_target.dart';
import '../device_scope.dart';

/// Builds [builder] again when the device's values change ([DeviceTarget.tick]) or [also] fires, except for a knob
/// step ([DeviceTarget.moving]) of a parameter nothing it built has read (beta plan B4.5: a knob step rebuilt the
/// whole editor, 450–1,100 widgets).
///
/// What it read: every [DeviceTarget.value] of its device while it rebuilds, lays out or paints, its descendants
/// built, laid out and painted in the same pass included (a LayoutBuilder's builder too), down to the next watch
/// (a control, a hero, a card). A widget rebuilt on its own (a dependency, its own setState, a motion frame) counts
/// for the watch it sits in, found when it looks up its [DeviceScope] (which also makes it a dependent of that
/// watch, so it rebuilds with it even when it is a const widget); a read that has neither goes to every watch of
/// the device that rebuilt in this frame but the page, else to the editor's page ([page]). Reads in gesture
/// handlers between frames don't count. The set only grows, so a value once shown keeps rebuilding it. Any other
/// change (a reset, undo, a bypass, a rack, a modulator) rebuilds it as before.
class ParamWatch extends StatefulWidget {
  const ParamWatch({super.key, required this.target, required this.builder, this.also, this.page = false});
  final DeviceTarget target;
  final WidgetBuilder builder;
  final Listenable? also;

  /// The editor's page: it also takes the reads no other watch's build made.
  final bool page;

  @override
  State<ParamWatch> createState() => _ParamWatchState();

  @override
  StatefulElement createElement() => _ParamWatchElement(this);
}

// Holds its state on the watch stack for the whole rebuild, so the children it builds then count as its own reads.
class _ParamWatchElement extends StatefulElement {
  _ParamWatchElement(super.widget);

  @override
  void performRebuild() {
    final s = state as _ParamWatchState;
    _ParamWatchState._rebuiltNow(s);
    _ParamWatchState._building.add(s);
    try {
      super.performRebuild();
    } finally {
      _ParamWatchState._building.removeLast();
    }
  }
}

// Holds the watch on the stack while its subtree lays out and paints, so a LayoutBuilder's builder or a painter
// under it counts for it too.
class _WatchPass extends SingleChildRenderObjectWidget {
  const _WatchPass({required this.watch, super.child});
  final _ParamWatchState watch;

  @override
  _RenderWatchPass createRenderObject(BuildContext context) => _RenderWatchPass(watch);

  @override
  void updateRenderObject(BuildContext context, _RenderWatchPass r) => r.watch = watch;
}

class _RenderWatchPass extends RenderProxyBox {
  _RenderWatchPass(this.watch);
  _ParamWatchState watch;

  @override
  void performLayout() {
    _ParamWatchState._building.add(watch);
    try {
      super.performLayout();
    } finally {
      _ParamWatchState._building.removeLast();
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _ParamWatchState._building.add(watch);
    try {
      super.paint(context, offset);
    } finally {
      _ParamWatchState._building.removeLast();
    }
  }
}

// What a watch gives the widgets under it: a dependency that rebuilds them with it (a const widget too), and which
// watch they sit in.
class _WatchTick extends InheritedWidget {
  const _WatchTick({required this.watch, required this.version, required super.child});
  final _ParamWatchState watch;
  final int version;

  @override
  bool updateShouldNotify(_WatchTick old) => old.version != version || !identical(old.watch, watch);
}

/// [builder] under its own [ParamWatch] of the device [DeviceScope] gives: a card or a control whose values
/// rebuild it alone.
Widget watchDevice(BuildContext context, WidgetBuilder builder) =>
    ParamWatch(target: DeviceScope.of(context).target, builder: builder);

class _ParamWatchState extends State<ParamWatch> {
  static final List<_ParamWatchState> _building = [];
  static final Set<_ParamWatchState> _pages = {};
  static final Set<_ParamWatchState> _rebuilt = {}; // this frame's
  final Set<String> _read = {};

  // The watch of the widget that looked up its scope last in this frame (a widget rebuilt on its own).
  static _ParamWatchState? _scopeReader;

  static void _onLookup(BuildContext context) {
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.persistentCallbacks) return;
    final w = context.dependOnInheritedWidgetOfExactType<_WatchTick>()?.watch;
    if (w == null) return;
    if (_scopeReader == null) SchedulerBinding.instance.addPostFrameCallback((_) => _scopeReader = null);
    _scopeReader = w;
  }

  static void _rebuiltNow(_ParamWatchState s) {
    if (_rebuilt.isEmpty) SchedulerBinding.instance.addPostFrameCallback((_) => _rebuilt.clear());
    _rebuilt.add(s);
  }

  static void _onRead(DeviceTarget t, String id) {
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.persistentCallbacks) return;
    // The innermost watch of this device rebuilding now; else every page of it.
    for (var i = _building.length - 1; i >= 0; i--) {
      if (_building[i].widget.target.sameDevice(t)) {
        _building[i]._read.add(id);
        return;
      }
    }
    final reader = _scopeReader;
    if (reader != null && reader.mounted && reader.widget.target.sameDevice(t)) {
      reader._read.add(id);
      return;
    }
    var any = false;
    for (final w in _rebuilt) {
      if (w.mounted && !w.widget.page && w.widget.target.sameDevice(t)) {
        w._read.add(id);
        any = true;
      }
    }
    if (any) return;
    for (final p in _pages) {
      if (p.widget.target.sameDevice(t)) p._read.add(id);
    }
  }

  @override
  void initState() {
    super.initState();
    DeviceTarget.onRead ??= _onRead;
    DeviceScope.onLookup ??= _onLookup;
    _listen(widget);
    if (widget.page) _pages.add(this);
  }

  @override
  void didUpdateWidget(ParamWatch old) {
    super.didUpdateWidget(old);
    if (!identical(old.target.tick, widget.target.tick) || !identical(old.also, widget.also)) {
      old.target.tick.removeListener(_changed);
      old.also?.removeListener(_changed);
      _listen(widget);
    }
    if (!old.target.sameDevice(widget.target)) _read.clear();
    if (widget.page) {
      _pages.add(this);
    } else {
      _pages.remove(this);
    }
  }

  void _listen(ParamWatch w) {
    w.target.tick.addListener(_changed);
    w.also?.addListener(_changed);
  }

  @override
  void dispose() {
    widget.target.tick.removeListener(_changed);
    widget.also?.removeListener(_changed);
    _pages.remove(this);
    _rebuilt.remove(this);
    super.dispose();
  }

  void _changed() {
    final m = DeviceTarget.moving;
    if (m != null && m.target.sameDevice(widget.target) && !_read.contains(m.id)) return;
    if (mounted) setState(() {});
  }

  int _version = 0;

  @override
  Widget build(BuildContext context) => _WatchTick(watch: this, version: ++_version,
      child: _WatchPass(watch: this, child: Builder(builder: widget.builder)));
}
