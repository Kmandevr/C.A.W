// Arrange's track edits on AppState: a track's FX stack (.caw chain and native effects), drops onto a track, trust.
import 'package:flutter/foundation.dart';

import '../engine/component_info.dart';
import '../engine/engine.dart';
import '../ui/frame/sections.dart';
import 'app_state.dart';
import 'cpp_component.dart';
import 'native_trust.dart';
import 'project.dart';

/// The engine's built-in stereo tools (`org.caw.*`): always loaded, no trust choice (docs/engine.md).
bool isBuiltinComponent(String id) => id.startsWith('org.caw.');

/// A readable name for a built-in before its descriptor arrives: `org.caw.delay.pingpong` → "Delay pingpong".
String builtinComponentName(String id) {
  if (!isBuiltinComponent(id)) return id;
  final text = id.substring('org.caw.'.length).split('.').join(' ');
  return text.isEmpty ? id : text[0].toUpperCase() + text.substring(1);
}

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
/// changed from [before] to its current order: a lane follows its effect to the new index, and goes with it when the
/// effect is removed. Lanes address an effect by index, so every chain edit calls this.
void followComponentLanes(ProjectDoc p, String? layerId, List<ComponentUseDoc> before) {
  final after = layerId == null ? p.masterComponents : p.layers.where((l) => l.id == layerId).firstOrNull?.components;
  p.automation.removeWhere((lane) {
    if (lane.targetType != 'component' || lane.layerId != layerId) return false;
    final i = lane.component ?? -1;
    if (i < 0 || i >= before.length) return true;
    final now = after == null ? -1 : after.indexWhere((c) => identical(c, before[i]));
    if (now < 0) return true;
    lane.component = now;
    return false;
  });
}

extension ArrangeFx on AppState {
  ComponentCatalog get componentCatalog => _catalogs[this] ??= ComponentCatalog(this);

  NativeComponentInfo? componentInfo(String id) => componentCatalog.value[id];

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

  /// Adds native effect [componentId] to [layer]'s inserts (at [at], or the end). Folders have no inserts.
  ComponentUseDoc? addNativeEffect(LayerDoc layer, String componentId, {int? at}) {
    if (layer.isFolder || layer.components.length >= 64 || componentId.isEmpty) return null;
    final use = ComponentUseDoc(componentId);
    final before = List.of(layer.components);
    editProject((p) {
      layer.components.insert((at ?? layer.components.length).clamp(0, layer.components.length), use);
      followComponentLanes(p, layer.id, before);
    });
    return use;
  }

  void removeNativeEffect(LayerDoc layer, int index) {
    if (index < 0 || index >= layer.components.length) return;
    final before = List.of(layer.components);
    editProject((p) {
      layer.components.removeAt(index);
      followComponentLanes(p, layer.id, before);
    });
  }

  /// Moves native effect [from] so it ends up at index [to] of the new order.
  void moveNativeEffect(LayerDoc layer, int from, int to) {
    final n = layer.components.length;
    if (from < 0 || from >= n || to < 0 || to >= n || from == to) return;
    final before = List.of(layer.components);
    editProject((p) {
      layer.components.insert(to, layer.components.removeAt(from));
      followComponentLanes(p, layer.id, before);
    });
  }

  /// Bypasses (or brings back) native effect [index]: live in the engine, and stored in the project.
  void setNativeBypass(LayerDoc layer, int index, bool bypass) {
    if (index < 0 || index >= layer.components.length) return;
    final engineIndex = engineComponentIndex(layer, index);
    if (engineIndex != null) engine?.setComponentBypass(layer.id, engineIndex, bypass);
    editLayer(layer, (l) => l.components[index].bypass = bypass);
  }

  /// A knob move on native effect [index]: live in the engine at once, and kept in the project. Call
  /// [commitNativeParams] when the gesture ends to save it (an update with the same chain keeps the running state).
  void setNativeParamLive(LayerDoc layer, int index, String param, double value) {
    if (index < 0 || index >= layer.components.length) return;
    layer.components[index].params[param] = value;
    final engineIndex = engineComponentIndex(layer, index);
    if (engineIndex != null) engine?.setComponentParam(layer.id, engineIndex, param, value);
    layerValueTick(layer.id).value++;
  }

