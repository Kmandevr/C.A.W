// Arrange's track edits on AppState: a track's FX stack (instrument and native effects), drops onto a track
// or below the last one, clips moved between tracks, trust.
import 'track_defaults.dart';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../engine/component_info.dart';
import '../engine/engine.dart';
import '../ui/frame/sections.dart';
import 'app_state.dart';
import 'audio_edit.dart';
import 'live_midi.dart';
import 'midi_clips.dart';
import 'modulation.dart';
import 'mixer_fx.dart';
import 'chain_templates.dart';
import 'cpp_component.dart';
import 'device_names.dart';
import 'freeze.dart';
import 'instance_ids.dart';
import 'automation_writer.dart' show AutomationTarget;
import 'native_trust.dart';
import 'pattern_doc.dart';
import 'project.dart';
import 'user_presets.dart';

/// The engine's built-in stereo tools (`org.caw.*`): always loaded, no trust choice (docs/engine.md).
bool isBuiltinComponent(String id) => id.startsWith('org.caw.');

/// A readable name for a built-in before its descriptor arrives: its [DeviceNames] title ("Talon · Compressor"), else
/// one made from its id (`org.caw.test.osc` → "Test osc").
String builtinComponentName(String id) {
  if (!isBuiltinComponent(id)) return id;
  if (DeviceNames.of(id) case final n?) return n.title;
  final text = id.substring('org.caw.'.length).split('.').join(' ');
  return text.isEmpty ? id : text[0].toUpperCase() + text.substring(1);
}

/// Where a dragged track header lands on another track: above it, inside it (the right-most third of its header,
/// owner 2026-11-11 after REAPER; any track, which then becomes a parent), or below it (below a folder: after
/// everything inside it).
enum TrackDrop { above, into, below }

/// What a native effect in a track's stack is doing now, for its card.
enum NativeEffectState { playing, needsTrust, blocked, buildFailed, loadFailed, waiting }

/// The descriptors of the engine's loaded native components, by id (knobs come from these). Loaded on first use
/// and again after the project's C++ components were prepared; tests can [set] them.
class ComponentCatalog extends ValueNotifier<Map<String, NativeComponentInfo>> {
  ComponentCatalog(this._state) : super(const {});
  final AppState _state;
  Object? _loadedFor;
  bool _loading = false;

  /// Asks the engine again when the native status changed since the last load (or nothing was loaded yet).
  void refreshIfStale() {
    final key = _state.nativeStatus ?? _state.engine;
    if (_loading || _state.engine == null || identical(key, _loadedFor)) return;
    _loadedFor = key;
    _loading = true;
    _state.engine!.nativeComponents().then((list) {
      value = {for (final c in list) c.id: c};
    }, onError: (_) {}).whenComplete(() => _loading = false);
  }

  void set(Iterable<NativeComponentInfo> list) {
    _loadedFor = _state.nativeStatus ?? _state.engine;
    value = {for (final c in list) c.id: c};
  }
}

final _catalogs = Expando<ComponentCatalog>('component catalog');

/// Keeps native-component automation lanes on their effects after the chain of [layerId] (null: the master)
/// changed from [before] to its current order: a lane follows its effect (by the device's id, lib/model/
/// instance_ids.dart; a lane with none yet by its index in [before]) to its new index, and goes with it when the
/// effect is removed. Every chain edit calls this, so the index the lane also keeps stays in step.
void followComponentLanes(ProjectDoc p, String? layerId, List<ComponentUseDoc> before) {
  final after = layerId == null ? p.masterComponents : p.layers.where((l) => l.id == layerId).firstOrNull?.components;
  // Where the lane's device is now, or -1 when it is gone (the lane goes too).
  int follow(String? device, int? index) {
    final use = aimedDevice(before, device, index ?? -1);
    return use == null || after == null ? -1 : deviceIndexIn(after, use.uid);
  }
  p.automation.removeWhere((lane) {
    if (lane.targetType != 'component' || lane.layerId != layerId) return false;
    final now = follow(lane.device, lane.component);
    if (now < 0) return true;
    lane.component = now;
    lane.device = after![now].uid;
    return false;
  });
  // Clip lanes on the track's effects follow them the same way.
  for (final clip in p.layers.where((l) => l.id == layerId).firstOrNull?.clips ?? const <ClipDoc>[]) {
    clip.automation.removeWhere((lane) {
      if (lane.targetType != 'component') return false;
      final now = follow(lane.device, lane.component);
      if (now < 0) return true;
      lane.component = now;
      lane.device = after![now].uid;
      return false;
    });
  }
  p.followComponentLinks(layerId, before);  // modulation links address an effect by index too (#161)
}

