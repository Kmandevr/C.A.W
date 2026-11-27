// Project edits as ops on stable ids (set, insert, move, delete), applied in one place with their inverses.
//
// Parameter sets, the mix (track, master, VCA, sends), clip moves and resizes, and device and track add, remove and
// move all go through [ProjectOps.apply] on AppState: the op changes the project ([ProjectDocOps.applyOp]), then
// the live engine call or the project sync and autosave follow, as the edit methods did before. Each applied op
// gives back its inverse, so applying that returns the project to what it was.
import 'dart:convert';

import '../app_state.dart';
import '../arrange_fx.dart';
import '../audio_clips.dart';
import '../automation_edit.dart' show shiftSpans;
import '../clip_automation.dart';
import '../instance_ids.dart';
import '../mixer_fx.dart';
import '../modulation.dart';
import '../note_fx.dart';
import '../project.dart';
import '../routing_edit.dart';
import '../vca.dart';

/// The node that holds the tracks (an insert's or a track move's parent: no folder).
const kProjectNode = 'project';

/// The master: its fader (`volume`) and its effect chain's parent.
const kMasterNode = 'master';

/// An index past the end of any list: an insert or move there puts its node last.
const kAtEnd = 0x3fffffff;

/// The lists an op inserts into or moves within.
abstract final class OpList {
  static const layers = 'layers', components = 'components', noteComponents = 'noteComponents', clips = 'clips',
      audioClips = 'audioClips';
}

/// The fields a [ProjectSet] writes. A track takes [volume], [pan], [mute] and [solo]; the master [volume]; a VCA
/// group [volume], [mute] and [solo]; a send [level], [pre] and [mute]; a device [bypass], [autoGain] and
/// `param.<id>` ([param]); a clip [start], [length] and [offset] (its source offset); an automation lane [points].
abstract final class OpField {
  static const volume = 'volume', pan = 'pan', mute = 'mute', solo = 'solo', level = 'level', pre = 'pre',
      bypass = 'bypass', autoGain = 'autoGain', start = 'start', length = 'length', offset = 'offset',
      points = 'points';
  static const _param = 'param.';

  /// The field of a device's parameter [id] (its value a number; null removes it, so the knob shows its default).
  static String param(String id) => '$_param$id';

  /// The parameter id [field] names, or null when it names none.
  static String? paramOf(String field) =>
      field.startsWith(_param) && field.length > _param.length ? field.substring(_param.length) : null;
}

/// One edit of the project, addressed by stable ids (a track's or clip's id, a device's or send's or lane's uid).
sealed class ProjectOp {
  const ProjectOp();

  Map<String, Object?> toJson();

