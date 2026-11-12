// The app's version as users see it (pubspec.yaml's version; a test keeps them equal). C.A.W is in open alpha.
const String appVersion = '0.9.0-beta.1';

/// The page where testers report problems (public; no token or account data is sent from the app).
const String issuesUrl = 'https://github.com/Kmandevr/C.A.W/issues/new';

/// The short commit this build was made from (CI's `--dart-define=CAW_BUILD=<sha>`); empty in a local build. The
/// update check compares it with an "Every change" build's.
const String appBuild = String.fromEnvironment('CAW_BUILD');
