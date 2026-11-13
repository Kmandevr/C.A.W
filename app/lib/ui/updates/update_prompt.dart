// Runs the update check after the app has opened and asks about an update found: a small prompt with Update, Not
// now and Don't ask again, never over the startup screen, never while another startup prompt (the first-run page,
// the keep-telemetry question) is open, and never while playing, recording or rendering. Also
// takes automatic update steps when the app is idle or goes to the background.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../model/app_state.dart';
import '../../model/updates/update_service.dart';
import '../adaptive_sheet.dart';
import '../app_prompts.dart';
import '../motion.dart';
import '../theme.dart';
import 'update_flow.dart';

class UpdatePromptHost extends StatefulWidget {
  const UpdatePromptHost({
    super.key,
    required this.state,
    required this.service,
    required this.busy,
    required this.child,
    this.settle = const Duration(seconds: 2),
  });
  final AppState state;
  final UpdateService service;

  /// Playing, recording, or a render or export running: no prompt and no install then.
  final bool Function() busy;
  final Widget child;

  /// How long after the app is shown before checking (the startup screen has faded by then).
  final Duration settle;

  @override
  State<UpdatePromptHost> createState() => _UpdatePromptHostState();
}

class _UpdatePromptHostState extends State<UpdatePromptHost> with WidgetsBindingObserver {
  Timer? _settle;
  bool _started = false, _showing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.addListener(_changed);
    AppPrompts.changes.addListener(_promptsChanged);
    _changed();
  }

  // The startup screen gone or another prompt closed: try again after this frame, so a first-run page that opens in
  // the same change goes first.
  void _promptsChanged() {
    if (!AppPrompts.free || !_started || (_settle?.isActive ?? true)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePrompt());
  }

  @override
  void dispose() {
    _settle?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.state.removeListener(_changed);
    AppPrompts.changes.removeListener(_promptsChanged);
    if (_showing) AppPrompts.showing.value = false; // closed with the app (its dialog never answered)
    super.dispose();
  }

  void _changed() {
    if (!widget.state.ready) return;
    if (!_started) {
      _started = true;
      _settle = Timer(widget.settle, () => unawaited(_afterStart()));
      return;
    }
    if (_settle?.isActive ?? true) return;
    _maybePrompt(); // e.g. playback just stopped
  }

  Future<void> _afterStart() async {
    if (!mounted) return;
    final note = widget.service.takeDownloadedNote();
    if (note != null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(note), duration: const Duration(seconds: 10)));
    }
    await widget.service.checkIfDue();
    if (!mounted) return;
    _maybePrompt();
    await widget.service.autoStep(busy: widget.busy(), saveFirst: widget.state.flush);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (!_started || (_settle?.isActive ?? true)) return;
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) {
      // In the background with nothing running: where Android allows a silent update, it installs now.
      unawaited(widget.service.autoStep(busy: widget.busy(), background: true, saveFirst: widget.state.flush));
    } else if (s == AppLifecycleState.resumed) {
      unawaited(widget.service.checkIfDue().then((_) {
        if (mounted) _maybePrompt();
      }));
    }
  }

  void _maybePrompt() {
    if (_showing || !mounted || !widget.state.ready || !AppPrompts.free || widget.busy() ||
        !widget.service.shouldPrompt) {
      return;
    }
    final offer = widget.service.offer!;
    _showing = true;
    widget.service.prompted();
    unawaited(AppPrompts.run(() => showDialogOrSheet<String>(
      context: context,
      builder: (c) => AlertDialog(
        key: const ValueKey('update-prompt'),
        title: Text('Update available: ${offer.label}'),
        content: ListenableBuilder(
          listenable: widget.service,
          builder: (c, _) {
            final size = widget.service.sizeLine(offer);
            return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('You have v${widget.service.current}. Updating is up to you; nothing changes until you choose '
                  'Update.', style: const TextStyle(color: Neon.dim)),
              // The download size, smaller once a small update is known to fit ("Update 4.7 MB instead of 54.5 MB").
              AnimatedSize(
                duration: Motion.move(Motion.standard, Motion.of(c)),
                alignment: Alignment.topLeft,
                child: AnimatedSwitcher(
                  duration: Motion.fade(Motion.standard, Motion.of(c)),
                  child: size == null
                      ? const SizedBox(key: ValueKey('update-size-none'), width: double.infinity)
                      : Padding(
                          key: ValueKey('update-size:$size'),
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(size, style: const TextStyle(color: Neon.dim, fontSize: 12)),
                        ),
                ),
              ),
            ]);
          },
        ),
        // One Wrap, not three actions: a dialog's button bar measures its height as if the buttons fit in one row (a
        // button's narrowest is its longest word), so on a narrow phone or with large text the sheet came out too
        // short and squeezed the text away. A Wrap measures the rows it really makes.
        actions: [
          Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 4, children: [
            TextButton(key: const ValueKey('update-never'), onPressed: () => Navigator.pop(c, 'never'),
                child: const Text('Don\'t ask again')),
            TextButton(key: const ValueKey('update-later'), onPressed: () => Navigator.pop(c, 'later'),
                child: const Text('Not now')),
            FilledButton(key: const ValueKey('update-now'), onPressed: () => Navigator.pop(c, 'update'),
                child: const Text('Update')),
          ]),
        ],
      ),
    )).then((choice) {
      _showing = false;
      if (!mounted) return;
      switch (choice) {
        case 'update':
          unawaited(startUpdate(context, widget.service, offer, state: widget.state));
        case 'never':
          widget.service.dontAskAgain();
        default:
          widget.service.notNow();
      }
    }));
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
