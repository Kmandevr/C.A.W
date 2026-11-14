// Raw dart:ffi bindings to the engine's audio functions (engine/include/caw.h: assets, analysis, SFZ, input, recording).
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings.dart' show engineLibraryPath;

typedef CStr = Pointer<Utf8>;
typedef CEngine = Pointer<Void>;

/// The API 18 functions, looked up once from the same library [Bindings] opens. Kept apart from [Bindings] so the
/// audio work does not touch the shared table.
class AudioBindings {
  AudioBindings._(DynamicLibrary lib)
      : free = lib.lookupFunction<Void Function(CStr), void Function(CStr)>('caw_free'),
        assetLoad = lib.lookupFunction<CStr Function(CEngine, CStr), CStr Function(CEngine, CStr)>('caw_asset_load'),
        assetPeaks = lib.lookupFunction<Int32 Function(CEngine, CStr, Double, Double, Int32, Int32, Pointer<Float>),
            int Function(CEngine, CStr, double, double, int, int, Pointer<Float>)>('caw_asset_peaks'),
        assetStoreStatus = lib.lookupFunction<CStr Function(), CStr Function()>('caw_asset_store_status'),
        assetStoreSetBudget = lib.lookupFunction<Void Function(Int64), void Function(int)>('caw_asset_store_set_budget'),
        assetStorePurge = lib.lookupFunction<Void Function(), void Function()>('caw_asset_store_purge'),
        assetTempo = lib.lookupFunction<CStr Function(CEngine, CStr, CStr), CStr Function(CEngine, CStr, CStr)>(
            'caw_asset_tempo'),
        assetSlices = lib.lookupFunction<CStr Function(CEngine, CStr, CStr), CStr Function(CEngine, CStr, CStr)>(
            'caw_asset_slices'),
        sfzImport = lib.lookupFunction<CStr Function(CStr), CStr Function(CStr)>('caw_sfz_import'),
        sfzExport = lib.lookupFunction<CStr Function(CStr, CStr, Int32), CStr Function(CStr, CStr, int)>('caw_sfz_export'),
        inputDevices = lib.lookupFunction<CStr Function(), CStr Function()>('caw_audio_input_devices'),
        configureInput = lib.lookupFunction<Int32 Function(CEngine, Int32, CStr, CStr, Int32),
            int Function(CEngine, int, CStr, CStr, int)>('caw_audio_configure_input'),
        inputPeaks = lib.lookupFunction<Int32 Function(CEngine, Pointer<Float>, Int32), int Function(CEngine, Pointer<Float>, int)>(
            'caw_engine_input_peaks'),
        recordStart = lib.lookupFunction<CStr Function(CEngine, CStr), CStr Function(CEngine, CStr)>('caw_record_start'),
        recordStop = lib.lookupFunction<CStr Function(CEngine), CStr Function(CEngine)>('caw_record_stop'),
        recordStatus = lib.lookupFunction<CStr Function(CEngine), CStr Function(CEngine)>('caw_record_status'),
        recordRecover = lib.lookupFunction<CStr Function(CStr), CStr Function(CStr)>('caw_record_recover'),
        setInputLatency = lib.lookupFunction<Void Function(CEngine, Int64), void Function(CEngine, int)>(
            'caw_engine_set_input_latency'),
        inputLatency = lib.lookupFunction<CStr Function(CEngine), CStr Function(CEngine)>('caw_engine_input_latency'),
        pingStart = lib.lookupFunction<Int32 Function(CEngine), int Function(CEngine)>('caw_latency_ping_start'),
        pingResult = lib.lookupFunction<CStr Function(CEngine), CStr Function(CEngine)>('caw_latency_ping_result');

  static AudioBindings? _instance;

  /// One per isolate: a worker isolate looks the functions up again from the already loaded library.
  static AudioBindings get instance => _instance ??= AudioBindings._(DynamicLibrary.open(engineLibraryPath()));

  final void Function(CStr) free;
  final CStr Function(CEngine, CStr) assetLoad;
  final int Function(CEngine, CStr, double, double, int, int, Pointer<Float>) assetPeaks;
  final CStr Function() assetStoreStatus;
  final void Function(int) assetStoreSetBudget;
  final void Function() assetStorePurge;
  // API 32: tempo detection and transients (options JSON, result JSON).
  final CStr Function(CEngine, CStr, CStr) assetTempo;
  final CStr Function(CEngine, CStr, CStr) assetSlices;
  final CStr Function(CStr) sfzImport;
  final CStr Function(CStr, CStr, int) sfzExport;
  final CStr Function() inputDevices;
  final int Function(CEngine, int, CStr, CStr, int) configureInput;
  final int Function(CEngine, Pointer<Float>, int) inputPeaks;
  final CStr Function(CEngine, CStr) recordStart;
  final CStr Function(CEngine) recordStop;
  final CStr Function(CEngine) recordStatus;
  final CStr Function(CStr) recordRecover;
  final void Function(CEngine, int) setInputLatency;
  final CStr Function(CEngine) inputLatency;
  final int Function(CEngine) pingStart;
  final CStr Function(CEngine) pingResult;

  /// Reads and frees a JSON string the engine returned ('{}' for none).
  String take(CStr s) {
    if (s == nullptr) return '{}';
    try {
      return s.toDartString();
    } finally {
      free(s);
    }
  }
}
