---
title: Plug-in hosting plan
summary: Least privilege and the companion app (1.0.7) first, the optional isolation design, the silent staged plan for hosting CLAP/VST3 plug-ins (#212, live in 1.1.0), the verified facts and the owner's open questions; planned, not built.
updated: 2026-11-18
---

# Plug-in hosting plan

**[Proposal]** None of this is built. It is an architect review from 2026-11-17, laid down silently in steps (the owner's groundwork rule, [decisions](decisions.md)). Hosting goes live in 1.1.0, and least privilege and the companion app in 1.0.7 (owner, 2026-11-18). The owner reviews the isolation design before step 1.

**Owner direction (2026-11-18):** least privilege comes first and Isolated is an option the user can choose, not the default ([decisions](decisions.md)). The design for that is [Least privilege and the companion app](#least-privilege-and-the-companion-app).

## Where things stand today **[Fact]**, checked 2026-11-17
- Isolated is refused: `engine/src/module_registry.cpp` and `app/lib/model/native_trust.dart`. The C API already has `CAW_NATIVE_TRUST_ISOLATED`.
- Trusted plug-ins run in the app's own process: the plug-in benchmark and the serial lanes (`ComponentChain::foreign`).
- The only separate process is Android's `:compiler` service. It is a plain `android:process` (not `isolatedProcess`), with one build per bind over a `Messenger`.
- `engine/plugin/{clap,vst3}` holds the export wrappers and test hosts, not a general host.

## Isolated mode: the design
- **A host process.** A small `caw_plugin_host` runs per plug-in instance by default. It links only the hosting code.
  - **Windows:** a child process in a Job Object (it is killed with the app, and its memory is capped), with a shared memory section. A Job Object limits resources, not access: to be a sandbox the host also needs an AppContainer or a low-integrity token, with no network capability.
  - **Android:** a `PluginHostService` in its own declared process, ideally `isolatedProcess`. It gets the plug-in `.so` and the shared memory as file descriptors, and it cannot read app storage itself.
  - **Linux CI:** the same POSIX code.
- **Audio exchange that never waits.** Each instance has one shared region holding input and output block slots, plus SPSC rings for events and parameter changes.
  - At each block, the audio callback writes the input and wakes the host without blocking. It then reads the previous block's output if it is ready; otherwise it plays silence or the last block and counts a miss.
  - So Isolated adds a fixed latency of **one block**, reported as the plug-in's latency so the delay compensation covers it.
  - Two missed blocks in a row bypass the node: effects pass the dry sound, instruments go silent.
- **Control:** state, activation, scanning and (later) GUIs go over a separate channel, never on the audio thread. That channel is Binder on Android and a named pipe on Windows.
- **Crashes:** a watchdog sees a stalled heartbeat or a dead process. It restarts the host with backoff and the last saved state, and gives up after 3 crashes, marking the node failed. The app itself never goes down.
- **Trusted** stays in-process. **Blocked** stays refused before the library is opened.
- **Cost on a phone:**
  - one more process, about 10–30 MB each **[Assumption]**;
  - one block of latency;
  - two context switches per block;
  - the host thread may not get real-time priority outside the audio callback **[Assumption]**.
  
  The Benchmark measures all of this.

## Least privilege and the companion app

**[Proposal]** (owner direction, 2026-11-18). Android grants permissions per app, not per process or library, so a Trusted plug-in has everything the main app has. Taking powers away from the main app costs nothing on the audio path.

**Already in place [Fact]**, `app/android/app/src/main/AndroidManifest.xml` and `LinkedFolders.kt`, checked 2026-11-18:
- the microphone and Bluetooth are asked for only when the user turns them on;
- location is declared only up to Android 11 (`maxSdkVersion="30"`), and Bluetooth scanning is `neverForLocation`;
- linked sample folders are granted read-only.

**The companion app** (owner, 2026-11-18: release **1.0.7** is given over to it and to this security work, after the 1.0.6 usability release; the later batches moved up by one). It has its own package, so its own permissions.
- **What it holds:** `REQUEST_INSTALL_PACKAGES`, `UPDATE_PACKAGES_WITHOUT_USER_ACTION` and `INTERNET`, for the self-updater, the update check, telemetry and feedback. Plug-in trust is kept here too (below).
- **What it grows into:** AutoStacc's secondary hub; the two work as one. It holds every download, the user's whole library and the account, and stores the user's data, sounds and one-shots in the cloud for C.A.W to use. C.A.W reads them through the companion, so the main app still needs no network, and account tokens never live in the process that loads plug-ins.
- **Private (owner):** its code (a closed-source, private repository, unlike C.A.W's Apache-2.0, [vision](vision.md)) and its data. Nothing in it is shared or exposed.
- **Admin view (owner):** the telemetry and feedback that C.A.W-Telemetry collects are shown in an admin view inside the companion app, for the owner and the people they trust, to see how the app is used and to find vulnerabilities. When it is built, the C.A.W-Telemetry repository's PLAN.md, privacy policy and access rules change in the same piece of work.
- **Talking to it** ([companion protocol](companion-protocol.md)): the main app sends only fixed, structured messages (an update check, a telemetry report in the existing schema, a request for a library file), never arbitrary payloads, so a plug-in can't use it to send data out. It accepts only callers signed with C.A.W's own key, through a custom permission with `protectionLevel="signature"`. It never uses `sharedUserId`, which would merge the two apps' permissions again. The main app needs a `<queries>` entry to find it.
- **Play builds:** the Play companion carries no install permissions, since Play does the updating.
- **Windows:** the same split, as a helper process. It only helps if the main process is itself restricted (MSIX with an AppContainer). **[Assumption]** that the Flutter app and local CMake builds work in an AppContainer; to test.

**Review, notice and takedown (owner, 2026-11-18),** stated in a clear disclaimer that users accept:
- **Sold** on AutoStacc (plug-ins, effects, samples, anything): AutoStacc may review it at any time, with no notice or update to the creator.
- **Stored, not sold:** private. If it is reviewed, the owner of it is told it is being reviewed, and that this doesn't necessarily mean there is a problem.
- **Taken down,** sold or stored: always with a notice and a way to appeal.
- **Hosting malicious plug-ins** gets the account banned. An appeal goes through an entirely manual process.
- **Already downloaded and then found malicious:** the plug-in is disabled at once on every device that has it, and the user can see why.
- **The automatic malware check is not a review:** it runs on each upload, sends no file or data to the owner or the team, and only refuses malicious content. Where it applies, it tells the uploader the upload was refused and why.

**[Assumption]** a lawyer checks this before launch against the laws where AutoStacc operates. For example, the EU's Digital Services Act requires a statement of reasons when hosted content is removed; the notice above is meant to be that.

### The rest of the design

**[Proposal]** The owner accepted these on 2026-11-18 ("all of the suggestions are good, use some reasoning"). The choices inside each are Claude's, to confirm.
1. **Trust lives in the companion.** The companion keeps the trust choices, the scan results and the known-bad and known-good lists. A plug-in in the main app can't edit them. The main app asks once per load, so playback pays nothing. Without the companion, choices are kept locally as today.
2. **The companion doesn't trust the main app.** A signature only proves the caller is C.A.W, not that no plug-in has taken it over. So every message is validated against its schema, each kind is rate-limited, and nothing that installs, uploads or deletes happens without the user's tap in the companion itself.
3. **Disabling a malicious plug-in.** The companion fetches the known-bad list. A listed plug-in is refused at its next load, and one already playing is unloaded at the next block boundary (its track goes silent, never a crash). The user sees which plug-in it was, why, and what it could have reached: its declared capabilities and the main app's permissions.
4. **Internet for plug-ins goes through the companion.** A plug-in that declares `network` also names its sites. The companion makes those requests for it, to those sites only, and the user sees them. The main app keeps no `INTERNET` of its own.
5. **No admin credentials on devices.** The admin view signs in to the relay with a personal account and a second sign-in step. It never holds a GitHub token. There are two roles: viewing, and taking content down or banning. The owner adds and removes people, and every admin read and action is logged.
6. **C.A.W without the companion** works fully offline (no updates, telemetry, feedback, cloud library or hub). It suggests the companion once, where one of those is asked for. Two Play listings, and Google's developer registration (global from 2027), cover both apps.
7. **Moving existing users.** First, one update installs the companion through the existing updater. Once it is installed, a later version drops the install permissions. The old path is kept until the companion is confirmed present, so nobody is stranded without updates.
8. **Signing keys.** Authors register a key through their AutoStacc account. A lost or stolen key is revoked from the account, and what it signed returns to "unsigned" or, if malicious, onto the known-bad list. Builds made on the device are signed with a non-exportable device key, which marks them as the user's own.
9. **Scanner rules are versioned.** Each verdict records the rules version. Rules update through the companion, and a plug-in is rescanned before its next load when the version changes. False positives are reported through feedback, and the owner (or a trusted person) triages them.
10. **Shared projects.** Opening a project that needs a plug-in shows each one's state: available, needs a trust choice, missing (with a way to get it from AutoStacc) or blocked. The project still opens, and those tracks stay silent until resolved.
11. **Windows** gets its own pass: an AppContainer test, code-signing the app (SmartScreen), and update checks that verify a signature, since Windows has no equivalent of Android's same-key rule.
12. **Keeping and deleting data.** Hosted files and the cloud library are kept until the user deletes them or the account closes. Deleting is the user's own action, as telemetry's delete keys already are. Retention periods go in the privacy policy.

**Free limits in the main app:**
- third-party code loads only while a project that uses it is open, and unloads when it closes;
- a setting gives the microphone back when C.A.W closes (`revokeSelfPermissionsOnKill`, Android 13+);
- the microphone foreground service runs only while recording.

**Flagging and a handshake** (the owner wants both; choices open):
- **Antivirus, Windows:** before loading a library, the app passes its bytes to the installed antivirus through AMSI (`AmsiScanBuffer`) and refuses on a detection. It keeps the Mark-of-the-Web on files that came from a download, so SmartScreen and Defender treat them as downloaded.
- **Android** has no antivirus API for an app's own files. The equivalent is a hash check against a list the hub keeps: known-bad hashes are refused everywhere, and a user's report through feedback can add one.
- **Signed plug-ins, the "handshake":** a check the plug-in runs itself proves nothing, because bad code can run it too. What works is a signature from a key the plug-in's author doesn't control, checked once at load:
  - authors register a key with the hub, and the hub can revoke it;
  - the app's own builder signs what it builds from source the user saw, with a non-exportable device key;
  - unsigned code needs an explicit Trusted choice with a plain warning.

### The pre-load scan

**[Proposal]** (owner direction, 2026-11-18: a silent antivirus that looks at each plug-in before it is ever launched).
- **When:** once per exact file hash, when a plug-in is added or built, and again before load if the file changed. **Before `dlopen`/`LoadLibrary`**, because loading already runs the library's static constructors (`.init_array`, and TLS callbacks on Windows). The verdict is cached by hash, so it costs nothing on the audio path, at play or at project open.
- **Where:** in the engine (one C++ parser for the app and a `caw` CLI command, tested against fixtures in CI), off the audio thread, on a worker. The scanner parses untrusted files, so it runs with size and count limits and is fuzzed in CI.
- **Two policies:**
  - **C.A.W components declare what they need (owner, 2026-11-18).** By default a component gets only the host API, maths, memory and the C++ runtime. Anything more is a **capability** it declares in its descriptor, each with the author's reason in plain words (for example `network`: "downloads the factory presets"). The scan checks the binary against the declaration: **anything used but not declared is blocked outright**, with no Trusted override. Declared capabilities are shown to the user with their reasons, and the hub reviews the reasons for what it lists. **[Proposal]** where it can, the host offers a capability as its own service (a file the user picks, a request to a named site through the companion), so even declared use is visible and limited.
  - **CLAP/VST3 binaries** can't declare anything in C.A.W's format and legitimately use much more (GUIs, files, often a licence check over the network), so for them the same findings warn rather than block.
- **What it looks for** (cheap, static):
  - **Imports:** networking (`socket`, `connect`, `getaddrinfo`, WinHTTP, WinINet, Winsock); starting programs (`execve`, `fork`, `system`, `popen`, `CreateProcess`, `ShellExecute`); loading more code at run time (`dlopen`, `dlsym`, `LoadLibrary`, `GetProcAddress`); making memory executable (`mprotect`, `VirtualProtect`, `VirtualAlloc` with execute); debugging other processes (`ptrace`); keyboard hooks, the registry, the clipboard; encryption APIs (a ransomware hint); and on Android `JNI_OnLoad` or other JNI use, which reaches Android's Java APIs.
  - **Direct system calls** in code sections, which bypass the import table: `svc #0` on Arm64 (fixed-width instructions, so a reliable scan) and `syscall` on x86-64 (a byte scan, so a hint only).
  - **Code that runs on load:** TLS callbacks, and an unusual amount of constructor code.
  - **Packing:** sections that are both writable and executable, high-entropy code or large high-entropy data, packer section names.
  - **Strings:** URLs and IP addresses, shell paths (`/system/bin/sh`, `cmd.exe`, `powershell`), `.onion`, browser-profile or wallet paths.
  - **Reputation:** the hub's known-bad and known-good hashes, and the signature state.
  - **Source builds:** the source too, for networking and process headers, inline assembly and platform headers.
- **Verdicts:** clean (silent), notice, warning (the user sees why before choosing Trusted), blocked. For C.A.W components, undeclared use blocks; for CLAP/VST3, the owner chooses which findings block.
- **Warnings people can follow (owner, 2026-11-18):** each finding is explained for someone who doesn't know how software works: what it lets the plug-in do, what could go wrong, and why an honest plug-in might need it. The draft wording is below; how it looks is the owner's to decide.

| Capability | What it lets the plug-in do | The risk | Why an honest plug-in might need it |
| --- | --- | --- | --- |
| Internet | Send and receive data over the internet | It could send your projects, recordings or samples to someone else, or download more code | Checking a licence, downloading presets or samples, updates, cloud sync |
| Reading files | Open files outside its own folder | It could read your projects and samples | Loading samples, impulse responses, wavetables or presets |
| Writing files | Change or create files | It could change or delete your work | Saving recordings, renders or presets |
| Starting programs | Run another program on the device | It could run anything at all, with C.A.W's access | Almost never for audio; sometimes a helper installer on desktop |
| Loading more code later | Load code the scan never saw | It can hide what it really does | Optional speed-ups for some processors, or hosting other plug-ins |
| Making new code while running | Turn data into runnable code | Same: hides what it does | A plug-in with its own scripting or fast-compile engine |
| Phone system features (Android) | Use Android's own features through C.A.W | It could use the microphone or other permissions you gave C.A.W | Rare: device sensors |
| Background threads | Do work alongside the audio | It could use a lot of battery or processor | Loading large samples, heavy offline processing |
| Encryption | Scramble or unscramble data | A sign of ransomware, which locks your files | Licence checks, protected sample libraries |
| Keyboard, clipboard, screen | See what you type, copy or show | Spying | Almost never for audio |
| Scrambled or packed code | Hide its own contents | The scan can't see what it does | Copy protection in commercial plug-ins |

- **Limits:** it stops lazy and obvious malware. Code built to evade it (looking functions up by walking memory, encrypted payloads, harmless-looking imports) gets past, as it does with any static scanner. A false positive must never silently break a legitimate plug-in.
- **Dependencies:** none needed; a small ELF/PE reader of C.A.W's own is enough. **[Assumption]** LIEF (Apache-2.0) for parsing and YARA (BSD-3-Clause) for signature rules are permissive candidates; check the licences before adopting either.

**[Assumption]** the API names and behaviour above (AMSI, `revokeSelfPermissionsOnKill`, `sharedUserId`) come from platform documentation not re-read this session; check each before building on it. Signature permissions, `<queries>` and `Message.sendingUid` were checked on 2026-11-18 ([companion protocol](companion-protocol.md#platform-facts)).

## Silent steps
1. **1.0.7:** the shared-memory ring (a new isolation folder in the engine sources), with tests across two processes on Linux and Windows CI. Nothing calls it.
2. **1.0.8:** the host executable and an `IsolatedProcessor` proxy. These load a C.A.W component first (not CLAP), and are compiled only with the `CAW_ISOLATED_HOST` CMake option (OFF).
   - Tests: render parity against in-process at one block of offset; `kill -9` mid-render, which bypasses and restarts; a stalled host never makes the callback wait.
   - CI checks the binary size, so it is shown to cost nothing while off.
3. **1.0.9:** the Android service, a client and a JNI bridge. It is never bound unless a hidden dev flag is on. An emulator test (API 34+) loads a fixture `.so` from a file descriptor in an isolated process; **this settles the riskiest Android assumption, so run it early**.
4. **1.0.10:** the scan, run inside the host process only, with timeouts and a cache. It is reachable only from the CLI (`caw scan`), with tests for hanging and crashing plug-ins.
5. **1.0.11:** the CLAP and VST3 adapters, mapping their audio, sidechain and note ports to the graph's typed ports, ready for the 1.1.0 routing (#233). The UI comes in 1.1.0, after the owner reviews its look.

## Facts and checks
- **[Fact]** CLAP is MIT, v1.2.9 (verified 2026-11-10). VST3's `pluginterfaces` is MIT from 3.8.0 (verified 2026-11-11). Steinberg's VST logo and trademark guidelines are still to be checked if "VST3" appears in the UI.
- **[Fact] Google Play,** verified 2026-11-17 (support.google.com, Play policy answer 9888379): "an app may not download executable code (such as dex, JAR, .so files) from a source other than Google Play". The only exception is code run in a VM or interpreter.
  - This **conflicts with loading downloaded third-party plug-in `.so` files in a Play build** (#222).
  - It also conflicts with the in-app self-update in a Play build.
  - Plug-ins the user compiles on the device are not downloaded. That this makes them allowed is an interpretation **[Assumption]**.
- **[Fact]** With targetSdk 29+, an app can't `execve` files in its data (verified 2026-11-09).
- **[Assumption]** These are unverified:
  - `dlopen` of an app-data `.so` is still allowed at targetSdk 34+;
  - an isolated process can map a `.so` passed by file descriptor;
  - an isolated process can use futex or eventfd on shared memory.
  
  Step 3's emulator test checks them.
- **iOS:** built-ins only. Isolated and Trusted compile out.

## Open questions for the owner
1. **Settled** (owner, 2026-11-17): two Android builds. The GitHub build has everything; the Play build follows Play's rules. Open: whether an interpreted plug-in format (a bytecode or WebAssembly interpreter in the engine) could bring third-party plug-ins to the Play build at a CPU cost, and whether iOS can do the same.
2. One host process per plug-in instance (more memory, a crash takes down one instance) or one per plug-in?
3. **Settled** (owner, 2026-11-17): one block is fine, plus an optional no-delay mode that runs in the callback with a timeout.
4. What users see on a crash: bypass, mute, or a notice?
5. Are plug-in GUIs (VST3 editors, CLAP GUI embedding) in scope for 1.1.0?
6. Which trust a plug-in gets the first time it is seen (already open in [vision](vision.md)).
7. Which flagging and signing parts to build ([least privilege](#least-privilege-and-the-companion-app)), whether unsigned code may load at all, which findings block for CLAP/VST3, the capability list, and how a warning looks.
8. **Settled** (owner, 2026-11-18): the companion app and this security work are release 1.0.7, after the 1.0.6 usability release and before hosting goes live in 1.1.0; the later batches moved up by one.
9. Which trust a never-seen plug-in gets (6): **[Proposal]** Blocked until the user chooses.
