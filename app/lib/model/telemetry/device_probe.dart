// The device facts an H2 report carries (H2 `device`, with the owner's 2026-11-12 additions): platform, CPU
// architecture, OS name and version, the maker's name and model, form factor, CPU model, core types and their top
// clocks, RAM. Read from the platform's own files once per report; what a platform doesn't give is null (owner,
// 2026-11-12: unknowns are null, never 0). Only maker-defined names are read: never the device's or computer's own
// name, a serial number, a hardware address or a full OS build string.
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/services.dart';

import 'report_schema.dart';

/// The probed part of `device` (the app adds screen, audio, peripherals, profile, eco and refresh rate).
class DeviceFacts {
  const DeviceFacts({
    required this.platform,
    this.arch,
    this.osName,
    this.osVersion,
    this.manufacturer,
    this.model,
    this.formFactor,
    this.cpu,
    this.big,
    this.little,
    this.other,
    this.maxClockMHz,
    this.ramGB,
    this.gpu,
  });

  /// android, windows, linux (or ios, macos); null on a platform the contract doesn't cover.
  final String? platform;
  final String? arch, osName, osVersion, manufacturer, model, formFactor, cpu, gpu;
  final int? big, little, other, ramGB;
  final List<int>? maxClockMHz;

  Map<String, Object?> toJson() => {
        'platform': platform,
        'arch': ?arch,
        'osName': ?osName,
        'osVersion': osVersion,
        'manufacturer': ?manufacturer,
        'model': ?model,
        'formFactor': ?formFactor,
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
/// "big" when there are at least two clusters; one cluster is "other". Clocks per cluster, fastest first (at most
/// 4), as MHz rounded to 100. Null counts and clocks when no core's clock could be read.
({int? big, int? little, int? other, List<int>? clocks}) coreTypes(List<int> maxKhzPerCore) {
  final known = maxKhzPerCore.where((k) => k > 0).toList();
  if (known.isEmpty) return (big: null, little: null, other: null, clocks: null);
  final clusters = <int, int>{};
  for (final k in known) {
    clusters[clockMHz(k)] = (clusters[clockMHz(k)] ?? 0) + 1;
  }
  final clocks = (clusters.keys.toList()..sort((a, b) => b.compareTo(a))).take(4).toList();
  if (clusters.length == 1) return (big: 0, little: 0, other: known.length, clocks: clocks);
  final little = clusters[clusters.keys.reduce((a, b) => a < b ? a : b)]!;
  return (big: known.length - little, little: little, other: 0, clocks: clocks);
}

/// The CPU's name from `/proc/cpuinfo`: x86's "model name", else Arm's "Hardware" line, else Arm's distinct
/// "CPU part" codes ("arm 0xd48/0xd47/0xd46"); null when none.
String? cpuFromCpuinfo(String text) {
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
  return parts.isEmpty ? null : 'arm ${parts.join('/')}';
}

/// Total RAM from `/proc/meminfo` (kB), as bytes; 0 when missing.
int ramFromMeminfo(String text) {
  final m = RegExp(r'^MemTotal:\s+(\d+)\s*kB', multiLine: true).firstMatch(text);
  return m == null ? 0 : int.parse(m.group(1)!) * 1024;
}

/// The major version's digits from a version text ("14", "24.04", "10.0.22631"), or null.
String? majorVersion(String? text) => RegExp(r'^\s*(\d{1,3})').firstMatch(text ?? '')?.group(1);

/// A version as H2 now takes it: major, or major.minor[.build] ("14", "24.04", "10.0.22631"); anything longer or
/// with letters (a build fingerprint) is cut to its numeric front, null when there is none.
String? osVersionOf(String? text) {
  final m = RegExp(r'^\s*(\d{1,4}(?:\.\d{1,6}){0,2})').firstMatch(text ?? '');
  return m?.group(1);
}

/// Windows' name and version from `Platform.operatingSystemVersion` ('"Windows 10 Pro" 10.0 (Build 22631)'): build
/// 22000 and later is Windows 11 (Microsoft reports Windows 11 as version 10.0). The edition ("Pro") is left out.
({String? name, String? version}) windowsOs(String text) {
  final build = RegExp(r'Build (\d+)').firstMatch(text)?.group(1);
  final mm = RegExp(r'(\d+)\.(\d+)').firstMatch(text);
  if (mm == null) return (name: 'Windows', version: null);
  final n = int.tryParse(build ?? '');
  final name = mm.group(1) == '10' && n != null ? (n >= 22000 ? 'Windows 11' : 'Windows 10') : 'Windows';
  return (name: name, version: [mm.group(1), mm.group(2), ?build].join('.'));
}

/// `/etc/os-release`'s NAME and VERSION_ID (the distribution's own names, not the machine's).
({String? name, String? version}) linuxOs(String text) {
  String? field(String key) {
    final m = RegExp('^$key="?([^"\\n]*)"?', multiLine: true).firstMatch(text);
    final v = m?.group(1)?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  return (name: field('NAME'), version: osVersionOf(field('VERSION_ID')));
}

/// The SMBIOS chassis type (`/sys/class/dmi/id/chassis_type`) as H2's formFactor ([Assumption] the codes as the
/// DMTF SMBIOS spec's system enclosure types, from memory, not re-read).
String chassisFormFactor(int? type) => switch (type) {
      3 || 4 || 5 || 6 || 7 || 13 || 15 || 16 || 24 || 35 || 36 => 'desktop',
      8 || 9 || 10 || 14 || 31 || 32 => 'laptop',
      11 || 30 => 'tablet',
      null => 'unknown',
      _ => 'other',
    };

/// A DMI or firmware text the maker set, or null for the usual placeholders ("To Be Filled By O.E.M.", "Default
/// string", "System Product Name").
String? makerText(String? v) {
  final t = v?.trim();
  if (t == null || t.isEmpty) return null;
  const junk = ['to be filled', 'default string', 'system product name', 'system manufacturer', 'not specified', 'o.e.m.'];
  final low = t.toLowerCase();
  return junk.any(low.contains) ? null : t;
}

/// `Abi.current()` as H2's `arch`.
String archOf(Abi abi) {
  final s = abi.toString(); // e.g. android_arm64, windows_x64
  final cpu = s.substring(s.indexOf('_') + 1);
  return switch (cpu) {
    'arm64' => 'arm64',
    'arm' => 'arm',
    'x64' => 'x64',
    'ia32' => 'x86',
    'riscv64' => 'riscv64',
    _ => 'other',
  };
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

  /// HKLM\HARDWARE\DESCRIPTION\System\BIOS's SystemManufacturer and SystemProductName: the firmware's SMBIOS
  /// strings ([Assumption]: the same values WMI's Win32_ComputerSystem gives), never the computer's name.
  Future<({String? maker, String? model})> _windowsSystem() async {
    try {
      final r = await Process.run('reg', [r'query', r'HKLM\HARDWARE\DESCRIPTION\System\BIOS'])
          .timeout(const Duration(seconds: 5));
      final out = '${r.stdout}';
      String? value(String key) => RegExp('^\\s*$key\\s+REG_SZ\\s+(.*)\$', multiLine: true).firstMatch(out)?.group(1);
      return (maker: makerText(value('SystemManufacturer')), model: makerText(value('SystemProductName')));
    } catch (_) {
      return (maker: null, model: null);
    }
  }

  @override
  Future<DeviceFacts> read() async {
    final arch = archOf(Abi.current());
    if (Platform.isWindows) {
      final os = windowsOs(Platform.operatingSystemVersion);
      final system = await _windowsSystem();
      return DeviceFacts(
        platform: 'windows',
        arch: arch,
        osName: os.name,
        osVersion: os.version,
        manufacturer: system.maker,
        model: system.model,
        cpu: Platform.environment['PROCESSOR_IDENTIFIER'],
        other: Platform.numberOfProcessors,
      );
    }
    if (!Platform.isAndroid && !Platform.isLinux) return DeviceFacts(platform: null, arch: arch);
    final cores = coreTypes(await _maxKhzPerCore());
    var cpu = cpuFromCpuinfo(await _read('/proc/cpuinfo') ?? '');
    var ram = ramFromMeminfo(await _read('/proc/meminfo') ?? '');
    String? osName, os, maker, model, formFactor;
    if (Platform.isAndroid) {
      osName = 'Android';
      try {
        final m = await _channel.invokeMapMethod<String, Object?>('device');
        os = osVersionOf(m?['osRelease'] as String?);
        final soc = m?['socModel'] as String?;
        if (soc != null && soc.isNotEmpty && soc != 'unknown') cpu = soc;
        final mem = (m?['totalMemBytes'] as num?)?.toInt() ?? 0;
        if (mem > 0) ram = mem;
        maker = makerText(m?['manufacturer'] as String?); // Build.MANUFACTURER
        model = makerText(m?['model'] as String?); // Build.MODEL: the maker's model name
      } on MissingPluginException {
        // an older build without the call
      } on PlatformException {
        // left unknown
      }
    } else {
      final release = linuxOs(await _read('/etc/os-release') ?? '');
      osName = release.name;
      os = release.version;
      maker = makerText(await _read('/sys/class/dmi/id/sys_vendor'));
      model = makerText(await _read('/sys/class/dmi/id/product_name'));
      formFactor = chassisFormFactor(int.tryParse((await _read('/sys/class/dmi/id/chassis_type'))?.trim() ?? ''));
    }
    return DeviceFacts(
      platform: Platform.isAndroid ? 'android' : 'linux',
      arch: arch,
      osName: osName,
      osVersion: os,
      manufacturer: maker,
      model: model,
      formFactor: formFactor,
      cpu: cpu,
      big: cores.big,
      little: cores.little,
      other: cores.other ?? (cores.big == null ? Platform.numberOfProcessors : null),
      maxClockMHz: cores.clocks,
      ramGB: ram > 0 ? ramGB(ram) : null,
    );
  }
}