extension ArrangeFx on AppState {
  ComponentCatalog get componentCatalog => _catalogs[this] ??= ComponentCatalog(this);

  NativeComponentInfo? componentInfo(String id) => componentCatalog.value[id];

  /// The descriptor [use]'s values choose: a merged device's variant's (FX consolidation), else its component's.
  NativeComponentInfo? useInfo(ComponentUseDoc use) => componentInfo(use.id)?.forValues(use.params);

  /// The project's C++ component that defines [componentId], or null (a built-in, or code that isn't in the project).
  CppComponentDoc? cppComponentFor(String componentId) =>
      project.cppComponents.where((c) => c.componentId == componentId).firstOrNull;

  /// A component's display name: its descriptor's, else the project code's, else one made from a built-in's id.
  String componentLabel(String id) => componentInfo(id)?.label ?? cppComponentFor(id)?.name ?? builtinComponentName(id);

  /// The same rule the project sync uses (`toEngineJson(playableComponents:)`): without an in-app compiler every
  /// component is sent; with one, the built-ins and the components it loaded.
  bool componentPlayable(String id) {
    final manager = nativeComponents;
    return manager == null || isBuiltinComponent(id) || manager.loaded.contains(id);
  }

  NativeEffectState nativeEffectState(String id) {
    if (componentPlayable(id)) return NativeEffectState.playing;
    final status = nativeStatus;
    if (status == null) return NativeEffectState.waiting;
    if (status.needsTrust.any((c) => c.componentId == id)) return NativeEffectState.needsTrust;
    if (status.blocked.contains(id)) return NativeEffectState.blocked;
    if (status.buildFailed.containsKey(id)) return NativeEffectState.buildFailed;
    if (status.loadFailed.containsKey(id)) return NativeEffectState.loadFailed;
    return NativeEffectState.waiting;
  }

  /// Where component [index] of [layer] sits in the engine's chain (unplayable ones are left out), or null.
  int? engineComponentIndex(LayerDoc layer, int index) {
    if (index < 0 || index >= layer.components.length || !componentPlayable(layer.components[index].id)) return null;
    return layer.components.take(index).where((c) => componentPlayable(c.id)).length;
  }

  /// Where device [uid] (`ComponentUseDoc.uid`) of [layer]'s effects sits in the engine's chain now, or null.
  int? engineDeviceIndex(LayerDoc layer, String uid) {
    final i = deviceIndexIn(layer.components, uid);
    return i < 0 ? null : engineComponentIndex(layer, i);
  }

  /// Adds native effect [componentId] to [layer]'s inserts (at [at], or the end). A folder has inserts only while
  /// its bus is on (a reverb bus).
  /// A new device starts with auto gain as Settings › Sound "Auto gain on new devices" says.
  ComponentUseDoc? addNativeEffect(LayerDoc layer, String componentId, {int? at}) => componentId.isEmpty
      ? null
      : insertNativeEffect(layer, ComponentUseDoc(componentId)..autoGain = settings.autoGainNewDevices, at: at);

  /// Puts [use] (a new effect, or a copy of one: the FX chain's Ctrl+D) into [layer]'s inserts at [at], or the end.
  ComponentUseDoc? insertNativeEffect(LayerDoc layer, ComponentUseDoc use, {int? at}) {
    if (guardFrozen(layer)) return null;
    if ((layer.isFolder && !layer.busEnabled) || layer.components.length >= 64 || use.id.isEmpty) return null;
    final before = List.of(layer.components);
    editProject((p) {
      layer.components.insert((at ?? layer.components.length).clamp(0, layer.components.length), use);
      followComponentLanes(p, engineLayerId(layer), before);
    });
    return use;
  }