  void commitNativeParams(LayerDoc layer) => editLayer(layer, (_) {});

  /// The C++ instruments a track can play: the engine's built-ins and the project's loaded (trusted) ones.
  List<NativeComponentInfo> get nativeInstruments =>
      [for (final c in componentCatalog.value.values) if (c.isInstrument && componentPlayable(c.id)) c];

  /// Makes native component [componentId] [layer]'s instrument in place of its .caw generator (null: none). Lanes of
  /// a replaced instrument go with it.
  void setNativeInstrument(LayerDoc layer, String? componentId) {
    if (layer.isFolder || (layer.instrument?.id == componentId && layer.generatorId == null)) return;
    editProject((p) {
      if (layer.instrument?.id != componentId) {
        p.automation.removeWhere((a) => a.targetType == 'instrument' && a.layerId == layer.id);
      }
      layer.setInstrument(componentId);
    });
  }

  /// Makes .caw module [moduleId] [layer]'s instrument, replacing a native one.
  void setCawGenerator(LayerDoc layer, String moduleId) {
    if (layer.isFolder) return;
    editProject((p) {
      if (layer.instrument != null) p.automation.removeWhere((a) => a.targetType == 'instrument' && a.layerId == layer.id);
      layer.instrument = null;
      layer.generatorId = moduleId;
    });
  }

  /// Bypasses (or brings back) [layer]'s native instrument: live in the engine, and stored in the project.
  void setInstrumentBypass(LayerDoc layer, bool bypass) {
    final use = layer.instrument;
    if (use == null) return;
    if (componentPlayable(use.id)) engine?.setComponentBypass(layer.id, ProjectDoc.instrumentIndex, bypass);
    editLayer(layer, (l) => l.instrument?.bypass = bypass);
  }

  /// A knob move on [layer]'s native instrument: live at once, kept in the project ([commitNativeParams] saves it).
  void setInstrumentParamLive(LayerDoc layer, String param, double value) {
    final use = layer.instrument;
    if (use == null) return;
    use.params[param] = value;
    if (componentPlayable(use.id)) engine?.setComponentParam(layer.id, ProjectDoc.instrumentIndex, param, value);
    layerValueTick(layer.id).value++;
  }

  /// Adds .caw effect module [moduleId] to [layer]'s chain (at [at], or the end).
  bool addCawEffect(LayerDoc layer, String moduleId, {int? at}) {
    if (layer.isFolder || project.module(moduleId) == null || layer.effectIds.length >= 32) return false;
    editLayer(layer, (l) => l.effectIds.insert((at ?? l.effectIds.length).clamp(0, l.effectIds.length), moduleId));
    return true;
  }

  void removeCawEffect(LayerDoc layer, int index) {
    if (index < 0 || index >= layer.effectIds.length) return;
    editLayer(layer, (l) => l.effectIds.removeAt(index));
  }

  void moveCawEffect(LayerDoc layer, int from, int to) {
    final n = layer.effectIds.length;
    if (from < 0 || from >= n || to < 0 || to >= n || from == to) return;
    editLayer(layer, (l) => l.effectIds.insert(to, l.effectIds.removeAt(from)));
  }

  /// Puts what was picked or dropped on [layer]: an effect joins its chain, an instrument module becomes its
  /// instrument when it has none, and a pattern becomes a clip at [atStep] (snapped). True when something changed.
  bool dropAsset(LayerDoc layer, AssetDrag asset, {int? atStep}) {
    if (layer.isFolder) return false;
    switch (asset.kind) {
      case AssetKind.nativeEffect:
        if (componentInfo(asset.id)?.isInstrument ?? false) {  // an instrument plays the track instead
          if (layer.instrument?.id == asset.id) return false;
          setNativeInstrument(layer, asset.id);
          return true;
        }
        return addNativeEffect(layer, asset.id) != null;
      case AssetKind.cawModule:
        if (isPattern(asset.id)) return _dropPattern(layer, asset.id, atStep);
        if (isGenerator(asset.id)) {
          if (layer.generatorId == asset.id && layer.instrument == null) return false;
          setCawGenerator(layer, asset.id);
          return true;
        }
        return addCawEffect(layer, asset.id);
      case AssetKind.pattern:
        return _dropPattern(layer, asset.id, atStep);
    }
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
