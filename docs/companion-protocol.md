---
title: Companion protocol
covers: [app/packages/caw_services/lib/companion/, app/lib/platform/companion_link.dart, app/lib/model/companion/, app/android/app/src/main/kotlin/com/kmandevr/caw/CompanionClient.kt, app/android/app/src/main/kotlin/com/kmandevr/caw/CompanionCallerCheck.kt]
summary: How C.A.W talks to its companion, the AutoStacc Hub (com.autostacc.hub), on Android (#239): a bound Messenger service, the ten message kinds and their bodies (update.open names the update channel), version 1, size limits, timeouts, the caller check both ways against a pinned signing-certificate digest (empty = none accepted) and the fallback when the companion is absent; the Hub itself not built.
updated: 2026-11-18
---

# Companion protocol

**[Fact]** (architect design, 2026-11-18). The companion holds the powers the main app gives up (least privilege); its plan is kept privately. The companion, the AutoStacc Hub (private `Kmandevr/AutoStacc-Hub`), has a first Android build that answers this protocol, not yet signed or published. The main app's side: with no companion installed, or no pinned Hub signer (the case until the Hub's key exists), everything takes today's in-app path.

## Transport
- **A bound `Service` with a `Messenger`,** like the main app's `:compiler` service. The main app binds with an explicit component, sends one `Message` per request with `replyTo` set, and gets one `Message` back.
- **Names** (owner, 2026-11-18): the companion is the AutoStacc Hub, package `com.autostacc.hub`, service `com.autostacc.hub.CompanionService`. They are kept in one place on each side (`CompanionCallerCheck.COMPANION_PACKAGE`, and the manifest's `<queries>`).
- **No custom permission in the main app** (security review, 2026-11-18). The design's signature permission `com.kmandevr.caw.permission.COMPANION` is not declared or asked for by C.A.W. A permission name belongs to whichever package declared it first, so a hostile app installed before C.A.W that declared it would make C.A.W's own install or update fail (see [Platform facts](#platform-facts)). The boundary is the per-message uid and signer check below, which needs no permission.
- **`<queries>`:** the main app names the companion package so it can see and bind it. The companion needs none to answer, because an app that binds a service is visible to that service's app.
- **No `sharedUserId`,** which would merge the two apps' permissions again.

## Message schema
- `what`: the kind, as a number (below). The reply carries the same `what`.
- The `Bundle` (`Message.data`):
  - `v` (int): the protocol version, **1**;
  - `id` (int): chosen by the sender, echoed in the reply; a reply with another `id` is dropped;
  - `body` (string): JSON, an object, **at most 64 KiB** (65,536 bytes of UTF-8). A bigger or unreadable body is refused before anything else is read;
  - in a reply only, `status` (string): `ok`, `unsupported`, `bad_request`, `refused`, `busy` (rate-limited) or `error`.
- **Never a URL or an HTTP method from the caller.** Every request the companion makes goes to a host and path it fixes itself, so a plug-in in the main app can't use it to send data anywhere.
- **Unknown kind or a higher `v`:** the reply is `unsupported`, with `v` set to the highest version the replier speaks. The main app treats a reply with a higher `v` the same way.

## Kinds

| `what` | Kind | Request body | Reply body |
|---|---|---|---|
| 1 | `hello` | `{}` | `{"app": version, "kinds": [names]}` |
| 2 | `update.status` | `{}` | `{"state": "idle"\|"checking"\|"downloading"\|"ready", "offer": label or null}` |
| 3 | `update.check` | `{}` | `{"releases": [...]}`, GitHub's release shape, notes trimmed to fit; the main app picks its channel's update itself |
| 4 | `update.open` | `{}` (Stable), `{"channel": "beta"\|"every"}`, or `{"channel": "every", "build": hex}` (below) | `{"started": bool, "release": label or null, "reason": text}`: whether the companion started that channel's update; nothing installs without the user's tap in Android's confirmation |
| 5 | `telemetry.report` | `{"report": object}` (the existing report schema) | a relay answer |
| 6 | `telemetry.get` | `{"receipt": hex}` | a relay answer |
| 7 | `telemetry.delete` | `{"items": [{"receipt", "deleteKey"}]}`, at most 100 | a relay answer |
| 8 | `feedback.post` | `{"feedback": object}` (the existing feedback schema) | a relay answer |
| 9 | `trust.query` | `{"component": id, "sha256": hex}` | `{"verdict": "bad"\|"unknown", "reason": text}` |
| 10 | `knownbad.version` | `{}` | `{"version": int}` |

- **`update.open`'s channel** (owner, 2026-11-18: "You should be able to switch"). The body names the channel the main app's settings hold: `stable`, `beta` or `every` (Every change); no `channel` means Stable. On Every change only, `build` (7 to 40 lower-case hex digits) is the running build's commit (`CAW_BUILD`), left out when the build doesn't know it. Any other key, another channel name or a `build` on another channel is `bad_request`.
  - **The companion chooses exactly as the main app does** (`releases.dart`'s `UpdateChannel.includes` and `updateFor`): Stable is the full releases and alphas, Beta adds every other test stage, Every change adds the rolling `latest-main` build (its version from the notes' `Version:` line). The newest tagged release above the installed version wins; on Every change the rolling build wins when its `Build:` line names another build than `build` and it is not older. Then the same checks as before: the asset pins, update.json against its published SHA-256, the APK against update.json and GitHub's digest, the package name, and the version code (higher for a tagged release; not lower for the rolling build, since every Main build of one version shares its code).
  - **Never a downgrade:** switching to a channel whose newest release is older than the installed build installs nothing. The reply is then `ok` with `started` false and `reason` `older` (or `up_to_date`, `unverifiable` when the release has no checkable package, `unknown_version`), and `release` the release concerned, so the main app can say why. `started` true names the release being downloaded (or already under way).
  - **Compatible within version 1:** the main app sends `{}` on Stable, which a companion from before channels still takes; such a companion answers a channel's name `bad_request`, which the main app reports as "too old to install from that channel". A reply without `started` (that older companion's `{}`) counts as started. `update.check` stays `{}`.
- **A relay answer** is `{"status": int, "body": text, "retryAfter": seconds, "sent": bool}`: the relay's own HTTP status and answer, so the main app's telemetry code reads it exactly as it reads the relay today (`RelayResponse`). `status` 0 means the companion couldn't reach the relay, and `sent` whether the request may have arrived. A `busy` reply reads as the relay's 429, so telemetry backs off.
- **Releases from the companion** are read by the same defensive parser as GitHub's answer (`parseGitHubReleases`): asset URLs must still be this repository's release downloads, so a companion that lied couldn't point a download elsewhere.
- **Known-bad wins** (once wired). A `bad` verdict blocks a component whatever the local trust choice says. `unknown` leaves the local choice in charge.
- **Not enforced yet.** The native component loader doesn't consult the known-bad list (`TrustSource` is built but not wired), so nothing is blocked by it today. Whether an absent companion or a timeout skips the list or blocks unlisted code is a decision for when it is wired; the code today skips it.

## Timeouts
- **Bind:** 3 s. A bind that fails or takes longer counts as `absent`.
- **Request:** 10 s, or **25 s** for the relay kinds (5 to 8), whose relay request may take 20 s itself.
- **Idle:** the main app unbinds 30 s after its last answer, so the companion isn't kept running.

## The caller check
Run on **every message**, on both sides: the companion checks each request, and the main app checks each reply. `Binder.getCallingUid` and `checkCallingPermission` don't work inside a `Messenger`'s `Handler`, because the message is handled after the binder call has returned; `Message.sendingUid` carries the sender instead.
1. `Message.sendingUid` maps (`PackageManager.getPackagesForUid`) to **exactly one** package, the expected one.
2. Only if the companion enforces the permission (open, above): that package holds it (`PackageManager.checkPermission`). The main app asks for none today.
3. Its signer is the **pinned** one (owner, 2026-11-18: each app has its own signing key and pins the other's). C.A.W pins the SHA-256 of the Hub's signing certificate; the Hub pins C.A.W's.
   - **No pin, no companion:** the digest comes from build configuration (below) and is empty until the Hub's key exists. Empty or malformed means every companion is refused, before any lookup, so today everything takes the in-app path.
   - **Every API level:** the package's current signers (`SigningInfo.apkContentsSigners` on API 28+, `PackageInfo.signatures` on 26 and 27), each hashed with SHA-256, must be **exactly one** certificate equal to the pin.
   - **API 28+, also:** `hasSigningCertificate(uid, pin, CERT_INPUT_SHA256)` must be true, the system's answer for the sending uid itself.
   - **API 26 and 27, also:** the package must still run as the sending uid after its signers are read (`getPackageUid`), since those versions have no uid-bound signer check.
   - **Several signers** are refused. **A rotated key** (APK signature scheme v3, API 28+) is refused once the Hub's current key is no longer the pinned one, even though `hasSigningCertificate` still accepts a past key in the lineage: a retired key may be the leaked one, so the pin follows the rotation (a new `HUB_CERT_SHA256`, then a C.A.W update).
   - **The pin:** the Gradle property `hubCertSha256` (64 hex digits, or 32 colon-separated pairs, either case), normalised to uppercase hex in `BuildConfig.HUB_CERT_SHA256`, default empty. A malformed non-empty value fails the build. CI (`app.yml`) passes the repository variable `HUB_CERT_SHA256` (a variable, not a secret: a certificate digest is public) to both Android builds with `--android-project-arg`.

The check runs **before anything of the message is read**: the `Bundle` is unparcelled only after the sender passes. A message that fails is dropped unread, without an answer. The main app also checks the companion's package and signer before it binds, again when the binding connects, and again before each send, so a companion replaced while bound is never sent to. The logic is kept pure, so the companion reuses it.

**The companion still doesn't trust the main app.** A pinned signer proves the caller is C.A.W, not that no plug-in has taken it over, so the companion also validates each body against its kind, rate-limits each kind, and asks the user in its own screen before anything installs, uploads or deletes.

## When the companion is absent
- The main app's link reports `absent` when the package isn't installed or visible, the bind fails or the bind times out. It asks once per run (`hello`), when something first needs the companion.
- **Absent or `unsupported`:** today's in-app path runs: the GitHub update check and installer, the relay over HTTPS, the local trust store.
- **A timeout** on a read (`update.status`, `update.check`, `trust.query`, `knownbad.version`) falls back the same way. A timeout on a request that sends or changes something (`update.open` and the relay kinds) is not retried in-app, because the companion may have sent it already: telemetry treats it as a try that may have arrived, as it treats a relay timeout today.
- Builds other than Android (Windows, Linux, tests) have no companion link and always take the in-app path.

## Platform facts
- **[Fact]** `protectionLevel="signature"`: granted only to an app signed with the same certificate as the app that declared it, without asking the user. The system doesn't let several packages declare the same permission name unless they are all signed with the same certificate (developer.android.com, `<permission>` element, read 2026-11-18). So both apps can declare it, as long as one key signs both.
- **[Fact]** A duplicate permission under another key: "If a package declares a permission, the system doesn't permit the user to install other packages with the same permission name, unless those packages are signed with the same certificate as the first package" (developer.android.com, `<permission>` element, read 2026-11-18). `PackageInstaller.STATUS_FAILURE_CONFLICT` (API 21) is the failure for a conflict "with another package already installed on the device. For example, an existing permission, incompatible certificates" (developer.android.com, `PackageInstaller`, read 2026-11-18). **[Assumption]** the install reports it as `INSTALL_FAILED_DUPLICATE_PERMISSION`, a name not on those public pages.
- **[Fact]** Package visibility: an app targeting Android 11 (API 30) or higher sees other apps filtered, and that includes starting or binding another app's service; `<queries>` widens it. Any app that starts or binds a service in your app is visible to you automatically (developer.android.com, package visibility and "visible automatically", read 2026-11-18).
- **[Fact]** `Message.sendingUid`: added in **API 21**, "the uid that sent the message", valid only for messages posted by a `Messenger`, otherwise -1 (developer.android.com, `android.os.Message`, read 2026-11-18). The main app's minimum is API 26.
- **[Fact]** `PackageManager.hasSigningCertificate(uid, cert, CERT_INPUT_SHA256)`, `CERT_INPUT_SHA256`, `GET_SIGNING_CERTIFICATES` and `SigningInfo` were added in API 28; `PackageManager.checkPermission(perm, package)` returns the permission's stored state (developer.android.com, `PackageManager`, read 2026-11-18).
- **[Assumption]** (not re-read this session) `hasSigningCertificate` also accepts a certificate from the package's past signing lineage after a key rotation, and `SigningInfo.apkContentsSigners` returns the current signer(s) only; hence the extra current-signer comparison above.
- **[Fact]** Google Play's `REQUEST_INSTALL_PACKAGES` policy permits it only where installing is the app's core purpose (web browsing or search, communication with attachments, file sharing or management, enterprise device management, backup and restore, device migration), and states its concern as "apps that self update using any method other than Google Play's update mechanism" (support.google.com, Play Console answer 12085295, read 2026-11-18). Hence the `play` flavour carries neither install permission.

## Where the code is
Built 2026-11-18 as groundwork; nothing reaches a companion until one is installed.
- **Dart, shared:** the kinds, version, limits, timeouts and body checks in `app/packages/caw_services/lib/companion/companion_protocol.dart`, which the companion can reuse.
- **Dart, the link:** `app/lib/platform/companion_link.dart`, chosen once in `main.dart`. `AndroidCompanionLink` talks to `caw/companion`; `NoCompanionLink` is every other platform and the tests. Each reply is checked again (version, id, status, body size and shape), and a channel that hangs counts as a timeout after the bind and request timeouts plus 2 s.
- **Dart, the adapters** (`app/lib/model/companion/`): `CompanionUpdateSource` (an `UpdateSource`), `CompanionUpdateInstaller` (an `UpdateInstaller` whose `handOff` takes an Android update before C.A.W downloads anything, so the APK is fetched once, by the Hub; sending the running `UpdateService`'s channel and build through `updateOpenBody` in `companion_protocol.dart`), `CompanionRelay` (at the `RelayClient` level, not `RelayHttp`, which takes any URL), and `TrustSource` with `LocalTrustSource` and `CompanionTrustSource`. Main wires the first three; **the trust source is not yet consulted by the native component loader**, which keeps reading `NativeTrustStore` until the known-bad list has a source.
- **Kotlin** (`app/android/app/src/main/kotlin/com/kmandevr/caw/`): `CompanionClient.kt` reads the pin from `BuildConfig.HUB_CERT_SHA256` (`app/android/app/build.gradle.kts`), checks the companion's package and signer before it binds, binds with the 3 s timeout (on Android 14+ with `BIND_ALLOW_ACTIVITY_STARTS`, so the Hub may open the system's install confirmation), sends each request with its own timeout, re-checks the companion when bound and before each send, checks each reply's sender before reading its Bundle, then its `what` and body size, drops a reply whose Bundle can't be read, and unbinds 30 s after the last answer; a companion process that dies mid-request times that request out. `CompanionCallerCheck.kt` holds the check and the pin's parser as pure Kotlin behind a small `PackageFacts` interface, so the companion reuses it. **No JVM unit tests yet:** the Android build has no test source set or test dependency, and CI builds the APK without running Gradle tests; the logic is kept pure so a test can be added with the companion. The manifest only names the companion in `<queries>`. In the `play` flavour, `caw/updates` answers `notImplemented` (`BuildConfig.SELF_UPDATES` false), so no PackageInstaller code is reachable.