  void removeNativeEffect(LayerDoc layer, int index) {
    if (guardFrozen(layer)) return;
    if (index < 0 || index >= layer.components.length) return;
    final before = List.of(layer.components);
    editProject((p) {
      layer.components.removeAt(index);
      followComponentLanes(p, engineLayerId(layer), before);
    });
  }

  /// Moves native effect [from] so it ends up at index [to] of the new order.
  void moveNativeEffect(LayerDoc layer, int from, int to) {
    if (guardFrozen(layer)) return;
    final n = layer.components.length;
    if (from < 0 || from >= n || to < 0 || to >= n || from == to) return;
    final before = List.of(layer.components);
    editProject((p) {
      layer.components.insert(to, layer.components.removeAt(from));
      followComponentLanes(p, engineLayerId(layer), before);
    });
  }

  /// Bypasses (or brings back) native effect [index]: live in the engine, and stored in the project.
  void setNativeBypass(LayerDoc layer, int index, bool bypass) {
    if (guardFrozen(layer)) return;
    if (index < 0 || index >= layer.components.length) return;
    final engineIndex = engineComponentIndex(layer, index);
    if (engineIndex != null) engine?.setComponentBypass(engineLayerId(layer), engineIndex, bypass);
    editLayer(layer, (l) => l.components[index].bypass = bypass);
  }

  /// Switches native effect [index]'s auto gain (the device header's ear): live in the engine, and stored in the
  /// project (a later project update sets it again from there) as one undo step.
  void setNativeAutoGain(LayerDoc layer, int index, bool on) {
    if (guardFrozen(layer)) return;
    if (index < 0 || index >= layer.components.length || layer.components[index].autoGain == on) return;
    final engineIndex = engineComponentIndex(layer, index);
    if (engineIndex != null) engine?.setComponentAutoGain(engineLayerId(layer), engineIndex, on);
    endUndoStep();
    editLayer(layer, (l) => l.components[index].autoGain = on);
    endUndoStep();
  }

  /// A knob move on native effect [index]: live in the engine at once, and kept in the project. Call
  /// [commitNativeParams] when the gesture ends to save it (an update with the same chain keeps the running state).
  void setNativeParamLive(LayerDoc layer, int index, String param, double value) {
    if (guardFrozen(layer)) return;
    if (index < 0 || index >= layer.components.length) return;
    onParamMove?.call(AutomationTarget('component', param, layerId: engineLayerId(layer), component: index), value);
    layer.components[index].params[param] = value;
    final engineIndex = engineComponentIndex(layer, index);
    if (engineIndex != null) engine?.setComponentParam(engineLayerId(layer), engineIndex, param, value);
    layerValueTick(layer.id).value++;
  }

  void commitNativeParams(LayerDoc layer) => editLayer(layer, (_) {});

  /// Gives native effect [index] of [layer] a new saved state, [bytes] at [version] (the convolver's WAV impulse):
  /// the engine rebuilds the effect's chain off the UI thread, and once it took the state the project keeps it
  /// (base64), so a reload starts from it. False, and nothing kept, when there is no engine or no such effect, the
  /// effect moved meanwhile, or it refused the state (a bad file). An undo takes the project's copy back but the
  /// playing effect keeps the state until the project reloads.
  Future<bool> loadNativeEffectState(LayerDoc layer, int index, Uint8List bytes, {int version = 1}) async {
    final e = engine;
    final engineIndex = engineComponentIndex(layer, index);
    if (e == null || engineIndex == null) return false;
    final uid = layer.components[index].uid;
    if (!await e.setComponentState(engineLayerId(layer), engineIndex, bytes, version)) return false;
    // The same device still at [index] (by its id: not another one put there meanwhile).
    if (deviceIndexIn(layer.components, uid) != index) return false;
    endUndoStep();
    editLayer(layer, (l) {
      l.components[index].state = base64Encode(bytes);
      l.components[index].stateVersion = version;
    });
    endUndoStep();
    return true;
  }

  /// The saved state native effect [index] of [layer] has now: the engine's (as the playing effect saves it), else
  /// the project's copy; null when it has none.
  Uint8List? savedEffectState(LayerDoc layer, int index) {
    if (index < 0 || index >= layer.components.length) return null;
    final e = engine;
    final engineIndex = engineComponentIndex(layer, index);
    if (e != null && engineIndex != null) {
      if (e.componentStates(engineLayerId(layer))[engineIndex] case final s?) return base64Decode(s.state);
    }
    final kept = layer.components[index].state;
    return kept == null || kept.isEmpty ? null : base64Decode(kept);
  }

