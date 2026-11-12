// The device facts an H2 report carries (beta readiness plan H2 `device`): OS major version, CPU model, core types and
// their top clocks, RAM. Read from the platform's own files once per report; what a platform doesn't give is left out
// or "unknown". Nothing that names the user, the device's owner or its files is read.
import 'dart:io';

import 'package:flutter/services.dart';

import 'report_schema.dart';

/// The probed part of `device` (the app adds audio, profile, eco and refresh rate).
class DeviceFacts {
  const DeviceFacts({
    required this.platform,
    this.osVersion,
    this.cpu = 'unknown',
    this.big = 0,
    this.little = 0,
    this.other = 0,
    this.maxClockMHz = const [],
    this.ramGB = 0,
    this.gpu = 'unknown',
  });

  /// android, windows or linux; null on a platform the contract doesn't cover (nothing is then sent).
  final String? platform;

  /// The OS major version as digits, or null when unknown (H2 allows digits only, so the field is then left out).
  final String? osVersion;
  final String cpu, gpu;
  final int big, little, other;
  final List<int> maxClockMHz;

  /// 0 when unknown.
  final int ramGB;

  Map<String, Object?> toJson() => {
        'platform': platform,
        'osVersion': ?osVersion,
        'cpu': cpu,
        'cores': {'big': big, 'little': little, 'other': other},
        'maxClockMHz': maxClockMHz,
        'ramGB': ramGB,
        'gpu': gpu,
      };
}

abstract class DeviceProbe {
  Future<DeviceFacts> read();
}

// ---------- parsing, kept pure for tests ----------

/// Core types from each core's top clock in kHz (`cpuinfo_max_freq`): the slowest cluster is "little" and the rest
/// "big" when there are at least two clusters; one cluster is "other". Clocks per cluster, fastest first, as MHz
/// rounded to 100.
({int big, int little, int other, List<int> clocks}) coreTypes(List<int> maxKhzPerCore) {
  final known = maxKhzPerCore.where((k) => k > 0).toList();
  if (known.isEmpty) return (big: 0, little: 0, other: maxKhzPerCore.length, clocks: const []);
  final clusters = <int, int>{};
  for (final k in known) {
    clusters[clockMHz(k)] = (clusters[clockMHz(k)] ?? 0) + 1;
  }
  final clocks = (clusters.keys.toList()..sort((a, b) => b.compareTo(a))).take(4).toList(); // H2: up to 4
  if (clocks.length == 1) return (big: 0, little: 0, other: known.length, clocks: clocks);
  final little = clusters[clocks.last]!;
  return (big: known.length - little, little: little, other: 0, clocks: clocks);
}

/// The CPU's name from `/proc/cpuinfo`: x86's "model name", else Arm's "Hardware" line, else Arm's distinct
/// "CPU part" codes ("arm 0xd48/0xd47/0xd46").
String cpuFromCpuinfo(String text) {
  String? field(String name) {
    for (final line in text.split('\n')) {
      final i = line.indexOf(':');
      if (i > 0 && line.substring(0, i).trim() == name) return line.substring(i + 1).trim();
    }
    return null;
  }

  final model = field('model name') ?? field('Hardware');
  if (model != null && model.isNotEmpty) return model;
  final parts = <String>[];
  for (final line in text.split('\n')) {
    final i = line.indexOf(':');
    if (i > 0 && line.substring(0, i).trim() == 'CPU part') {
      final p = line.substring(i + 1).trim().toLowerCase();
      if (!parts.contains(p)) parts.add(p);
    }
  }
  return parts.isEmpty ? 'unknown' : 'arm ${parts.join('/')}';
}

/// Total RAM from `/proc/meminfo` (kB), as bytes; 0 when missing.
int ramFromMeminfo(String text) {
  final m = RegExp(r'^MemTotal:\s+(\d+)\s*kB', multiLine: true).firstMatch(text);
  return m == null ? 0 : int.parse(m.group(1)!) * 1024;
}

/// The major version's digits from a version text ("14", "24.04", "10.0.22631"), or null.
String? majorVersion(String? text) {
  final m = RegExp(r'^\s*(\d{1,3})').firstMatch(text ?? '');
  return m?.group(1);
}

/// Windows' major version from `Platform.operatingSystemVersion` ('"Windows 10 Pro" 10.0 (Build 22631)'): build
/// 22000 and later is Windows 11 (Microsoft reports Windows 11 as version 10.0).
String? windowsMajor(String text) {
  final build = int.tryParse(RegExp(r'Build (\d+)').firstMatch(text)?.group(1) ?? '');
  final major = RegExp(r'(\d+)\.\d+').firstMatch(text)?.group(1);
  if (major == '10' && build != null) return build >= 22000 ? '11' : '10';
  return major;
}

// ---------- the real probe ----------

class IoDeviceProbe implements DeviceProbe {
  static const _channel = MethodChannel('caw/resource_signals');

  Future<String?> _read(String path) async {
    try {
      return await File(path).readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<List<int>> _maxKhzPerCore() async {
    final out = <int>[];
    for (var i = 0; i < Platform.numberOfProcessors; i++) {
      final t = await _read('/sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_max_freq');
      out.add(int.tryParse(t?.trim() ?? '') ?? 0);
    }
    return out;
  }

  @override
  Future<DeviceFacts> read() async {
    if (Platform.isWindows) {
      return DeviceFacts(
        platform: 'windows',
        osVersion: windowsMajor(Platform.operatingSystemVersion),
        cpu: Platform.environment['PROCESSOR_IDENTIFIER'] ?? 'unknown',
        other: Platform.numberOfProcessors,
      );
    }
    if (!Platform.isAndroid && !Platform.isLinux) return const DeviceFacts(platform: null);
    final cores = coreTypes(await _maxKhzPerCore());
    var cpu = cpuFromCpuinfo(await _read('/proc/cpuinfo') ?? '');
    var ram = ramFromMeminfo(await _read('/proc/meminfo') ?? '');
    String? os;
    if (Platform.isAndroid) {
      try {
        final m = await _channel.invokeMapMethod<String, Object?>('device');
        os = majorVersion(m?['osRelease'] as String?);
        final soc = m?['socModel'] as String?;
        if (soc != null && soc.isNotEmpty && soc != 'unknown') cpu = soc;
        final mem = (m?['totalMemBytes'] as num?)?.toInt() ?? 0;
        if (mem > 0) ram = mem;
      } on MissingPluginException {
        // an older build without the call
      } on PlatformException {
        // left unknown
      }
    } else {
      final release = await _read('/etc/os-release') ?? '';
      os = majorVersion(RegExp(r'^VERSION_ID="?([^"\n]*)', multiLine: true).firstMatch(release)?.group(1));
    }
    return DeviceFacts(
      platform: Platform.isAndroid ? 'android' : 'linux',
      osVersion: os,
      cpu: cpu,
      big: cores.big,
      little: cores.little,
      other: cores.other,
      maxClockMHz: cores.clocks,
      ramGB: ramGB(ram),
    );
  }
}
