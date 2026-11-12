// Rebuilds a device editor's part only when a value it shows moves: it notes which parameters its build reads.
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../../model/device_target.dart';
import '../device_scope.dart';

/// Builds [builder] again when the device's values change ([DeviceTarget.tick]) or [also] fires, except for a knob
/// step ([DeviceTarget.moving]) of a parameter nothing it built has read (beta plan B4.5: a knob step rebuilt the
/// whole editor, 450–1,100 widgets).
///
/// What it read: every [DeviceTarget.value] of its device while it rebuilds, its descendants built in the same pass
/// included, down to the next watch (a control, a card); and, for the editor's page ([page]), every read of the
/// device in a frame's build, layout or paint outside any watch's rebuild (a LayoutBuilder's builder, a motion
/// frame, a widget's own setState). Reads in gesture handlers between frames don't count. The set only grows, so
/// a value once shown keeps rebuilding it. Any other change (a reset, undo, a bypass, a rack, a modulator)
/// rebuilds it as before.
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
    _ParamWatchState._building.add(s);
    try {
      super.performRebuild();
    } finally {
      _ParamWatchState._building.removeLast();
    }
  }
}

/// [builder] under its own [ParamWatch] of the device [DeviceScope] gives: a card or a control whose values
/// rebuild it alone.
Widget watchDevice(BuildContext context, WidgetBuilder builder) =>
    ParamWatch(target: DeviceScope.of(context).target, builder: builder);

class _ParamWatchState extends State<ParamWatch> {
  static final List<_ParamWatchState> _building = [];
  static final Set<_ParamWatchState> _pages = {};
  final Set<String> _read = {};

  static void _onRead(DeviceTarget t, String id) {
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.persistentCallbacks) return;
    // The innermost watch of this device rebuilding now; else every page of it.
    for (var i = _building.length - 1; i >= 0; i--) {
      if (_building[i].widget.target.sameDevice(t)) {
        _building[i]._read.add(id);
        return;
      }
    }
    for (final p in _pages) {
      if (p.widget.target.sameDevice(t)) p._read.add(id);
    }
  }

  @override
  void initState() {
    super.initState();
    DeviceTarget.onRead ??= _onRead;
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
    super.dispose();
  }

  void _changed() {
    final m = DeviceTarget.moving;
    if (m != null && m.target.sameDevice(widget.target) && !_read.contains(m.id)) return;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
