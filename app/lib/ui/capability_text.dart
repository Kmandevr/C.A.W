// Every word the app says about a native component's capabilities (the trust sheet, the Needs form): one entry per capability id, from the plug-in hosting plan's wording table (2026-11-18).
import 'package:flutter/material.dart';

/// How the app explains one capability to someone who doesn't know how software works.
class CapabilityText {
  const CapabilityText({
    required this.name,
    required this.can,
    required this.does,
    required this.risk,
    required this.why,
    required this.icon,
    required this.normal,
  });

  /// Its plain name (the Needs form's picker and rows).
  final String name;

  /// The trust sheet's row: what it lets the plug-in do, as a short sentence.
  final String can;

  /// The same in full.
  final String does;

  /// What could go wrong.
  final String risk;

  /// Why an honest plug-in might need it.
  final String why;
  final IconData icon;

  /// The scan weighs it as a notice, not a warning (files and threads): the sheet marks it "(normal)".
  final bool normal;

  /// The text for [id], or a plain fallback for an id this build of the app doesn't know.
  static CapabilityText of(String id) => all[id] ?? _unknown(id);

  static CapabilityText _unknown(String id) => CapabilityText(
        name: id,
        can: 'Something C.A.W doesn\'t recognise ($id)',
        does: 'Something this version of C.A.W can\'t describe',
        risk: 'C.A.W can\'t say what it could do',
        why: 'A newer kind of capability: update C.A.W to see what it means',
        icon: Icons.help_outline,
        normal: false,
      );

  static const all = <String, CapabilityText>{
    'internet': CapabilityText(
      name: 'Internet',
      can: 'Use the internet',
      does: 'Send and receive data over the internet',
      risk: 'It could send your projects, recordings or samples to someone else, or download more code.',
      why: 'Checking a licence, downloading presets or samples, updates, cloud sync.',
      icon: Icons.public,
      normal: false,
    ),
    'read_files': CapabilityText(
      name: 'Read files',
      can: 'Read files outside its own folder',
      does: 'Open files outside its own folder',
      risk: 'It could read your projects and samples.',
      why: 'Loading samples, impulse responses, wavetables or presets.',
      icon: Icons.folder_open,
      normal: true,
    ),
    'write_files': CapabilityText(
      name: 'Write files',
      can: 'Change or create files',
      does: 'Change or create files',
      risk: 'It could change or delete your work.',
      why: 'Saving recordings, renders or presets.',
      icon: Icons.save_outlined,
      normal: true,
    ),
    'start_programs': CapabilityText(
      name: 'Start programs',
      can: 'Start other programs',
      does: 'Run another program on the device',
      risk: 'It could run anything at all, with C.A.W\'s access.',
      why: 'Almost never for audio; sometimes a helper installer on desktop.',
      icon: Icons.terminal,
      normal: false,
    ),
    'load_code': CapabilityText(
      name: 'Load more code later',
      can: 'Load more code later',
      does: 'Load code the scan never saw',
      risk: 'It can hide what it really does.',
      why: 'Optional speed-ups for some processors, or hosting other plug-ins.',
      icon: Icons.extension_outlined,
      normal: false,
    ),
    'make_code': CapabilityText(
      name: 'Make code while running',
      can: 'Make new code while running',
      does: 'Turn data into runnable code',
      risk: 'It can hide what it really does.',
      why: 'A plug-in with its own scripting or fast-compile engine.',
      icon: Icons.memory,
      normal: false,
    ),
    'android_system': CapabilityText(
      name: 'Phone system features',
      can: 'Use Android\'s own features',
      does: 'Use Android\'s own features through C.A.W',
      risk: 'It could use the microphone or other permissions you gave C.A.W.',
      why: 'Rare: device sensors.',
      icon: Icons.phone_android,
      normal: false,
    ),
    'background_threads': CapabilityText(
      name: 'Background threads',
      can: 'Start background threads',
      does: 'Do work alongside the audio',
      risk: 'It could use a lot of battery or processor.',
      why: 'Loading large samples, heavy offline processing.',
      icon: Icons.call_split,
      normal: true,
    ),
    'encryption': CapabilityText(
      name: 'Encryption',
      can: 'Scramble or unscramble data',
      does: 'Scramble or unscramble data',
      risk: 'A sign of ransomware, which locks your files.',
      why: 'Licence checks, protected sample libraries.',
      icon: Icons.lock_outline,
      normal: false,
    ),
    'input_spying': CapabilityText(
      name: 'Keyboard, clipboard, screen',
      can: 'See what you type, copy or show',
      does: 'See what you type, copy or show',
      risk: 'Spying.',
      why: 'Almost never for audio.',
      icon: Icons.visibility_outlined,
      normal: false,
    ),
    'packed': CapabilityText(
      name: 'Scrambled or packed code',
      can: 'Hide its own contents',
      does: 'Hide its own contents',
      risk: 'The scan can\'t see what it does.',
      why: 'Copy protection in commercial plug-ins.',
      icon: Icons.inventory_2_outlined,
      normal: false,
    ),
  };

  // The sheet's fixed lines.
  static const sheetHeading = 'This plug-in can:';
  static const normalTag = '(normal)';
  static const whyFold = 'Why might an honest plug-in need this?';
  static const authorSays = 'Its author says:';
  static const graceLine = 'Built before 1.0.7: rebuild it with its needs declared';
  static const isolatedLater = 'Running it apart (Isolated) comes later';
  static const nothingFound = 'Nothing beyond sound, maths and memory.';

  /// Why a C.A.W component can't be added: the capabilities it uses without declaring them.
  static String blockedLine(List<String> names) => names.isEmpty
      ? 'Blocked: C.A.W can\'t check this file safely.'
      : 'Blocked: it uses ${_join(names)} without declaring ${names.length == 1 ? 'it' : 'them'}.';

  static String _join(List<String> names) =>
      names.length < 2 ? names.join() : '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';

  // The Needs form's fixed lines.
  static const needsTitle = 'Needs';
  static const needsEmpty = 'Nothing beyond sound, maths and memory. Add what else it uses, with your reason: '
      'people see it before they trust the plug-in.';
  static const reasonHint = 'Why it needs this, in plain words';
  static const sitesHint = 'sites: host names, separated by spaces';
}
