// The feedback form (beta readiness plan F; owner's look 2026-11-12): a bottom sheet with type chips, the text, three
// attachment toggles that open to show exactly what is attached, an optional email, the public-posting notice and
// Send. It posts to the relay (H4) whether telemetry is on or off, and waits in a queue when offline.
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../model/problem_log.dart';
import '../../model/telemetry/report_schema.dart';
import '../../model/telemetry/telemetry.dart';
import '../glass.dart';
import '../haptics.dart';
import '../motion.dart';
import '../theme.dart';
import 'privacy_pages.dart';

/// F1's notice, word for word apart from naming the repository (H, as updated 2026-11-12).
const feedbackNotice = 'Feedback is posted publicly on GitHub, as an issue in Kmandevr/C.A.W-Telemetry; don\'t include '
    'personal details. Your email (if given) is never published.';

Future<void> showFeedbackSheet(BuildContext context, Telemetry t) => showGlassSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(c).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.9),
          child: FeedbackForm(telemetry: t),
        ),
      ),
    );

class FeedbackForm extends StatefulWidget {
  const FeedbackForm({super.key, required this.telemetry, this.errors});
  final Telemetry telemetry;

  /// The recent error log (tests pass their own); ProblemLog's by default.
  final List<Map<String, Object?>> Function()? errors;

  @override
  State<FeedbackForm> createState() => _FeedbackFormState();
}

class _FeedbackFormState extends State<FeedbackForm> {
  final _text = TextEditingController();
  final _email = TextEditingController();
  FeedbackKind _kind = FeedbackKind.bug;
  bool _device = false, _stress = false, _errors = false;
  Map<String, Object?>? _deviceInfo;
  bool _sending = false;
  String? _problem;

  Telemetry get t => widget.telemetry;
  List<Map<String, Object?>> get _errorLog =>
      [for (final e in (t.allowList.errors((widget.errors ?? ProblemLog.recentErrors)()) as List?) ?? const []) (e as Map).cast<String, Object?>()];

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    t.deviceInfo().then((d) {
      if (mounted) setState(() => _deviceInfo = d);
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _email.dispose();
    super.dispose();
  }

  Map<String, Object?> get _body => t.feedbackBody(
        kind: _kind,
        text: _text.text,
        device: _device ? _deviceInfo : null,
        stress: _stress ? t.lastStress : null,
        errors: _errors ? _errorLog : null,
        contact: _email.text,
      );

  bool get _emailOk {
    final e = _email.text.trim();
    return e.isEmpty || RegExp(r'^[^\s@]{1,64}@[^\s@]{1,190}\.[^\s@]{2,}$').hasMatch(e);
  }

  Future<void> _send() async {
    if (_sending) return;
    if (!_emailOk) {
      setState(() => _problem = 'That email doesn\'t look right; leave it empty or fix it.');
      return;
    }
    setState(() {
      _sending = true;
      _problem = null;
    });
    final r = await t.submitFeedback(_body);
    if (!mounted) return;
    setState(() => _sending = false);
    final messenger = ScaffoldMessenger.maybeOf(context);
    switch (r.outcome) {
      case FeedbackOutcome.sent:
        Haptics.tap();
        Navigator.of(context).pop();
        messenger?.showSnackBar(SnackBar(
            content: Text(r.issueUrl == null ? 'Sent, thanks' : 'Sent, thanks. It is at ${r.issueUrl}'),
            duration: const Duration(seconds: 6)));
      case FeedbackOutcome.queued:
        Navigator.of(context).pop();
        messenger?.showSnackBar(const SnackBar(content: Text('Saved. It sends when you\'re back online.')));
      case FeedbackOutcome.dailyLimit:
        setState(() => _problem = 'Five feedback posts a day is the limit. This one can go tomorrow.');
      case FeedbackOutcome.invalid:
        setState(() => _problem = 'The relay won\'t take this one: write some text, and keep it under 5,000 characters.');
      case FeedbackOutcome.unavailable:
        setState(() => _problem = 'This build has no feedback relay set. Report a problem (About and beta) still works.');
    }
  }

  Widget _attachment(String key, String title, bool on, ValueChanged<bool>? set, Object? what, String empty) {
    final level = Motion.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SwitchListTile(
        key: ValueKey('feedback-attach-$key'),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 4),
        title: Text(title),
        subtitle: set == null ? Text(empty, style: const TextStyle(color: Neon.dim, fontSize: 12)) : null,
        value: on,
        onChanged: set == null
            ? null
            : (v) {
                Haptics.tap();
                set(v);
              },
      ),
      AnimatedSize(
        duration: Motion.move(Motion.panel, level),
        alignment: Alignment.topCenter,
        child: on
            ? jsonBlock(what == null ? '(reading…)' : const JsonEncoder.withIndent('  ').convert(what),
                key: ValueKey('feedback-shows-$key'))
            : const SizedBox(width: double.infinity),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final left = t.feedbackLeftToday;
    final canSend = !_sending && _text.text.trim().isNotEmpty && left > 0;
    return SingleChildScrollView(
      key: const ValueKey('feedback-form'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        const Text('Send feedback', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final k in FeedbackKind.values)
            ChoiceChip(
              key: ValueKey('feedback-kind-${k.name}'),
              label: Text(k.label),
              selected: _kind == k,
              onSelected: (_) {
                Haptics.tap();
                setState(() => _kind = k);
              },
            ),
        ]),
        const SizedBox(height: 10),
        TextField(
          key: const ValueKey('feedback-text'),
          controller: _text,
          minLines: 4,
          maxLines: 8,
          maxLength: maxFeedbackChars,
          decoration: const InputDecoration(hintText: 'What happened, or what would you like?', border: OutlineInputBorder()),
        ),
        _attachment('device', 'Attach device info', _device, (v) => setState(() => _device = v), _deviceInfo, ''),
        _attachment('stress', 'Attach last stress-test result', _stress,
            t.lastStress == null ? null : (v) => setState(() => _stress = v), t.lastStress, 'No stress-test result yet'),
        _attachment('errors', 'Attach recent error log', _errors, (v) => setState(() => _errors = v), _errorLog, ''),
        const SizedBox(height: 6),
        TextField(
          key: const ValueKey('feedback-email'),
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          maxLength: 254,
          decoration: const InputDecoration(
              labelText: 'Email (optional, never published)', border: OutlineInputBorder(), counterText: ''),
        ),
        const SizedBox(height: 10),
        const Text(feedbackNotice, style: TextStyle(color: Neon.dim, fontSize: 12, height: 1.35)),
        AnimatedSwitcher(
          duration: Motion.fade(Motion.standard, Motion.of(context)),
          child: _problem == null
              ? const SizedBox(key: ValueKey('no-problem'), width: double.infinity)
              : Padding(
                  key: ValueKey(_problem),
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_problem!, style: const TextStyle(color: Neon.pink, fontSize: 13)),
                ),
        ),
        if (left < Telemetry.feedbackPerDay)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('$left of ${Telemetry.feedbackPerDay} left today',
                style: const TextStyle(color: Neon.dim, fontSize: 12)),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const ValueKey('feedback-send'),
          onPressed: canSend ? _send : null,
          icon: AnimatedSwitcher(
            duration: Motion.fade(Motion.small, Motion.of(context)),
            child: _sending
                ? const SizedBox(key: ValueKey('sending'), width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send, key: ValueKey('send'), size: 18),
          ),
          label: const Text('Send'),
        ),
      ]),
    );
  }
}
