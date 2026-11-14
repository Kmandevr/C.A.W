// The app's version as users see it (pubspec.yaml's version; a test keeps them equal). C.A.W is in open alpha.
const String appVersion = '1.0.4-alpha.1';

/// The build number (pubspec.yaml's `+N`; a test keeps them equal). Projects record it with [appVersion] as they save.
const int appBuild = 7;

/// The page where testers report problems (public; no token or account data is sent from the app).
const String issuesUrl = 'https://github.com/Kmandevr/C.A.W/issues/new';

/// The short commit this build was made from (CI's `--dart-define=CAW_BUILD=<sha>`, the first 12 characters); empty
/// in a local build. The update check compares it with an "Every change" build's. Not [appBuild], pubspec's `+N`.
const String appCommit = String.fromEnvironment('CAW_BUILD');