  /// Writes a state the device's own page made (Molt's painted curve) to native effect [index]: to the engine at
  /// once (when there is one; it rebuilds the chain off the UI thread), and with [keep] into the project as one
  /// undo step, so a reload starts from it. Unlike [loadNativeEffectState] the project keeps it without an engine:
  /// the page built it, so it is valid.
  void writeNativeEffectState(LayerDoc layer, int index, Uint8List bytes, {int version = 1, bool keep = true}) {
    if (guardFrozen(layer)) return;
    if (index < 0 || index >= layer.components.length) return;
    final engineIndex = engineComponentIndex(layer, index);
    if (engineIndex != null) engine?.setComponentState(engineLayerId(layer), engineIndex, bytes, version);
    if (!keep) return;
    endUndoStep();
    editLayer(layer, (l) {
      l.components[index].state = base64Encode(bytes);
      l.components[index].stateVersion = version;
    });
    endUndoStep();
  }

  /// The C++ instruments a track can play: the engine's built-ins and the project's loaded (trusted) ones.
  List<NativeComponentInfo> get nativeInstruments =>
      [for (final c in componentCatalog.value.values) if (c.isInstrument && componentPlayable(c.id)) c];

  /// Makes native component [componentId] [layer]'s instrument (null: none). Lanes of a replaced instrument go with
  /// it.
  void setNativeInstrument(LayerDoc layer, String? componentId) {
    if (guardFrozen(layer)) return;
    if (layer.isFolder || layer.instrument?.id == componentId) return;
    editProject((p) {
      if (layer.instrument?.id != componentId) {
        p.automation.removeWhere((a) => a.targetType == 'instrument' && a.layerId == layer.id);
      }
      final fresh = layer.instrument?.id != componentId;
      layer.setInstrument(componentId);
      // A new instrument that opens on one of its presets (a new Rook on its studio kit, 1.1.3).
      final start = LayerDoc.newInstrumentPresets[componentId], use = layer.instrument;
      if (fresh && start != null && use != null) {
        final preset = componentCatalog.value[componentId]?.presets.where((p) => p.name == start).firstOrNull;
        if (preset != null) {
          use.params = {...preset.params, ...use.params};
          use.preset = start;  // the header names it; the engine reads the same values either way
        }
      }
    });
  }

  /// Bypasses (or brings back) [layer]'s native instrument: live in the engine, and stored in the project.
  void setInstrumentBypass(LayerDoc layer, bool bypass) {
    if (guardFrozen(layer)) return;
    final use = layer.instrument;
    if (use == null) return;
    if (componentPlayable(use.id)) engine?.setComponentBypass(layer.id, ProjectDoc.instrumentIndex, bypass);
    editLayer(layer, (l) => l.instrument?.bypass = bypass);
  }

  /// A knob move on [layer]'s native instrument: live at once, kept in the project ([commitNativeParams] saves it).
  void setInstrumentParamLive(LayerDoc layer, String param, double value) {
    if (guardFrozen(layer)) return;
    final use = layer.instrument;
    if (use == null) return;
    onParamMove?.call(AutomationTarget('instrument', param, layerId: layer.id), value);
    use.params[param] = value;
    if (componentPlayable(use.id)) engine?.setComponentParam(layer.id, ProjectDoc.instrumentIndex, param, value);
    layerValueTick(layer.id).value++;
  }

