// Export as plug-in (#162): pick the format (CLAP or VST3) and desktop targets, set name, vendor and version, save the plug-in project (.zip) with the system picker, and read how to build and load it in a desktop DAW.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../model/cpp_workbench.dart';
import '../../model/plugin_export.dart';
import '../../platform/save_copy.dart';
import '../haptics.dart';
import '../theme.dart';
import 'tool_kit.dart';

/// Saves the package bytes as [name] (the system picker; a test passes a fake). True when saved.
typedef PackageSaver = Future<bool> Function(List<int> bytes, String name);

Future<bool> _saveWithPicker(List<int> bytes, String name) async {
  final dir = await Directory.systemTemp.createTemp('caw-plugin-');
  try {
    final f = File('${dir.path}${Platform.pathSeparator}$name');
    await f.writeAsBytes(bytes, flush: true);
    return await saveCopyOf(f, name: name, mimeType: 'application/zip', extension: 'zip');
  } finally {
    unawaited(dir.delete(recursive: true).then((_) {}, onError: (_) {}));
  }
}

class PluginExportScreen extends StatefulWidget {
  const PluginExportScreen({super.key, required this.workbench, this.save});
  final CppWorkbench workbench;
  final PackageSaver? save;

  @override
  State<PluginExportScreen> createState() => _PluginExportScreenState();
}

class _PluginExportScreenState extends State<PluginExportScreen> {
  late final _name = TextEditingController(text: widget.workbench.name);
  final _vendor = TextEditingController();
  final _version = TextEditingController(text: '1.0.0');
  final _url = TextEditingController();
  PluginFormat _format = PluginFormat.clap;
  final _targets = {PluginTarget.windowsX64, PluginTarget.linuxX64};
  bool _busy = false;
  String? _saved, _error;

  CppWorkbench get w => widget.workbench;

  PluginExportSettings get settings => PluginExportSettings(name: _name.text, vendor: _vendor.text,
    version: _version.text, url: _url.text, format: _format, targets: {..._targets});

  @override
  void dispose() {
    for (final c in [_name, _vendor, _version, _url]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _export() async {
    final c = w.component;
    final s = settings;
    if (c == null || s.problems.isNotEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final name = '${s.fileName}-plugin.zip';
    try {
      final ok = await (widget.save ?? _saveWithPicker)(zipStore(pluginPackageFiles(c, s)), name);
      if (!mounted) return;
      ok ? Haptics.threshold() : Haptics.tap();
      setState(() => _saved = ok ? name : null);
    } catch (e) {
      Haptics.error();
      if (mounted) setState(() => _error = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(String key, String label, TextEditingController c, {String? hint}) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: TextField(key: ValueKey(key), controller: c, enabled: !_busy,
      decoration: InputDecoration(labelText: label, hintText: hint, isDense: true),
      onChanged: (_) => setState(() => _saved = null)),
  );

  @override
  Widget build(BuildContext context) {
    const accent = Neon.violet;
    final s = settings;
    final problems = s.problems;
    final built = w.artifactPath != null;
    return ToolPage(
      title: 'Export as plug-in',
      subtitle: w.name,
      icon: Icons.extension_outlined,
      accent: accent,
      bottom: ToolAction(
        label: 'Save plug-in project (.zip)…',
        icon: Icons.file_upload_outlined,
        color: accent,
        progress: _busy ? -1 : null,
        busyLabel: 'Saving…',
        onPressed: problems.isEmpty && w.component != null ? _export : null,
      ),
      children: [
        const ToolHeading('Format'),
        ToolSegments<PluginFormat>(values: PluginFormat.values, value: _format, color: accent, keyPrefix: 'plugin-format',
          labels: (f) => f.available ? f.label : '${f.label} · soon',
          onChanged: (f) => setState(() => _format = f)),
        const ToolHeading('Targets'),
        for (final t in PluginTarget.values)
          ToolSwitch(
            key: ValueKey('plugin-target-${t.slug}'),
            label: t.label,
            detail: t.available ? null : 'Not built yet: a macOS plug-in is a bundle the SDK doesn\'t make.',
            value: _targets.contains(t),
            color: accent,
            onChanged: t.available ? (v) => setState(() => v ? _targets.add(t) : _targets.remove(t)) : null),
        const ToolHeading('Plug-in'),
        _field('plugin-name', 'Name (the file: ${s.fileName}${_format.extension})', _name),
        _field('plugin-vendor', 'Vendor', _vendor, hint: 'Your name or label'),
        _field('plugin-version', 'Version', _version),
        _field('plugin-url', 'Web address (optional)', _url),
        const SizedBox(height: 6),
        if (problems.isNotEmpty)
          ToolCard(title: 'Before you export', status: ToolStatus.warn, child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final p in problems) Text('• $p', style: const TextStyle(fontSize: 12, color: Neon.text))]))
        else if (!built)
          const ToolCard(title: 'Not built here yet', status: ToolStatus.info, child: Text(
            'Press ▶ Build first to catch errors here: the plug-in compiles the same code on the desktop.',
            style: TextStyle(fontSize: 12, color: Neon.dim))),
        if (_saved case final name?)
          ToolCard(key: const ValueKey('plugin-saved'), title: 'Saved $name', status: ToolStatus.pass, child: const Text(
            'Next: build it on GitHub, then load it in your DAW (below).', style: TextStyle(fontSize: 12, color: Neon.dim))),
        if (_error case final e?)
          ToolCard(title: 'Not saved', status: ToolStatus.fail, child: Text(e, style: const TextStyle(fontSize: 12, color: Neon.text))),
        const ToolHeading('How it becomes a plug-in'),
        ToolCard(title: '1 · Build on GitHub', color: accent, child: Text(
          'A phone can\'t compile desktop plug-ins, so the .zip is a small project: your code, a CMake file and a GitHub '
          'Actions workflow. Make a new GitHub repository, upload the unzipped folder (keep .github), and the "Build plug-in" '
          'workflow builds ${s.targets.where((t) => t.available).map((t) => t.label).join(' and ')}. Download '
          '${s.fileName}-<target> from the run\'s Artifacts.',
          style: const TextStyle(fontSize: 12, color: Neon.text))),
        ToolCard(title: '2 · Load it in a DAW', color: accent, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(_format == PluginFormat.vst3
              ? 'Unzip the artifact and copy the ${s.fileName}.vst3 folder (a VST3 bundle) into a VST3 folder, then rescan '
                'plug-ins in your DAW:'
              : 'Unzip the artifact and copy ${s.fileName}.clap into a CLAP folder, then rescan plug-ins in your DAW:',
            style: const TextStyle(fontSize: 12, color: Neon.text)),
          const SizedBox(height: 6),
          for (final (os, folder) in _format.folders) ToolStat(os, folder),
          const SizedBox(height: 6),
          const Text('It shows under the component\'s own name with the DAW\'s generic knobs (no custom window yet). The '
            'README in the .zip has the details and a desktop build.', style: TextStyle(fontSize: 11, color: Neon.dim)),
        ])),
      ],
    );
  }
}