  /// The op [j] describes, or null when it isn't one. What an inverse keeps to put lanes, links and memberships
  /// back ([OpRestore]) is local and never in the JSON.
  static ProjectOp? fromJson(Object? j) {
    if (j is! Map) return null;
    String? text(String key) => switch (j[key]) { final String s when s.isNotEmpty && s.length <= 256 => s, _ => null };
    final node = text('node');
    switch (j['op']) {
      case 'set':
        final field = text('field');
        if (node == null || field == null) return null;
        var value = j['value'];
        if (field == OpField.points) {
          if (value is! List) return null;
          value = <AutomationPointDoc>[for (final p in value) if (p is Map<String, dynamic>) AutomationPointDoc.fromJson(p)];
        }
        return ProjectSet(node, field, value);
      case 'insert':
        final parent = text('parent'), list = text('list'), index = j['index'], raw = j['node'];
        if (parent == null || list == null || index is! int || raw is! Map<String, dynamic>) return null;
        final Object? made = switch (j['kind']) {
          'track' => raw['id'] is String ? LayerDoc.fromJson(raw) : null,
          'device' => switch (ComponentUseDoc.fromJson(raw['device'])) {
              final use? when InstanceIds.valid(raw['uid'], InstanceIds.device) => use..uid = raw['uid'] as String,
              _ => null,
            },
          _ => null,
        };
        return made == null ? null : ProjectInsert(parent, list, index, made);
      case 'move':
        final parent = text('parent'), list = text('list'), index = j['index'];
        if (node == null || parent == null || list == null || index is! int) return null;
        return ProjectMove(node, parent, list, index, withInside: j['inside'] != false);
      case 'delete':
        return node == null ? null : ProjectDelete(node);
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is ProjectOp && other.runtimeType == runtimeType && jsonEncode(other.toJson()) == jsonEncode(toJson());

  @override
  int get hashCode => jsonEncode(toJson()).hashCode;

  @override
  String toString() {
    try {
      return jsonEncode(toJson());
    } on JsonUnsupportedObjectError {
      return toJson().toString();  // a value JSON can't hold (NaN): an op apply refuses
    }
  }
}

/// Writes [field] of [node] ([OpField]).
final class ProjectSet extends ProjectOp {
  const ProjectSet(this.node, this.field, this.value);
  final String node, field;
  final Object? value;

  @override
  Map<String, Object?> toJson() => {
        'op': 'set',
        'node': node,
        'field': field,
        'value': switch (value) {
          final List<AutomationPointDoc> points => [for (final p in points) p.toJson(withIds: true)],
          final v => v,
        },
      };
}

/// Puts [node] (a [LayerDoc] into [kProjectNode]'s [OpList.layers], or a [ComponentUseDoc] into a track's or
/// [kMasterNode]'s [OpList.components], or a track's [OpList.noteComponents]) at [index] of [list].
final class ProjectInsert extends ProjectOp {
  const ProjectInsert(this.parent, this.list, this.index, this.node, {this.restore});
  final String parent, list;
  final int index;
  final Object node;

  /// What the delete this undoes took with it (an inverse's own data).
  final OpRestore? restore;

  @override
  Map<String, Object?> toJson() => {
        'op': 'insert',
        'parent': parent,
        'list': list,
        'index': index,
        ...switch (node) {
          final LayerDoc l => {'kind': 'track', 'node': l.toJson(withIds: true)},
          final ComponentUseDoc d => {'kind': 'device', 'node': {'uid': d.uid, 'device': d.toJson(withIds: true)}},
          _ => const <String, Object?>{},
        },
      };
}

/// Moves [node] to [index] of [parent]'s [list] (the index in that list without it): a track among the tracks, its
/// folder then [parent] (none for [kProjectNode]) and, with [withInside], the tracks inside it going along; a device
/// within or between chains; a clip ([OpList.clips], [OpList.audioClips]) onto another track.
final class ProjectMove extends ProjectOp {
  const ProjectMove(this.node, this.parent, this.list, this.index, {this.withInside = true, this.restore});
  final String node, parent, list;
  final int index;
  final bool withInside;

  /// What the move this undoes took out (a device's lanes and links on its old track; an inverse's own data).
  final OpRestore? restore;

  @override
  Map<String, Object?> toJson() =>
      {'op': 'move', 'node': node, 'parent': parent, 'list': list, 'index': index, if (!withInside) 'inside': false};
}

/// Removes [node]: a track (the tracks inside it move up to its folder) or a device (its lanes and links go too).
final class ProjectDelete extends ProjectOp {
  const ProjectDelete(this.node);
  final String node;

  @override
  Map<String, Object?> toJson() => {'op': 'delete', 'node': node};
}

/// The project's lanes, links, folders and VCA memberships as a delete or move found them, put back by its inverse
/// so the round trip is exact: the lanes and links a removed device took, a moved device's retargeted ones, the
/// tracks a removed folder let go, a removed track's groups. Kept in memory with the inverse, never sent.
class OpRestore {
  OpRestore._(this._lanes, this._laneState, this._clipLanes, this._links, this._linkTargets, this._children,
      this._vca);

  final List<ProjectAutomationLaneDoc>? _lanes;
  final List<(ProjectAutomationLaneDoc, String?, int?, String?)> _laneState;
  final List<(ClipDoc, List<ClipAutomationLaneDoc>, List<(ClipAutomationLaneDoc, int?, String?)>)> _clipLanes;
  final List<ModLinkDoc>? _links;
  final List<(ModLinkDoc, ModTarget)> _linkTargets;
  final List<(LayerDoc, String?)> _children;
  final List<(VcaGroupDoc, List<String>)> _vca;

  /// The lanes and links around devices, and the clip lanes of [tracks].
  static OpRestore devices(ProjectDoc p, Iterable<LayerDoc?> tracks) => OpRestore._(
        List.of(p.automation),
        [for (final l in p.automation) (l, l.layerId, l.component, l.device)],
        [
          for (final t in {...tracks.nonNulls})
            for (final c in t.clips)
              if (c.automation.isNotEmpty) (c, List.of(c.automation), [for (final l in c.automation) (l, l.component, l.device)]),
        ],
        List.of(p.modLinks),
        [for (final k in p.modLinks) (k, k.target)],
        const [], const []);

  /// The tracks inside [track] and the VCA groups it is in.
  static OpRestore track(ProjectDoc p, LayerDoc track) => OpRestore._(null, const [], const [], null, const [],
      [for (final l in p.layers) if (l.parentId == track.id) (l, l.parentId)],
      [for (final g in p.vcaGroups) if (g.members.contains(track.id)) (g, List.of(g.members))]);

  void restore(ProjectDoc p) {
    if (_lanes case final lanes?) {
      p.automation
        ..clear()
        ..addAll(lanes);
    }
    for (final (lane, layer, component, device) in _laneState) {
      lane
        ..layerId = layer
        ..component = component
        ..device = device;
    }
    for (final (clip, lanes, state) in _clipLanes) {
      clip.automation
        ..clear()
        ..addAll(lanes);
      for (final (lane, component, device) in state) {
        lane
          ..component = component
          ..device = device;
      }
    }
    if (_links case final links?) {
      p.modLinks
        ..clear()
        ..addAll(links);
    }
    for (final (link, target) in _linkTargets) {
      link.target = target;
    }
    for (final (child, parent) in _children) {
      child.parentId = parent;
    }
    for (final (group, members) in _vca) {
      group.members
        ..clear()
        ..addAll(members);
    }
  }
}

/// Which list of its track a device sits in.
enum DeviceChain { components, noteComponents, instrument }

/// Where device [use] sits: [layer] (null: the master), [chain], [index] in it (0 for an instrument).
typedef DeviceSpot = ({LayerDoc? layer, DeviceChain chain, int index, ComponentUseDoc use});

/// The op parent a chain of [layer] goes by: its id, or [kMasterNode] for the master's stand-in ([masterLayerOf]).
String chainNode(LayerDoc layer) => isMasterLayer(layer) ? kMasterNode : layer.id;

/// Where clip [id] sits: a pattern clip ([clip]) or an audio clip ([audio]) at [index] of [layer]'s list.
typedef ClipSpot = ({LayerDoc layer, ClipDoc? clip, AudioClipDoc? audio, int index});

extension ProjectDocOps on ProjectDoc {
  LayerDoc? _layer(String id) {
    for (final l in layers) {
      if (l.id == id) return l;
    }
    return null;
  }

  /// Device [uid] in the project, or null.
  DeviceSpot? findDevice(String uid) {
    for (var i = 0; i < masterComponents.length; i++) {
      if (masterComponents[i].uid == uid) return (layer: null, chain: DeviceChain.components, index: i, use: masterComponents[i]);
    }
    for (final l in layers) {
      if (l.instrument case final use? when use.uid == uid) {
        return (layer: l, chain: DeviceChain.instrument, index: 0, use: use);
      }
      for (var i = 0; i < l.components.length; i++) {
        if (l.components[i].uid == uid) return (layer: l, chain: DeviceChain.components, index: i, use: l.components[i]);
      }
      for (var i = 0; i < l.noteComponents.length; i++) {
        if (l.noteComponents[i].uid == uid) {
          return (layer: l, chain: DeviceChain.noteComponents, index: i, use: l.noteComponents[i]);
        }
      }
    }
    return null;
  }

  /// Send [uid]: its track and index, or null.
  ({LayerDoc layer, int index})? findSend(String uid) {
    for (final l in layers) {
      for (var i = 0; i < l.sends.length; i++) {
        if (l.sends[i].uid == uid) return (layer: l, index: i);
      }
    }
    return null;
  }

  /// Clip [id] (a pattern or an audio clip), or null.
  ClipSpot? findClip(String id) {
    for (final l in layers) {
      for (var i = 0; i < l.clips.length; i++) {
        if (l.clips[i].id == id) return (layer: l, clip: l.clips[i], audio: null, index: i);
      }
      for (var i = 0; i < l.audioClips.length; i++) {
        if (l.audioClips[i].id == id) return (layer: l, clip: null, audio: l.audioClips[i], index: i);
      }
    }
    return null;
  }

  /// The points of lane [uid] (a track's, the project's, a clip's or a VCA group's), read and written.
  ({List<AutomationPointDoc> points, void Function(List<AutomationPointDoc>) write})? _lane(String uid) {
    for (final lane in automation) {
      if (lane.uid == uid) return (points: lane.points, write: (p) => lane.points = p);
    }
    for (final l in layers) {
      for (final lane in l.automation) {
        if (lane.uid == uid) return (points: lane.points, write: (p) => lane.points = p);
      }
      for (final c in l.clips) {
        for (final lane in c.automation) {
          if (lane.uid == uid) return (points: lane.points, write: (p) => lane.points = p);
        }
      }
    }
    for (final g in vcaGroups) {
      if (g.automation case final lane? when lane.uid == uid) {
        return (points: lane.points, write: (p) => lane.points = p);
      }
    }
    return null;
  }

  /// The chain [list] of [parent] (a track id or [kMasterNode]), or null when there is none.
  List<ComponentUseDoc>? _chain(String parent, String list) {
    if (parent == kMasterNode) return list == OpList.components ? masterComponents : null;
    final l = _layer(parent);
    if (l == null) return null;
    return switch (list) { OpList.components => l.components, OpList.noteComponents => l.noteComponents, _ => null };
  }

  /// The layer id lanes and links on a chain of [layer] name (null: the master's).
  static String? _laneLayer(LayerDoc? layer) => layer?.id;

  /// Applies [op] to the project and returns its inverse, or null when [op] names nothing here (nothing changed).
  ProjectOp? applyOp(ProjectOp op) => switch (op) {
        ProjectSet() => _set(op),
        ProjectInsert() => _insert(op),
        ProjectMove() => _move(op),
        ProjectDelete() => _delete(op),
      };

  ProjectOp? _set(ProjectSet op) {
    final node = op.node, field = op.field, v = op.value;
    ProjectSet back(Object? old) => ProjectSet(node, field, old);
    final number = v is num && v.isFinite ? v.toDouble() : null;
    final flag = v is bool ? v : null;
    switch (field) {
      case OpField.volume || OpField.pan || OpField.mute || OpField.solo:
        if (node == kMasterNode) {
          if (field != OpField.volume || number == null) return null;
          final old = master;
          master = number;
          return back(old);
        }
        if (_layer(node) case final l?) {
          switch (field) {
            case OpField.volume when number != null:
              final old = l.volume;
              l.volume = number;
              return back(old);
            case OpField.pan when number != null:
              final old = l.pan;
              l.pan = number;
              return back(old);
            case OpField.mute when flag != null:
              final old = l.mute;
              l.mute = flag;
              return back(old);
            case OpField.solo when flag != null:
              final old = l.solo;
              l.solo = flag;
              return back(old);
          }
          return null;
        }
        if (vcaGroup(node) case final g?) {
          switch (field) {
            case OpField.volume when number != null:
              final old = g.volume;
              g.volume = number;
              return back(old);
            case OpField.mute when flag != null:
              final old = g.mute;
              g.mute = flag;
              return back(old);
            case OpField.solo when flag != null:
              final old = g.solo;
              g.solo = flag;
              return back(old);
          }
          return null;
        }
        if (field == OpField.mute && flag != null) {
          if (findSend(node) case final at?) {
            final s = at.layer.sends[at.index];
            final old = s.mute;
            s.mute = flag;
            return back(old);
          }
        }
        return null;
      case OpField.level || OpField.pre:
        final at = findSend(node);
        if (at == null) return null;
        final s = at.layer.sends[at.index];
        if (field == OpField.level) {
          if (number == null) return null;
          final old = s.level;
          s.level = number;
          return back(old);
        }
        if (flag == null) return null;
        final old = s.pre;
        s.pre = flag;
        return back(old);
      case OpField.bypass || OpField.autoGain:
        final use = findDevice(node)?.use;
        if (use == null || flag == null) return null;
        final old = field == OpField.bypass ? use.bypass : use.autoGain;
        if (field == OpField.bypass) {
          use.bypass = flag;
        } else {
          use.autoGain = flag;
        }
        return back(old);
      case OpField.start || OpField.length || OpField.offset:
        final at = findClip(node);
        if (at == null) return null;
        if (at.clip case final c?) {
          if (v is! int) return null;
          switch (field) {
            case OpField.start when v >= 0:
              final old = c.startSteps;
              c.startSteps = v;
              return back(old);
            case OpField.length when v >= 1:
              final old = c.lengthSteps;
              c.lengthSteps = v;
              return back(old);
            case OpField.offset when v >= 0:
              final old = c.sourceOffsetSteps;
              c.sourceOffsetSteps = v;
              return back(old);
          }
          return null;
        }
        // An audio clip's start (its length and trim depend on its file and stretch: edited by audio_edit.dart).
        final a = at.audio!;
        if (field != OpField.start || number == null || number < 0) return null;
        final old = a.startSteps;
        a.startSteps = number;
        return back(old);
      case OpField.points:
        final lane = _lane(node);
        if (lane == null || v is! List<AutomationPointDoc>) return null;
        final old = lane.points;
        lane.write([for (final p in v) p.copy()]);  // the op keeps its own points: the lane's are edited later
        return back(old);
    }
    final param = OpField.paramOf(field);
    if (param == null || (v != null && number == null)) return null;
    final use = findDevice(node)?.use;
    if (use == null) return null;
    final old = use.params[param];
    if (number == null) {
      use.params.remove(param);
    } else {
      use.params[param] = number;
    }
    return back(old);
  }

  ProjectOp? _insert(ProjectInsert op) {
    final node = op.node;
    if (node is LayerDoc) {
      if (op.parent != kProjectNode || op.list != OpList.layers || _layer(node.id) != null) return null;
      layers.insert(op.index.clamp(0, layers.length), node);
      op.restore?.restore(this);
      return ProjectDelete(node.id);
    }
    if (node is! ComponentUseDoc || findDevice(node.uid) != null) return null;
    final chain = _chain(op.parent, op.list);
    if (chain == null) return null;
    final layer = op.parent == kMasterNode ? null : _layer(op.parent);
    final before = List.of(chain);
    chain.insert(op.index.clamp(0, chain.length), node);
    _follow(layer, op.list, before);
    op.restore?.restore(this);
    return ProjectDelete(node.uid);
  }

  /// Keeps the lanes and links on chain [list] of [layer] (null: the master's) on their devices after it changed
  /// from [before] (arrange_fx.dart's followComponentLanes and followNoteLanes).
  void _follow(LayerDoc? layer, String list, List<ComponentUseDoc> before) {
    if (list == OpList.noteComponents) {
      followNoteLanes(this, layer!, before);
    } else {
      followComponentLanes(this, _laneLayer(layer), before);
    }
  }

  static String _listOf(DeviceChain chain) =>
      chain == DeviceChain.noteComponents ? OpList.noteComponents : OpList.components;

  ProjectOp? _delete(ProjectDelete op) {
    if (_layer(op.node) case final l?) {
      final at = layers.indexOf(l);
      final restore = OpRestore.track(this, l);
      for (final child in layers.where((x) => x.parentId == l.id)) {
        child.parentId = l.parentId;
      }
      layers.removeAt(at);
      return ProjectInsert(kProjectNode, OpList.layers, at, l, restore: restore);
    }
    final spot = findDevice(op.node);
    if (spot == null || spot.chain == DeviceChain.instrument) return null;
    final list = _listOf(spot.chain);
    final chain = _chain(spot.layer == null ? kMasterNode : spot.layer!.id, list)!;
    final restore = OpRestore.devices(this, [spot.layer]);
    final before = List.of(chain);
    chain.removeAt(spot.index);
    _follow(spot.layer, list, before);
    return ProjectInsert(spot.layer == null ? kMasterNode : spot.layer!.id, list, spot.index, spot.use,
        restore: restore);
  }

  bool _inside(LayerDoc layer, String folderId) {
    var parent = layer.parentId;
    for (var depth = 0; parent != null && depth <= layers.length; depth++) {
      if (parent == folderId) return true;
      parent = _layer(parent)?.parentId;
    }
    return false;
  }

  ProjectOp? _move(ProjectMove op) {
    final inverse = op.list == OpList.layers ? _moveTrack(op)
        : op.list == OpList.clips || op.list == OpList.audioClips ? _moveClip(op)
        : _moveDevice(op);
    if (inverse != null) op.restore?.restore(this);  // an inverse: what the move it undoes took out comes back
    return inverse;
  }

  ProjectOp? _moveTrack(ProjectMove op) {
    final track = _layer(op.node);
    if (track == null) return null;
    final String? parent = op.parent == kProjectNode ? null : op.parent;
    if (parent != null && parent != track.parentId) {
      final folder = _layer(parent);
      if (folder == null || parent == track.id || _inside(folder, track.id)) return null;  // into its own subtree
    }
    final block = [for (final l in layers) if (identical(l, track) || (op.withInside && _inside(l, track.id))) l];
    final from = layers.indexOf(track);
    final was = layers.take(from).where((l) => !block.contains(l)).length;
    final oldParent = track.parentId;
    layers.removeWhere(block.contains);
    track.parentId = parent;
    layers.insertAll(op.index.clamp(0, layers.length), block);
    return ProjectMove(track.id, oldParent ?? kProjectNode, OpList.layers, was, withInside: op.withInside);
  }

  ProjectOp? _moveClip(ProjectMove op) {
    final at = findClip(op.node);
    final to = _layer(op.parent);
    if (at == null || to == null) return null;
    if ((at.clip != null) != (op.list == OpList.clips)) return null;
    if (at.clip case final c?) {
      at.layer.clips.removeAt(at.index);
      to.clips.insert(op.index.clamp(0, to.clips.length), c);
    } else {
      at.layer.audioClips.removeAt(at.index);
      to.audioClips.insert(op.index.clamp(0, to.audioClips.length), at.audio!);
    }
    return ProjectMove(op.node, at.layer.id, op.list, at.index);
  }

  ProjectOp? _moveDevice(ProjectMove op) {
    final spot = findDevice(op.node);
    if (spot == null || spot.chain == DeviceChain.instrument) return null;
    final fromParent = spot.layer == null ? kMasterNode : spot.layer!.id;
    final fromList = _listOf(spot.chain);
    final from = _chain(fromParent, fromList)!;
    final to = _chain(op.parent, op.list);
    if (to == null) return null;
    final use = spot.use;
    if (identical(from, to)) {
      final before = List.of(from);
      from.removeAt(spot.index);
      from.insert(op.index.clamp(0, from.length), use);
      _follow(spot.layer, fromList, before);
      return ProjectMove(use.uid, fromParent, fromList, spot.index);
    }
    final toLayer = op.parent == kMasterNode ? null : _layer(op.parent);
    final restore = OpRestore.devices(this, [spot.layer, toLayer]);
    final fromBefore = List.of(from), toBefore = List.of(to);
    from.removeAt(spot.index);
    final at = op.index.clamp(0, to.length);
    to.insert(at, use);
    // Appended, nothing on the new chain moved; inserted before others, their lanes and links follow them.
    if (at < toBefore.length) _follow(toLayer, op.list, toBefore);
    // Between track (or master) chains, the device's own lanes go with it (mixer_fx.dart's dropFx).
    if (fromList == OpList.components && op.list == OpList.components) {
      final fromLanes = _laneLayer(spot.layer), toLanes = _laneLayer(toLayer);
      for (final lane in automation) {
        if (lane.targetType == 'component' && lane.layerId == fromLanes &&
            identical(aimedDevice(fromBefore, lane.device, lane.component ?? -1), use)) {
          lane
            ..layerId = toLanes
            ..component = at
            ..device = use.uid;
        }
      }
    }
    _follow(spot.layer, fromList, fromBefore);
    return ProjectMove(use.uid, fromParent, fromList, spot.index, restore: restore);
  }
}

/// The lanes "Automation follows clips" moves with clips on [layer] moved from [spans] (each from, to) by [shift]
/// steps: one points set per lane of the track (its own, its devices' project lanes) with points over them.
List<ProjectSet> clipFollowOps(ProjectDoc p, LayerDoc layer, List<(double, double)> spans, double shift) {
  if (!p.automationFollowsClips || shift == 0 || spans.isEmpty) return const [];
  bool over(AutomationPointDoc q) => spans.any((r) => q.step >= r.$1 && q.step <= r.$2);
  return [
    for (final lane in layer.automation)
      if (lane.points.any(over)) ProjectSet(lane.uid, OpField.points, shiftSpans(lane.points, spans, shift)),
    for (final lane in p.automation)
      if (lane.layerId == layer.id && lane.points.any(over))
        ProjectSet(lane.uid, OpField.points, shiftSpans(lane.points, spans, shift)),
  ];
}

/// How an applied group of ops ends: only the live engine values change (a knob's drag step), the project saves
/// too (a fader: autosave and the undo burst, no redraw), or it is sent to the engine, saved and redrawn.
enum _End { live, save, changed }

extension ProjectOps on AppState {
  /// The one entry for the edits [ProjectOp] covers: applies [op] to the project, makes the live engine call or
  /// the project sync and autosave it needs, and returns its inverse (empty when it named nothing).
  List<ProjectOp> apply(ProjectOp op, {void Function()? andThen}) => applyAll([op], andThen: andThen);

  /// Applies [ops] in order as one edit (one sync, one save) and returns their inverses, last first. [andThen] runs
  /// after the project changed and before it saves and redraws (a selection that follows the edit).
  List<ProjectOp> applyAll(Iterable<ProjectOp> ops, {void Function()? andThen}) {
    final inverses = <ProjectOp>[];
    var end = _End.live;
    final mixed = <LayerDoc>[];
    final vcas = <VcaGroupDoc>[];
    final ticks = <String>{};
    var master = false;
    void reach(_End e) {
      if (e.index > end.index) end = e;
    }

    for (final op in ops) {
      final inverse = project.applyOp(op);
      if (inverse == null) continue;
      inverses.insert(0, inverse);
      if (op is! ProjectSet) {
        reach(_End.changed);
        continue;
      }
      final node = op.node, field = op.field;
      switch (field) {
        case OpField.volume || OpField.pan || OpField.mute || OpField.solo:
          if (node == kMasterNode) {
            engine?.setMaster(project.master);
            master = true;
            reach(_End.save);
          } else if (project.layers.where((l) => l.id == node).firstOrNull case final l?) {
            if (field == OpField.mute || field == OpField.solo) {
              // Mute and solo reach through folders and buses, which the engine works out from the whole project.
              reach(_End.changed);
            } else {
              if (!mixed.contains(l)) mixed.add(l);
              reach(_End.save);
            }
          } else if (project.vcaGroup(node) case final g?) {
            if (!vcas.contains(g)) vcas.add(g);
          } else if (project.findSend(node) case final at?) {
            _pushSend(at.layer, at.index);
            reach(_End.changed);
          }
        case OpField.level || OpField.pre:
          final at = project.findSend(node)!;
          _pushSend(at.layer, at.index);
          if (field == OpField.level) {
            ticks.add(at.layer.id);
          } else {
            reach(_End.changed);
          }
        case OpField.start || OpField.length || OpField.offset || OpField.points:
          reach(_End.changed);
        default:
          final spot = project.findDevice(node)!;
          final param = OpField.paramOf(field);
          _deviceLive(spot, field, param);
          if (param != null) {
            ticks.add(spot.layer?.id ?? masterLayerId);
          } else {
            reach(_End.changed);
          }
      }
    }
    if (inverses.isEmpty) return inverses;
    // A group's fader goes straight to the audio thread; one the engine doesn't hold yet goes as a project update.
    for (final g in vcas) {
      if (engine?.setVca(g.id, g.volume, g.mute, g.solo) ?? false) {
        reach(_End.save);
      } else {
        reach(_End.changed);
      }
    }
    // Volume and pan go straight to the audio thread, unless the edit goes as a project update anyway.
    if (end != _End.changed) {
      for (final l in mixed) {
        engine?.setLayerMix(l.id, l.volume, l.pan, l.mute, l.solo);
      }
    }
    andThen?.call();
    switch (end) {
      case _End.changed:
        finishEdit();
      case _End.save:
        finishEdit(sync: false, notify: false);
        if (master) masterValueTick.value++;
        for (final l in mixed) {
          layerValueTick(l.id).value++;
        }
        for (final id in ticks) {
          layerValueTick(id).value++;
        }
        values.value++;
      case _End.live:
        for (final id in ticks) {
          layerValueTick(id).value++;
        }
    }
    return inverses;
  }

  void _pushSend(LayerDoc layer, int index) {
    final s = layer.sends[index];
    final e = engineSendIndex(layer, index);
    if (e != null) engine?.setSend(layer.id, e, s.level, pre: s.pre, mute: s.mute);
  }

  /// A device's new [param] value, bypass or auto gain, live in the engine where it plays.
  void _deviceLive(DeviceSpot spot, String field, String? param) {
    final use = spot.use;
    final layer = spot.layer ?? masterLayerOf(project);
    final layerId = engineLayerId(layer);
    final int? index = switch (spot.chain) {
      DeviceChain.instrument => componentPlayable(use.id) ? ProjectDoc.instrumentIndex : null,
      DeviceChain.components => engineComponentIndex(layer, spot.index),
      DeviceChain.noteComponents => switch (engineNoteIndex(layer, spot.index)) {
          final at? => at | noteComponentFlag,
          null => null,
        },
    };
    if (index == null) return;
    if (param != null) {
      engine?.setComponentParam(layerId, index, param, use.params[param] ?? 0);
    } else if (field == OpField.bypass) {
      engine?.setComponentBypass(layerId, index, use.bypass);
    } else if (spot.chain == DeviceChain.components) {
      engine?.setComponentAutoGain(layerId, index, use.autoGain);  // the engine has none on instruments or per-note
    }
  }
}