  /// Puts what was picked or dropped on [layer]: an effect joins its chain, an instrument becomes its instrument,
  /// and a pattern becomes a clip at [atStep] (snapped). True when something changed.
  bool dropAsset(LayerDoc layer, AssetDrag asset, {int? atStep}) {
    // The master's chain holds C++ effects only (the engine's `master_components`).
    if (asset.kind == AssetKind.chainTemplate) {
      final t = ChainTemplates.byId(asset.id);
      return t != null && (isMasterLayer(layer) || !layer.isFolder || layer.busEnabled) && applyChainTemplate(layer, t);
    }
    if (isMasterLayer(layer)) {
      return asset.kind == AssetKind.nativeEffect && !isInstrumentAsset(asset) && addNativeEffect(layer, asset.id) != null;
    }
    if (layer.isFolder) return false;
    switch (asset.kind) {
      case AssetKind.nativeEffect:
        if (isInstrumentAsset(asset)) {  // an instrument plays the track instead
          if (layer.instrument?.id == asset.id) return false;
          setNativeInstrument(layer, asset.id);
          return true;
        }
        return addNativeEffect(layer, asset.id) != null;
      case AssetKind.pattern:
        return _dropPattern(layer, asset.id, atStep);
      case AssetKind.midiFile:
        final f = project.midiFiles.where((f) => f.id == asset.id).firstOrNull;
        final snap = arrangementSnapSteps;
        return f != null && placeMidiFile(this, f, layer, atStep: atStep == null ? null : (atStep / snap).floor() * snap);
      case AssetKind.devicePreset:
        final p = userPresets.byId(asset.id);
        return p != null && applyDevicePresetToTrack(layer, p);
      case AssetKind.trackPreset:
        final p = userPresets.byId(asset.id);
        return p != null && applyTrackPreset(layer, p);
      case AssetKind.audioFile:
        return dropAudio(layer, asset.id, atStep: atStep);
      case AssetKind.chainTemplate:
        return false;  // handled above
    }
  }

  /// An instrument rather than an effect or a clip: what [AssetDrag.instrument] says, else the engine's descriptor.
  bool isInstrumentAsset(AssetDrag asset) => switch (asset.kind) {
        AssetKind.nativeEffect => asset.instrument || (componentInfo(asset.id)?.isInstrument ?? false),
        AssetKind.devicePreset => asset.instrument ||
            (componentInfo(userPresets.byId(asset.id)?.componentId ?? '')?.isInstrument ?? false),
        AssetKind.trackPreset => userPresets.byId(asset.id)?.instrument != null,
        _ => false,
      };

  /// The name of what plays [layer]'s notes (its C++ instrument), or null when nothing does.
  String? instrumentName(LayerDoc layer) {
    final use = layer.instrument;
    return use == null ? null : componentLabel(use.id);
  }

  /// Whether putting [asset] on [layer] would replace the instrument it has (the UI asks first).
  bool replacesInstrument(LayerDoc layer, AssetDrag asset) {
    if (!isInstrumentAsset(asset) || instrumentName(layer) == null) return false;
    if (asset.kind == AssetKind.trackPreset || asset.kind == AssetKind.devicePreset) return true;
    return layer.instrument?.id != asset.id;
  }

  /// A new track with nothing on it, named [name]: at the end of the list, or with [parentId] as the last track
  /// inside that folder.
  LayerDoc addEmptyTrack({String? name, String? parentId, NewTrackKind kind = NewTrackKind.midi}) {
    final p = project;
    final track = LayerDoc(id: newId('l'), name: name == null || name.isEmpty ? 'Track ${p.layers.length + 1}' : name,
        color: newTrackColor(kind), parentId: parentId, lengthSteps: p.stepsPerBar, volume: 1);
    var at = p.layers.length;
    if (parentId != null) {
      final folder = p.layers.indexWhere((l) => l.id == parentId);
      if (folder >= 0) {
        at = folder + 1;
        while (at < p.layers.length && _isInside(p.layers[at], parentId)) {
          at++;
        }
      }
    }
    editProject((p) => p.layers.insert(at, track));
    return track;
  }

  bool _isInside(LayerDoc layer, String folderId) {
    var parent = layer.parentId;
    for (var depth = 0; parent != null && depth <= project.layers.length; depth++) {
      if (parent == folderId) return true;
      parent = project.layers.where((l) => l.id == parent).firstOrNull?.parentId;
    }
    return false;
  }

  /// Where a clip or asset dropped on [layer] goes. C.A.W.'s folders have no instrument or inserts (REAPER's folder
  /// tracks hold items, docs/ui.md), so a folder passes it to its first track inside, in track order, and a folder
  /// with no track inside gets a new one.
  LayerDoc dropTrackFor(LayerDoc layer, {String? newName}) {
    if (!layer.isFolder) return layer;
    final inside = project.layers.where((l) => !l.isFolder && _isInside(l, layer.id)).firstOrNull;
    return inside ?? addEmptyTrack(name: newName, parentId: layer.id);
  }

