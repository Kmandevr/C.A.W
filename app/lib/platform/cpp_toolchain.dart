// Describes locally provisioned C++ toolchains and validates their host-specific execution contract.
import 'dart:convert';

enum CppToolchainExecutionMode { process, inProcess }

class CppToolchainArtifact {
  const CppToolchainArtifact({required this.path, required this.sha256, required this.sizeBytes});
  final String path;
  final String sha256;
  final int sizeBytes;

  factory CppToolchainArtifact.fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    final digest = json['sha256'];
    final size = json['size_bytes'];
    if (path is! String || !_isSafeRelativePath(path)) {
      throw const FormatException('Toolchain artifact path must be a safe relative path.');
    }
    if (digest is! String || !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('Toolchain artifact requires a SHA-256 digest.');
    }
    if (size is! int || size <= 0) {
      throw const FormatException('Toolchain artifact size must be a positive integer.');
    }
    return CppToolchainArtifact(path: path, sha256: digest.toLowerCase(), sizeBytes: size);
  }

  Map<String, Object> toJson() => {'path': path, 'sha256': sha256, 'size_bytes': sizeBytes};
}

class CppToolchainManifest {
  const CppToolchainManifest({
    required this.id, required this.host, required this.executionMode,
    required this.compilerVersion, required this.sdkVersion, required this.artifacts,
    this.androidMinApi, this.entryLibrary, this.compilerExecutable,
  });

  final String id;
  final String host;
  final CppToolchainExecutionMode executionMode;
  final String compilerVersion;
  final String sdkVersion;
  final List<CppToolchainArtifact> artifacts;
  final int? androidMinApi;
  final String? entryLibrary;
  final String? compilerExecutable;

  static CppToolchainManifest decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Toolchain manifest must be a JSON object.');
    }
    return CppToolchainManifest.fromJson(decoded);
  }

  factory CppToolchainManifest.fromJson(Map<String, dynamic> json) {
    if (json['format'] != 'caw.toolchain' || json['version'] != 1) {
      throw const FormatException('Unsupported C.A.W. toolchain manifest format or version.');
    }
    final id = json['id'];
    final host = json['host'];
    final mode = json['execution_mode'];
    final compilerVersion = json['compiler_version'];
    final sdkVersion = json['sdk_version'];
    final rawArtifacts = json['artifacts'];
    if (id is! String || id.isEmpty || id.length > 128 ||
        compilerVersion is! String || compilerVersion.isEmpty ||
        sdkVersion is! String || sdkVersion.isEmpty) {
      throw const FormatException('Toolchain identity, compiler version and SDK version are required.');
    }
    if (host is! String || !const {'android-arm64', 'linux-x64', 'windows-x64'}.contains(host)) {
      throw const FormatException('Unsupported C.A.W. toolchain host.');
    }
    final executionMode = switch (mode) {
      'process' => CppToolchainExecutionMode.process,
      'in_process' => CppToolchainExecutionMode.inProcess,
      _ => throw const FormatException('Unknown toolchain execution mode.'),
    };
    final expectedMode = host == 'android-arm64'
        ? CppToolchainExecutionMode.inProcess : CppToolchainExecutionMode.process;
    if (executionMode != expectedMode) {
      throw FormatException('The $host toolchain must use ${expectedMode.name} execution.');
    }
    if (rawArtifacts is! List || rawArtifacts.isEmpty) {
      throw const FormatException('Toolchain must declare at least one artifact.');
    }
    final artifacts = rawArtifacts.map((entry) {
      if (entry is! Map<String, dynamic>) {
        throw const FormatException('Toolchain artifact entries must be objects.');
      }
      return CppToolchainArtifact.fromJson(entry);
    }).toList(growable: false);
    final paths = artifacts.map((artifact) => artifact.path).toSet();
    if (paths.length != artifacts.length) {
      throw const FormatException('Toolchain artifact paths must be unique.');
    }

    final androidMinApi = json['android_min_api'];
    final entryLibrary = json['entry_library'];
    final compilerExecutable = json['compiler_executable'];
    if (host == 'android-arm64') {
      if (androidMinApi is! int || androidMinApi < 26 ||
          entryLibrary is! String || !_isSafeRelativePath(entryLibrary) ||
          !paths.contains(entryLibrary) || compilerExecutable != null) {
        throw const FormatException('Android toolchains require a bundled native entry library and minimum API; executable paths are forbidden.');
      }
    } else if (compilerExecutable is! String ||
        !_isSafeRelativePath(compilerExecutable) || !paths.contains(compilerExecutable) ||
        entryLibrary != null || androidMinApi != null) {
      throw const FormatException('Desktop toolchains require a declared compiler executable.');
    }

    return CppToolchainManifest(
      id: id, host: host, executionMode: executionMode,
      compilerVersion: compilerVersion, sdkVersion: sdkVersion, artifacts: artifacts,
      androidMinApi: androidMinApi as int?, entryLibrary: entryLibrary as String?,
      compilerExecutable: compilerExecutable as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'format': 'caw.toolchain', 'version': 1, 'id': id, 'host': host,
    'execution_mode': executionMode == CppToolchainExecutionMode.inProcess ? 'in_process' : 'process',
    'compiler_version': compilerVersion, 'sdk_version': sdkVersion,
    if (androidMinApi != null) 'android_min_api': androidMinApi,
    if (entryLibrary != null) 'entry_library': entryLibrary,
    if (compilerExecutable != null) 'compiler_executable': compilerExecutable,
    'artifacts': artifacts.map((artifact) => artifact.toJson()).toList(),
  };
}

bool _isSafeRelativePath(String path) =>
    path.isNotEmpty && !path.startsWith('/') && !path.contains(String.fromCharCode(92)) &&
    !path.contains(':') && !path.contains('\\u0000') &&
    path.split('/').every((part) => part.isNotEmpty && part != '.' && part != '..');
