// Raw dart:ffi bindings to the engine's C API (engine/include/caw.h, version 1).
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const int cawApiVersion = 25;  // must equal CAW_API_VERSION in engine/include/caw.h

/// CawNoteFxStats (API 22, #127): a layer's per-note FX slots.
final class CawNoteFxStatsStruct extends Struct {
  @Uint32()
  external int structSize;
  @Uint32()
  external int voices;
  @Uint32()
  external int budget;
  @Uint32()
  external int active;
  @Uint32()
  external int activeMask;
  @Uint32()
  external int overflowing;
  @Uint32()
  external int overflowed;
  @Uint32()
  external int stolen;
}

/// CawLayerMeterStereo (API 25): one layer's meter with each side's peak, as caw_engine_layer_meters fills them.
final class CawLayerMeterStereoStruct extends Struct {
  @Float()
  external double peak;
  @Float()
  external double peakL;
  @Float()
  external double peakR;
  @Float()
  external double progress;
  @Int32()
  external int active;
  @Int32()
  external int overloaded;
}

final class CawMetersStruct extends Struct {
  @Float()
  external double cpu;
  @Float()
  external double peakL;
  @Float()
  external double peakR;
  @Int32()
  external int playing;
  @Int32()
  external int overloaded;
  @Int64()
  external int position;
  @Int64()
  external int loopLength;
}

final class CawLayerMeterStruct extends Struct {
  @Float()
  external double peak;
  @Float()
  external double progress;
  @Int32()
  external int active;
  @Int32()
  external int overloaded;
}

final class CawHardwareProfileStruct extends Struct {
  @Uint16()
  external int logicalCores;
  @Uint32()
  external int memoryBudgetMiB;
  @Int32()
  external int supportsSimd;
  @Int32()
  external int supportsGpuCompute;
}

final class CawExecutionRequestStruct extends Struct {
  @Int32()
  external int workload;
  @Int32()
  external int pressure;
  @Int32()
  external int foregroundBusy;
  @Int32()
  external int allowGpu;
}

final class CawExecutionPlanStruct extends Struct {
  @Uint16()
  external int workerThreads;
  @Uint16()
  external int maxConcurrentJobs;
  @Uint32()
  external int preferredBatchFrames;
  @Int32()
  external int latencySensitive;
  @Int32()
  external int useSimd;
  @Int32()
  external int allowGpu;
  @Int32()
  external int yieldToForeground;
}

final class CawJobStatusStruct extends Struct {
  @Uint32()
  external int structSize;
  @Int32()
  external int state;
  @Int32()
  external int progress;
  @Int32()
  external int resultCode;
}

final class CawRenderOptionsStruct extends Struct {
  @Int32()
  external int kind;
  @Int32()
  external int sampleRate;
  @Int32()
  external int float32;
  @Int32()
  external int frames;
  @Double()
  external double seconds;
  external Pointer<Utf8> target;
  external Pointer<Utf8> param;
}

/// The engine library's file name on each platform. CAW_LIB overrides it (tests on a desktop build).
String engineLibraryPath() {
  final override = Platform.environment['CAW_LIB'];
  if (override != null && override.isNotEmpty) return override;
  if (Platform.isWindows) return 'caw.dll';
  if (Platform.isMacOS || Platform.isIOS) return 'libcaw.dylib';
  return 'libcaw.so';
}