  /// Moves [clip] from [from] onto [to] at [startSteps], keeping its pattern; [to] null makes a new track for it at
  /// the end (REAPER: dragged below the last track). With [copy] (REAPER's Ctrl-drag) a copy with its own notes goes
  /// there and the original stays. All of it is one undo step. Returns the clip that was placed.
  ClipDoc? moveClipTo(LayerDoc from, ClipDoc clip, LayerDoc? to, int startSteps, {bool copy = false}) {
    final name = project.module(clip.patternId)?.name;
    final target = to == null ? addEmptyTrack(name: name) : dropTrackFor(to, newName: name);
    final start = startSteps.clamp(0, project.maxArrangementSteps - clip.lengthSteps).toInt();
    if (!copy) {
      if (identical(target, from)) {
        moveClip(from, clip, start);
        return clip;
      }
      editProject((_) {
        from.clips.remove(clip);
        clip.startSteps = start;
        target.clips.add(clip);
      });
      selectClip(target, clip);
      return clip;
    }
    var patternId = clip.patternId;
    final original = project.module(patternId);
    if (original == null) return null;
    final source = ModuleDoc(id: newId('m'), name: '${original.name} copy',
        source: original.source, runSource: original.runSource);
    final copied = ClipDoc(id: newId('c'), patternId: source.id, startSteps: start,
        lengthSteps: clip.lengthSteps.clamp(1, project.maxArrangementSteps - start).toInt(),
        sourceOffsetSteps: clip.sourceOffsetSteps, loop: clip.loop, loopSteps: clip.loopSteps,
        automation: [for (final a in clip.automation) a.copy(fresh: true)]);
    editProject((p) {
      p.modules.add(source);
      target.clips.add(copied);
    });
    selectClip(target, copied);
    return copied;
  }

  /// Puts [asset] on a new track at the end, named after it (REAPER: an FX, instrument or file dropped on the empty
  /// area below the last track). Returns the track, or null (and no track) when the asset couldn't go on one.
  LayerDoc? dropOnNewTrack(AssetDrag asset, {int? atStep}) {
    final track = addEmptyTrack(name: asset.name);
    if (dropAsset(track, asset, atStep: atStep)) return track;
    removeLayer(track);
    return null;
  }

  /// Moves [track] (a folder with everything inside it) next to or into [target], as a header dragged in REAPER's
  /// track panel; [target] null puts it at the end, outside any folder. A track can't go into itself. True when it
  /// moved.
  bool moveTrack(LayerDoc track, LayerDoc? target, TrackDrop where) {
    final p = project;
    if (target != null && (identical(target, track) || _isInside(target, track.id))) return false;
    if (target != null && where == TrackDrop.into) {
      if (track.parentId == target.id) return false;
      // One undo step: the parent made (when it was a plain track) and the track moved into it.
      endUndoStep();
      if (!target.isFolder) makeParent(target);
      final moved = moveLayerIntoFolder(track, target.id);
      endUndoStep();
      return moved;
    }
    final subtree = [for (final l in p.layers) if (identical(l, track) || _isInside(l, track.id)) l];
    editProject((p) {
      p.layers.removeWhere(subtree.contains);
      var at = p.layers.length;
      if (target != null) {
        at = p.layers.indexOf(target);
        if (where == TrackDrop.below) {
          at++;
          while (at < p.layers.length && _isInside(p.layers[at], target.id)) {
            at++;
          }
        }
      }
      track.parentId = target?.parentId;
      p.layers.insertAll(at, subtree);
    });
    return true;
  }

