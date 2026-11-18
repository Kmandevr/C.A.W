// The build's telemetry settings from --dart-define (beta readiness plan E1, G1): the channel, the relay's URL and
// the non-secret app key. No URL (the placeholder until the owner gives the final one) means nothing is ever sent.

/// The build channel CI sets (`--dart-define=CAW_CHANNEL=beta|release`). Telemetry is on by default in beta builds
/// and off in release builds (E1).
enum BuildChannel { beta, release }

class TelemetryConfig {
  const TelemetryConfig({required this.channel, this.relay, this.appKey = '', this.build});

  final BuildChannel channel;

  /// The relay's base URL (H3), or null: sending is then off entirely.
  final Uri? relay;

  /// `X-CAW-App-Key` (H3): a per-build value that only blocks casual spam. Not a secret.
  final String appKey;

  /// The short commit CI built from (`CAW_BUILD`: 7 to 12 lowercase hex), or null (a local build, or a malformed
  /// value).
  final String? build;

  /// What this build was given. A build without `CAW_CHANNEL` (a local run, `flutter test`) is a release build, so
  /// telemetry starts off.
  static TelemetryConfig fromEnvironment() => parse(
        channel: const String.fromEnvironment('CAW_CHANNEL'),
        relayUrl: const String.fromEnvironment('CAW_RELAY_URL'),
        appKey: const String.fromEnvironment('CAW_APP_KEY'),
        build: const String.fromEnvironment('CAW_BUILD'),
      );

  /// Reads the defines' text. Only an absolute `https` URL with a host and no user info, query or fragment counts;
  /// anything else (empty, the placeholder, plain http) leaves [relay] null.
  static TelemetryConfig parse(
      {required String channel, required String relayUrl, required String appKey, String build = ''}) {
    final uri = Uri.tryParse(relayUrl.trim());
    final ok = uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment;
    return TelemetryConfig(
      channel: channel.trim().toLowerCase() == 'beta' ? BuildChannel.beta : BuildChannel.release,
      relay: ok ? uri : null,
      // Each channel's key (owner, 2026-11-12: caw-release-1 beside caw-beta-1) unless the build names one.
      appKey: appKey.trim().isNotEmpty ? appKey.trim() : (channel.trim().toLowerCase() == 'beta' ? 'caw-beta-1' : 'caw-release-1'),
      build: RegExp(r'^[0-9a-f]{7,12}$').hasMatch(build.trim()) ? build.trim() : null,
    );
  }

  /// Whether this build can reach a relay at all (a URL and an app key).
  bool get canSend => relay != null && appKey.isNotEmpty;

  /// [path] (`/v1/report`...) under the relay's base URL.
  Uri endpoint(String path) {
    final base = relay!;
    final prefix = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    return base.replace(path: '$prefix$path');
  }
}

/// The public data repository (H1, as corrected 2026-11-12): reports, weekly summaries and feedback issues.
const telemetryRepoUrl = 'https://github.com/Kmandevr/C.A.W-Telemetry';
const privacyPolicyUrl = '$telemetryRepoUrl/blob/main/PRIVACY.md';
const termsUrl = '$telemetryRepoUrl/blob/main/TERMS.md';
String reportRepoUrl(String receipt) => '$telemetryRepoUrl/blob/main/data/${receipt.substring(0, 2)}/$receipt.json';