class Bindings {
  Bindings._(DynamicLibrary lib)
      : _lib = lib,
        apiVersion = lib.lookupFunction<Int32 Function(), int Function()>('caw_api_version'),
        free = lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('caw_free'),
        create = lib.lookupFunction<Pointer<Void> Function(Int32), Pointer<Void> Function(int)>('caw_engine_create'),
        destroy = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('caw_engine_destroy'),
        setProject = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)>('caw_engine_set_project'),
        loadComponent = lib.lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Int32),
            Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int)>('caw_engine_load_component'),
        reloadComponent = lib.lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Int32),
            Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int)>('caw_engine_reload_component'),
        unloadComponent = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<Utf8>),
            int Function(Pointer<Void>, Pointer<Utf8>)>('caw_engine_unload_component'),
        components = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Void>), Pointer<Utf8> Function(Pointer<Void>)>(
            'caw_engine_components'),
        setComponentParam = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf8>, Uint32, Pointer<Utf8>, Double),
            int Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Utf8>, double)>('caw_engine_set_component_param'),
        setSend = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf8>, Uint32, Double, Int32, Int32),
            int Function(Pointer<Void>, Pointer<Utf8>, int, double, int, int)>('caw_engine_set_send'),
        setComponentBypass = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf8>, Uint32, Int32),
            int Function(Pointer<Void>, Pointer<Utf8>, int, int)>('caw_engine_set_component_bypass'),
        componentStates = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)>('caw_engine_component_states'),
        setComponentState = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf8>, Uint32, Pointer<Uint8>, Int32, Uint32),
            int Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Uint8>, int, int)>('caw_engine_set_component_state'),
        componentDisplay = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf8>, Uint32, Pointer<Float>, Int32),
            int Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Float>, int)>('caw_engine_component_display'),
        setLayerMix = lib.lookupFunction<Void Function(Pointer<Void>, Pointer<Utf8>, Double, Double, Int32, Int32),
            void Function(Pointer<Void>, Pointer<Utf8>, double, double, int, int)>('caw_engine_set_layer_mix'),
        setMaster = lib.lookupFunction<Void Function(Pointer<Void>, Double),
            void Function(Pointer<Void>, double)>('caw_engine_set_master'),
        noteOn = lib.lookupFunction<Void Function(Pointer<Void>, Pointer<Utf8>, Int32, Double, Double),
            void Function(Pointer<Void>, Pointer<Utf8>, int, double, double)>('caw_engine_note_on'),
        notePitch = lib.lookupFunction<Void Function(Pointer<Void>, Int32, Double),
            void Function(Pointer<Void>, int, double)>('caw_engine_note_pitch'),
        noteOff = lib.lookupFunction<Void Function(Pointer<Void>, Int32), void Function(Pointer<Void>, int)>(
            'caw_engine_note_off'),
        notesOff = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('caw_engine_notes_off'),
        play = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('caw_engine_play'),
        playAt = lib.lookupFunction<Void Function(Pointer<Void>, Double), void Function(Pointer<Void>, double)>(
            'caw_engine_play_at'),
        playCountIn = lib.lookupFunction<Void Function(Pointer<Void>, Double, Int32), void Function(Pointer<Void>, double, int)>(
            'caw_engine_play_count_in'),
        setMetronome = lib.lookupFunction<Void Function(Pointer<Void>, Int32), void Function(Pointer<Void>, int)>(
            'caw_engine_set_metronome'),
        releaseTouches = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
            'caw_engine_release_touches'),
        migrateInstrument = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>(
            'caw_migrate_instrument'),
        drumsInfo = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('caw_drums_info'),
        drumsRandomize = lib.lookupFunction<Pointer<Utf8> Function(Int32, Uint32, Double, Int32, Pointer<Utf8>),
            Pointer<Utf8> Function(int, int, double, int, Pointer<Utf8>)>('caw_drums_randomize'),
        drumsExplode = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>(
            'caw_drums_explode'),
        setQuality = lib.lookupFunction<Void Function(Pointer<Void>, Int32), void Function(Pointer<Void>, int)>(
            'caw_engine_set_quality'),
        audioSetBufferMode = lib.lookupFunction<Void Function(Pointer<Void>, Int32, Int32),
            void Function(Pointer<Void>, int, int)>('caw_audio_set_buffer_mode'),
        audioBufferFrames = lib.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
            'caw_audio_buffer_frames'),
        stop = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('caw_engine_stop'),
        clearOverload = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
            'caw_engine_clear_overload'),
        meters = lib.lookupFunction<Void Function(Pointer<Void>, Pointer<CawMetersStruct>),
            void Function(Pointer<Void>, Pointer<CawMetersStruct>)>('caw_engine_meters'),
        layerMeter = lib.lookupFunction<Int32 Function(Pointer<Void>, Int32, Pointer<CawLayerMeterStruct>),
            int Function(Pointer<Void>, int, Pointer<CawLayerMeterStruct>)>('caw_engine_layer_meter'),
        layerMeterStereo = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Int32, Pointer<CawLayerMeterStruct>, Pointer<Float>, Pointer<Float>),
            int Function(Pointer<Void>, int, Pointer<CawLayerMeterStruct>, Pointer<Float>, Pointer<Float>)>(
            'caw_engine_layer_meter_stereo'),
        layerMeters = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<CawLayerMeterStereoStruct>, Int32),
            int Function(Pointer<Void>, Pointer<CawLayerMeterStereoStruct>, int)>('caw_engine_layer_meters'),
        scope = lib.lookupFunction<Int32 Function(Pointer<Void>, Int32, Pointer<Float>, Int32),
            int Function(Pointer<Void>, int, Pointer<Float>, int)>('caw_engine_scope'),
        process = lib.lookupFunction<Void Function(Pointer<Void>, Pointer<Float>, Pointer<Float>, Int32),
            void Function(Pointer<Void>, Pointer<Float>, Pointer<Float>, int)>('caw_engine_process'),
        audioStart = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32),
            int Function(Pointer<Void>, Pointer<Utf8>, int)>('caw_audio_start'),
        audioStop = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('caw_audio_stop'),
        render = lib.lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<CawRenderOptionsStruct>, Pointer<Utf8>, Pointer<Int32>,
                Pointer<Int32>, Pointer<Utf8>, Int32),
            int Function(Pointer<Utf8>, Pointer<CawRenderOptionsStruct>, Pointer<Utf8>, Pointer<Int32>, Pointer<Int32>,
                Pointer<Utf8>, int)>('caw_render'),
        patternFromMidi = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Uint8>, Int32),
            Pointer<Utf8> Function(Pointer<Uint8>, int)>('caw_pattern_from_midi'),
        patternExport = lib.lookupFunction<Int32 Function(Pointer<Utf8>, Double, Int32, Int32, Pointer<Utf8>, Pointer<Utf8>, Int32),
            int Function(Pointer<Utf8>, double, int, int, Pointer<Utf8>, Pointer<Utf8>, int)>('caw_pattern_export'),
        hardwareProfileDetect = lib.lookupFunction<
            Int32 Function(Pointer<CawHardwareProfileStruct>),
            int Function(Pointer<CawHardwareProfileStruct>)>('caw_hardware_profile_detect'),
        executionPlan = lib.lookupFunction<
            Int32 Function(Pointer<CawHardwareProfileStruct>, Pointer<CawExecutionRequestStruct>,
                Pointer<CawExecutionPlanStruct>),
            int Function(Pointer<CawHardwareProfileStruct>, Pointer<CawExecutionRequestStruct>,
                Pointer<CawExecutionPlanStruct>)>('caw_execution_plan'),
        workerPoolCreate = lib.lookupFunction<Pointer<Void> Function(Uint32), Pointer<Void> Function(int)>(
            'caw_worker_pool_create'),
        workerPoolDestroy = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
            'caw_worker_pool_destroy'),
        workerPoolApply = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<CawExecutionRequestStruct>, Pointer<CawExecutionPlanStruct>),
            int Function(Pointer<Void>, Pointer<CawExecutionRequestStruct>, Pointer<CawExecutionPlanStruct>)>(
            'caw_worker_pool_apply'),
        workerPoolSubmitProject = lib.lookupFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Utf8>, Int32),
            Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Utf8>, int)>('caw_worker_pool_submit_project'),
        workerPoolSubmitRender = lib.lookupFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Pointer<CawRenderOptionsStruct>, Pointer<Utf8>, Int32),
            Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Pointer<CawRenderOptionsStruct>, Pointer<Utf8>, int)>(
            'caw_worker_pool_submit_render'),
        jobWait = lib.lookupFunction<Int32 Function(Pointer<Void>, Uint32), int Function(Pointer<Void>, int)>(
            'caw_job_wait'),
        jobGetStatus = lib.lookupFunction<
            Int32 Function(Pointer<Void>, Pointer<CawJobStatusStruct>),
            int Function(Pointer<Void>, Pointer<CawJobStatusStruct>)>('caw_job_get_status'),
        jobResult = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Void>), Pointer<Utf8> Function(Pointer<Void>)>(
            'caw_job_result'),
        jobError = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Void>), Pointer<Utf8> Function(Pointer<Void>)>(
            'caw_job_error'),
        jobCancel = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('caw_job_cancel'),
        jobRelease = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('caw_job_release'),
        workerPoolWaitIdle = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
            'caw_worker_pool_wait_idle'),
        // API 10: the audio device's choice and state, the click's sound and a test tone.
        audioDevices = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('caw_audio_devices'),
        audioConfigure = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Int32, Int32),
            int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int, int)>('caw_audio_configure'),
        audioStatus = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Void>), Pointer<Utf8> Function(Pointer<Void>)>(
            'caw_audio_status'),
        // API 23: the running device's output and input latency.
        audioLatency = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Void>), Pointer<Utf8> Function(Pointer<Void>)>(
            'caw_audio_latency'),
        setMetronomeSound = lib.lookupFunction<Void Function(Pointer<Void>, Double, Int32),
            void Function(Pointer<Void>, double, int)>('caw_engine_set_metronome_sound'),
        testTone = lib.lookupFunction<Void Function(Pointer<Void>, Double), void Function(Pointer<Void>, double)>(
            'caw_engine_test_tone'),
        testToneSounding = lib.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
            'caw_engine_test_tone_sounding'),
        // API 15: MIDI from devices, frame-accurate.
        midiClockNs = lib.lookupFunction<Int64 Function(), int Function()>('caw_midi_clock_ns'),
        midiUmp = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint32>, Int32, Int64),
            int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint32>, int, int)>('caw_engine_midi_ump'),
        midiBytes = lib.lookupFunction<Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, Int32, Int64),
            int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, int, int)>('caw_engine_midi_bytes'),
        midiRelease = lib.lookupFunction<Void Function(Pointer<Void>, Pointer<Utf8>),
            void Function(Pointer<Void>, Pointer<Utf8>)>('caw_engine_midi_release'),
        setMidiOptions = lib.lookupFunction<Void Function(Pointer<Void>, Int32, Double, Double, Double),
            void Function(Pointer<Void>, int, double, double, double)>('caw_engine_set_midi_options'),
        midiDropped = lib.lookupFunction<Int64 Function(Pointer<Void>), int Function(Pointer<Void>)>(
            'caw_engine_midi_dropped'),
        positionAt = lib.lookupFunction<Int64 Function(Pointer<Void>, Int64), int Function(Pointer<Void>, int)>(
            'caw_engine_position_at'),
        // The Build tools (#163, #164): the testing suite and the sample-pack maker; both block, so call them off
        // the UI isolate.
        componentTest = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>, Int32, Pointer<Utf8>, Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Utf8>, int, Pointer<Utf8>, Pointer<Utf8>)>('caw_component_test'),
        samplePackRender = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>, Int32, Pointer<Int32>, Pointer<Int32>),
            Pointer<Utf8> Function(Pointer<Utf8>, int, Pointer<Int32>, Pointer<Int32>)>('caw_sample_pack_render'),
        // Song renders (API 15): the mix and stems; it blocks, so it runs as a worker-pool job.
        renderSong = lib.lookupFunction<
            Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Int32>, Pointer<Int32>),
            Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Int32>, Pointer<Int32>)>('caw_render_song'),
        workerPoolSubmitSong = lib.lookupFunction<
            Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Int32),
            Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int)>('caw_worker_pool_submit_song');

  static Bindings? _instance;

  /// Loads the engine library once per isolate.
  final DynamicLibrary _lib;

  // Project modulation (API 19, #161; caw.h).
  late final int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, double) setModulatorParam = _lib.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Double),
      int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, double)>('caw_engine_set_modulator_param');
  late final int Function(Pointer<Void>, Pointer<Utf8>, int) setModulatorBypass = _lib.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Utf8>, Int32), int Function(Pointer<Void>, Pointer<Utf8>, int)>(
      'caw_engine_set_modulator_bypass');
  late final int Function(Pointer<Void>, int, double) setModulationAmount = _lib.lookupFunction<
      Int32 Function(Pointer<Void>, Uint32, Double), int Function(Pointer<Void>, int, double)>(
      'caw_engine_set_modulation_amount');
  late final int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Float>, int) modulatorOutputs = _lib.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Float>, Int32),
      int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Float>, int)>('caw_engine_modulator_outputs');
  late final int Function(Pointer<Void>, int, Pointer<Float>) modulationOffset = _lib.lookupFunction<
      Int32 Function(Pointer<Void>, Uint32, Pointer<Float>), int Function(Pointer<Void>, int, Pointer<Float>)>(
      'caw_engine_modulation_offset');

  // Per-note FX (API 22, #127; caw.h).
  late final int Function(Pointer<Void>, Pointer<Utf8>, Pointer<CawNoteFxStatsStruct>) noteFxStats = _lib.lookupFunction<
      Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<CawNoteFxStatsStruct>),
      int Function(Pointer<Void>, Pointer<Utf8>, Pointer<CawNoteFxStatsStruct>)>('caw_engine_note_fx_stats');

  static Bindings get instance => _instance ??= Bindings._(DynamicLibrary.open(engineLibraryPath()));

  final int Function() apiVersion;
  final void Function(Pointer<Utf8>) free;
  final Pointer<Void> Function(int) create;
  final void Function(Pointer<Void>) destroy;
  final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>) setProject;
  final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int) loadComponent;
  final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int) reloadComponent;
  final int Function(Pointer<Void>, Pointer<Utf8>) unloadComponent;
  final Pointer<Utf8> Function(Pointer<Void>) components;
  final int Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Utf8>, double) setComponentParam;
  final int Function(Pointer<Void>, Pointer<Utf8>, int, double, int, int) setSend;
  final int Function(Pointer<Void>, Pointer<Utf8>, int, int) setComponentBypass;
  final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>) componentStates;
  final int Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Uint8>, int, int) setComponentState;
  final int Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Float>, int) componentDisplay;
  final void Function(Pointer<Void>, Pointer<Utf8>, double, double, int, int) setLayerMix;
  final void Function(Pointer<Void>, double) setMaster;
  final void Function(Pointer<Void>, Pointer<Utf8>, int, double, double) noteOn;
  final void Function(Pointer<Void>, int, double) notePitch;
  final void Function(Pointer<Void>, int) noteOff;
  final void Function(Pointer<Void>) notesOff;
  final void Function(Pointer<Void>) play;
  final void Function(Pointer<Void>, double) playAt;
  final void Function(Pointer<Void>, double, int) playCountIn;
  final void Function(Pointer<Void>, int) setMetronome;
  final Pointer<Utf8> Function(Pointer<Utf8>) migrateInstrument;
  final Pointer<Utf8> Function() drumsInfo;
  final Pointer<Utf8> Function(int, int, double, int, Pointer<Utf8>) drumsRandomize;
  final Pointer<Utf8> Function(Pointer<Utf8>) drumsExplode;
  final void Function(Pointer<Void>, int) setQuality;
  final void Function(Pointer<Void>, int, int) audioSetBufferMode;
  final int Function(Pointer<Void>) audioBufferFrames;
  final void Function(Pointer<Void>) releaseTouches;
  final void Function(Pointer<Void>) stop;
  final void Function(Pointer<Void>) clearOverload;
  final void Function(Pointer<Void>, Pointer<CawMetersStruct>) meters;
  final int Function(Pointer<Void>, int, Pointer<CawLayerMeterStruct>) layerMeter;
  final int Function(Pointer<Void>, int, Pointer<CawLayerMeterStruct>, Pointer<Float>, Pointer<Float>) layerMeterStereo;
  final int Function(Pointer<Void>, Pointer<CawLayerMeterStereoStruct>, int) layerMeters;
  final int Function(Pointer<Void>, int, Pointer<Float>, int) scope;
  final void Function(Pointer<Void>, Pointer<Float>, Pointer<Float>, int) process;
  final int Function(Pointer<Void>, Pointer<Utf8>, int) audioStart;
  final void Function(Pointer<Void>) audioStop;
  final int Function(Pointer<Utf8>, Pointer<CawRenderOptionsStruct>, Pointer<Utf8>, Pointer<Int32>, Pointer<Int32>,
      Pointer<Utf8>, int) render;
  final Pointer<Utf8> Function(Pointer<Uint8>, int) patternFromMidi;
  final int Function(Pointer<Utf8>, double, int, int, Pointer<Utf8>, Pointer<Utf8>, int) patternExport;
  final int Function(Pointer<CawHardwareProfileStruct>) hardwareProfileDetect;
  final int Function(Pointer<CawHardwareProfileStruct>, Pointer<CawExecutionRequestStruct>,
      Pointer<CawExecutionPlanStruct>) executionPlan;
  final Pointer<Void> Function(int) workerPoolCreate;
  final void Function(Pointer<Void>) workerPoolDestroy;
  final int Function(Pointer<Void>, Pointer<CawExecutionRequestStruct>, Pointer<CawExecutionPlanStruct>) workerPoolApply;
  final Pointer<Void> Function(Pointer<Void>, Pointer<Void>, Pointer<Utf8>, int) workerPoolSubmitProject;
  final Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Pointer<CawRenderOptionsStruct>, Pointer<Utf8>, int)
      workerPoolSubmitRender;
  final int Function(Pointer<Void>, int) jobWait;
  final int Function(Pointer<Void>, Pointer<CawJobStatusStruct>) jobGetStatus;
  final Pointer<Utf8> Function(Pointer<Void>) jobResult;
  final Pointer<Utf8> Function(Pointer<Void>) jobError;
  final void Function(Pointer<Void>) jobCancel;
  final void Function(Pointer<Void>) jobRelease;
  final void Function(Pointer<Void>) workerPoolWaitIdle;
  final Pointer<Utf8> Function() audioDevices;
  final int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int, int) audioConfigure;
  final Pointer<Utf8> Function(Pointer<Void>) audioStatus;
  final Pointer<Utf8> Function(Pointer<Void>) audioLatency;
  final void Function(Pointer<Void>, double, int) setMetronomeSound;
  final void Function(Pointer<Void>, double) testTone;
  final int Function(Pointer<Void>) testToneSounding;
  final int Function() midiClockNs;
  final int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint32>, int, int) midiUmp;
  final int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Uint8>, int, int) midiBytes;
  final void Function(Pointer<Void>, Pointer<Utf8>) midiRelease;
  final void Function(Pointer<Void>, int, double, double, double) setMidiOptions;
  final int Function(Pointer<Void>) midiDropped;
  final int Function(Pointer<Void>, int) positionAt;
  final Pointer<Utf8> Function(Pointer<Utf8>, int, Pointer<Utf8>, Pointer<Utf8>) componentTest;
  final Pointer<Utf8> Function(Pointer<Utf8>, int, Pointer<Int32>, Pointer<Int32>) samplePackRender;
  final Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Int32>, Pointer<Int32>) renderSong;
  final Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int) workerPoolSubmitSong;
}