  /// Lets the plain track [track] hold tracks (owner, 2026-11-11: any track can be a parent, its children feeding
  /// it). The engine's buses only sum and run effects, so [track] becomes a folder with a bus that keeps its id,
  /// name, colour, effects, sends, fader, mute, solo and track automation (so what it nests passes through them, as a
  /// REAPER parent's FX and fader do), and what plays on it (its instrument and clips) moves to a new first track
  /// inside it, of the same name, at unity gain; lanes, links and modulators that follow the instrument move with
  /// it. A track with nothing to play just becomes the folder. Returns that new track, or null when none was needed.
  LayerDoc? makeParent(LayerDoc track) {
    if (track.isFolder) return null;
    final plays = track.instrument != null || track.clips.isNotEmpty || track.patternId != null;
    LayerDoc? own;
    editProject((p) {
      if (plays) {
        own = LayerDoc(id: newId('l'), name: track.name, color: track.color, ownColor: track.ownColor,
            parentId: track.id, patternId: track.patternId, lengthSteps: track.lengthSteps, volume: 1,
            clips: track.clips, instrument: track.instrument);
        final id = own!.id;
        for (final lane in p.automation) {
          if (lane.targetType == 'instrument' && lane.layerId == track.id) lane.layerId = id;
        }
        for (final link in p.modLinks) {
          if (link.target.type == 'instrument' && link.target.layerId == track.id) {
            link.target = ModTarget.instrument(id, link.target.param);
          }
        }
        for (final m in p.modulators) {
          if (m.inputId == track.id && m.hears == 'notes') m.inputId = id;
        }
        p.layers.insert(p.layers.indexOf(track) + 1, own!);
        track
          ..clips = []
          ..patternId = null
          ..instrument = null;
      }
      track
        ..isFolder = true
        ..busEnabled = true
        ..collapsed = false;
    });
    final midi = LiveMidi.current;
    if (own != null && midi?.armedLayerId == track.id) midi!.armedLayerId = own!.id;
    return own;
  }

  /// Drags [clip]'s left edge to [startSteps] (REAPER: an item's edge is dragged to trim it): the end stays where it
  /// is and the notes stay at their times, so the source offset moves with the edge (never before the source's start).
  void trimClipStart(LayerDoc layer, ClipDoc clip, int startSteps) {
    final end = clip.startSteps + clip.lengthSteps;
    final earliest = clip.startSteps - clip.sourceOffsetSteps;
    final start = startSteps.clamp(earliest < 0 ? 0 : earliest, end - 1).toInt();
    editLayer(layer, (_) {
      clip.sourceOffsetSteps += start - clip.startSteps;
      clip.startSteps = start;
      clip.lengthSteps = end - start;
    });
  }

  /// A new empty pattern in a clip on [layer] from [startSteps], [lengthSteps] long (REAPER: Ctrl+drag in an empty
  /// area creates an empty item). A folder passes it to its first track inside.
  ClipDoc? addEmptyClip(LayerDoc layer, int startSteps, int lengthSteps) {
    final track = dropTrackFor(layer);
    final start = startSteps.clamp(0, project.maxArrangementSteps - 1).toInt();
    final length = lengthSteps.clamp(1, project.maxArrangementSteps - start).toInt();
    var n = 1;
    while (project.modules.any((m) => m.name == 'Pattern $n')) {
      n++;
    }
    final name = 'Pattern $n';
    final source = PatternDoc.blank(name: name, steps: length).serialize();
    final module = ModuleDoc(id: newId('m'), name: name, source: source);
    final clip = ClipDoc(id: newId('c'), patternId: module.id, startSteps: start, lengthSteps: length);
    editProject((p) {
      p.modules.add(module);
      track.clips.add(clip);
    });
    selectClip(track, clip);
    return clip;
  }

  bool _dropPattern(LayerDoc layer, String patternId, int? atStep) {
    final before = layer.clips.length;
    final snap = arrangementSnapSteps;
    addClip(layer, patternId, startSteps: atStep == null ? null : (atStep / snap).floor() * snap);
    return layer.clips.length > before;
  }

  /// The user's Trust or Block for a project C++ component waiting for one: remembered for this exact code, then
  /// the project's components are prepared again (a trusted one builds and starts playing).
  Future<void> decideNativeTrust(CppComponentDoc component, {required bool trust}) async {
    final manager = nativeComponents;
    if (manager == null) return;
    manager.trust.remember(component.componentId, NativeTrustStore.sourceFingerprint(component),
        trust ? NativeComponentTrust.trusted : NativeComponentTrust.blocked);
    await manager.trust.save();
    await prepareNativeComponents();
  }
}
