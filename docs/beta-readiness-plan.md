---
title: Beta readiness plan
summary: The owner's 2026-11-12 direction for engine speed A1-A7, a 240 fps UI, the stress test, the startup screen, telemetry and feedback, and the C.A.W-Telemetry contract (section H, with its 2026-11-12 updates); telemetry and feedback (E, F) are built, the rest planned.
updated: 2026-11-12
---

# Beta readiness plan

**[Proposal] Owner direction, 2026-11-12, verbatim.** The owner's other session wrote it with the owner and sent it here; the owner confirmed it in this session. Tracked in issue #187. Section H is shared with the caw-telemetry repo: change it only through the owner. What is built is recorded in the notes that own each area, not here.

## The prompt

Owner direction, 2026-11-12. Record each decision below in `docs/decisions.md` before building it.

### Who does what

Two Claude sessions work at once, on disjoint repositories.

- **You (this prompt): everything inside `Kmandevr/C.A.W`.** The engine, the app, the C API, CI in this repo, and this repo's docs. That covers sections A–G below, including the app's side of telemetry, feedback and "My data".
- **The other session: everything outside it.** The public data repo `Kmandevr/caw-telemetry` (Cloudflare Worker code, its deploy workflow, the stored data and the weekly summaries), the Cloudflare setup (Worker, D1, Cron, free plan), the GitHub tokens' scopes, and the privacy policy and terms texts (published in caw-telemetry as `PRIVACY.md` and `TERMS.md`).
- **The contract between you is section H.** Build the app to it exactly. If you need a change to it, don't work around it: write it in your PR description and ask the owner, who will pass it on.
- Don't create or edit files in caw-telemetry, and don't touch Cloudflare.

### Rules

- Work on the branch the session names. One PR per section (or per item where a section is large).
- audio-reviewer after engine changes, code-reviewer before each PR, security-reviewer for anything that sends data off the device, architect before structural changes.
- Every speed claim needs a before/after measurement (Bench workflow, callgrind, or `app/test/perf_*_test.dart` BENCH lines), recorded in `docs/engine-performance.md` or `docs/performance.md`. Every measured gain is kept. No audible change without asking the owner.
- **Before any change to how the UI looks, ask the owner first:** propose a layout or 2–3 options and wait for an answer. This applies to sections B (settings), C, D, E and F.
- Never invent facts about APIs, platforms, limits or licences: check a primary source, date it, or label it an assumption.
- No secrets in the app or this repo. The app holds only the relay's URL and a non-secret app key.

---

### A. Engine speed, beyond phases 1–5

Keep doing phases 2–5 as planned. Add these, in this order:

**A1. Audio-thread scheduling.** This is the biggest open gap. The owner's S22+ showed 49% CPU on three tracks; the server shows 3.8%. `docs/performance.md` ("The CPU meter") suspects a little core or a low clock.
- Diagnostics: report the callback's core (`sched_getcpu` or the platform's equivalent) and that core's clock through the C API, so the app and the stress test can show them.
- Use each platform's own scheduling tools, set up outside the callback, loaded so older systems still run, with a silent fallback (check each against primary docs, dated):
  - Android: the ADPF performance hint (`APerformanceHint`, Android 13+): target duration = the callback period; report actual durations. Check which calls are safe on the real-time thread and how Oboe does it.
  - Windows: MMCSS "Pro Audio" for the audio thread (if miniaudio doesn't already do it; check); opt it out of power throttling/EcoQoS; keep it off E-cores on hybrid Intel CPUs; WASAPI exclusive where the user allows it.
  - Linux: real-time priority (SCHED_FIFO, via rtkit when unprivileged), and what PipeWire, Pulse and ALSA each allow.
  - macOS/iOS: audio workgroups are future work only (the app doesn't ship there).
- Ask the owner to run a release APK before/after and report the CPU meter.

**A2. Flagship inside one track.** The parallel mixer can't help it: 64 voices are still about 91% of budget after phase 1.
- Run several voices' ladder filters side by side, as each voice's two sides already are (that gave 1.7×, `docs/performance.md` "Flagship synth").
- Vectorise across unison copies.
- Fold this into phase 4 if it fits, and say which.

**A3. The first callback after Play** is 2–8× the mean (`docs/engine-performance.md`). Find the first-time work, move it before Play or spread it over a few callbacks, and report the worst-case column before/after.

**A4. Issue #133:** bound the per-callback loops (`applyCommands`, `planChunk`, `updateSolo`) to active slots; callgrind before/after.

**A5. CPU features:** check what each build enables (SSE2 only? AVX2? NEON on arm64). Propose runtime dispatch for the hottest kernels where a wider instruction set measurably helps. Add a Windows target to `bench.yml` if it isn't there. The same tolerance tests run on every target.

**A6. Worker pool and parallel mixer (phase 5):** size from each device's real cores and core types on every platform (big/little and P/E-cores), not just Android.

**A7. Proposal only:** a shared reverb bus instead of a reverb inside each Flagship is a product choice. Write it up in docs and ask the owner.

### B. A super-smooth UI with an adaptive frame rate, up to 240 fps

Goal: everything that moves (playhead, meters, scopes, scrolling, zoom, drags, device motion) runs at the display's full refresh rate, up to 240 Hz, on every platform. When nothing moves, the app still asks for zero frames (the battery rule stays).

**B1. Research first (facts, sources, dates):**
- How Flutter at our version asks for the highest refresh rate on Android (API 30+ preferred frame rate/display mode; any plugin must be permissively licensed and recorded in decisions).
- The S22+ panel's real modes (believed adaptive up to 120 Hz; confirm).
- How Flutter Windows and Linux pace frames to the monitor, including several monitors (follow the one the window is on).
- Any known Impeller frame-pacing limits.

**B2. Adaptive rate:** the display's maximum while anything animates or the user is touching; the lowest rate when idle. The Lightweight and Minimal profiles may cap it (propose the caps; ask the owner).

**B3. Decouple motion from the 30 Hz poll** (today `Poller` ticks every 33 ms and `MotionClock` steps every 33 ms, so faster frames would repeat the same picture):
- Playhead: work out its position each frame from the last engine position plus elapsed time × tempo, correcting softly on each poll. Never call FFI per frame.
- Meters: fall per frame on wall-clock time.
- Device motion: per frame while visible.
- Scopes: keep 30 Hz data, with no full redraw on frames that have no new data.

**B4. Make every frame cheap** (a 240 Hz frame is 4.2 ms):
1. `track_cards_screen.dart:543`: the playhead shares a repaint layer with clips and waveforms. Put the playhead in a `LiveIsland` and the waveform in a `RepaintBoundary`.
2. `arrange/audio_waveform.dart:143`: one `drawLine` per pixel across the whole clip, including off screen. Batch it (`drawRawPoints` or one `Path`), draw only the visible span, and cache a `ui.Picture` per clip and zoom level.
3. `AudioClipPainter` repaints on the global `WaveformCache`, so any loaded level redraws every waveform. Notify per file path.
4. `app_state.dart:757`: `_syncNow` always notifies, rebuilding the shell and every `IndexedStack` workspace. Notify only on a real change.
5. Device editors:
   - about 25 painters return `shouldRepaint => true`;
   - a knob step rebuilds 450–1,100 widgets;
   - display polls run on their own `Timer.periodic(33 ms)` (`device_display.dart:82`).
   Drive them from the shared tick, compare in `shouldRepaint`, and narrow listeners per control.
6. `ScopeView` (`widgets.dart:65`): add a `LiveIsland`, and drop the blur under Lightweight.
7. `track_lanes.dart:518`: split a cached static automation curve from a small live painter.
8. `app_state.dart:509`: one FFI call per track every 33 ms. Make it one batched C API call into a reused buffer (bump the C API, update the app).
9. Pinch zoom paints every clip each frame (about 4,200 render objects). Scale the painted lanes during the gesture and lay out once at the end.

**B5. Measure:** extend the perf benches with frame build and raster cost while playing, scrolling, zooming and with a device editor open, and assert them so they can't grow back. Then ask the owner to check a release build on the S22+ and on Windows, and record the results.

### C. Built-in stress test, on every platform

Goal: a one-tap DAW benchmark, like a game or PC benchmark, that does two jobs:
- tells a user how well their device runs C.A.W, with no hand-built "explode the phone" project;
- tells us exactly what takes the time and where the limits are.

It runs on Android, Windows and Linux, with the same scenarios, scores and JSON everywhere.

**C1. Scenarios:** reuse caw_bench's scenarios and builders (`engine/bench/caw_bench.cpp`), so the app's numbers match CI's.
- Normal: first_loop, three_tracks, song8, song8_extras.
- Heavy: song16, drums_kit, flagship_heavy16.
- Extreme: flagship_heavy, song32_heavy.
- Idle: tail_floor.
- Ramps: add tracks, then Flagship voices, then effects on one track, until a callback misses its budget. Report the last count that held ("holds 23 tracks / 41 voices").
- Sustained: one heavy scenario for a few minutes (load over time, thermal state).

**C2. Two ways to measure, both reported:**
- DSP: timed rendering on a worker thread (repeatable).
- Live: through the real audio device, output muted, counting dropouts and real callback times, plus the A1 core and clock and whether the platform's scheduling hint was on.

**C3. Results, plain words first:**
- A headline per tier (comfortable / tight / over budget) and the limits the ramps found.
- Per scenario: mean, p99 and worst callback, load %, dropouts.
- What's holding it back: a per-component breakdown from caw_bench's profile mode (401), with the top costs ranked.
- UI frame times while the arranger plays and scrolls (ties to B).
- Device info (see H2's `device` fields; "unknown" where a platform doesn't expose something).
- Export as JSON plus a text summary through the share/save picker. With telemetry on, the result also goes in the next report (H2 `stress`).

**C4. Safety:**
- Output is muted for the whole run.
- A ramp stops at the first over-budget step.
- The run stops on severe thermal status or battery saver, and says why.
- Time limits: a quick run (about 1 min) and a full run (about 5 min). Cancel at any time.
- It uses its own Engine and project, never touches the user's project, and restores playback state afterwards.
- It stays within memory budgets.

**C5. Engine and C API:** a "run scenario N for S seconds" call with progress and cancel, through the native worker pool, sharing code with caw_bench (architect review first: the shared builders move). Bump the C API version.

**C6. UI:** ask the owner how the test and results look and where they live, before building.

### D. Startup screen and animation

Goal: a polished startup like REAPER's (a splash showing what's loading), but entirely C.A.W's own: the crow logo, original art and motion, not REAPER's look.
- **D1.** No blank flash: the native splash (Android 12+ SplashScreen API plus its older fallback; the Windows and Linux window background) matches the first Flutter frame.
- **D2.** It shows the version (v1.0.0-beta.x) and the real loading steps ("Starting audio engine", "Loading instruments", "Opening project"). It disappears the moment loading is done and never slows startup: measure with `perf_startup_bench_test` and stay within about 50 ms of today.
- **D3.** Minimal / motion off gets a still logo. The animation runs at the display's real rate.
- **D4.** Ask the owner first: 2–3 options (logo motion, layout, colours, duration), then build the one picked.

### E. Telemetry: the app's side

Purpose: device specs and how well C.A.W runs on them, so the owner can make design decisions. Nothing about the user is collected. All collected data is published openly in `Kmandevr/caw-telemetry`, for full transparency.

**E1. Default by build channel** (a CI build flag, not a user setting):
- Beta builds: on by default.
- Release builds: off by default, with a clear option to turn it on.
- On the first release launch after a beta build, telemetry switches off and the user is asked once whether to keep it on.

**E2. First run:** a Privacy Policy and Terms screen (scrollable summary, with links to the full texts at caw-telemetry's `PRIVACY.md` and `TERMS.md`, also in Settings → About). It says plainly that this beta sends anonymous performance and device data, that all of it is published publicly, what is and isn't sent, and that it can be turned off in Settings → Privacy. Continue = accepted. Bundle a copy of both texts in the app for offline viewing; the other session writes them, so ask the owner for the final versions before release.

**E3. Settings → Privacy:**
- The toggle: off stops sending at once and wipes the queue.
- "Show exactly what's sent": the real queued JSON.
- "My data" (E5).

**E4. Collecting and sending:**
- Build reports to H2's schema exactly, rounding as H2 says.
- Queue locally (capped at 1 MB), send at most once a day over HTTPS with `dart:io` `HttpClient` (no new package unless needed; licence-check any).
- Honour 429 and 503 `Retry-After` by keeping the report queued.
- Give up quietly offline, and never block the UI or touch the audio thread.

**E5. "My data":**
- Every report this device sent: date, status (queued / sent / published), the exact JSON, "Open in repo" (H1 path) and "Copy receipt ID".
- "Check on server" (H3 GET).
- "Delete my data" (H3 delete), with the privacy policy's note that public git history and others' copies can't be fully recalled.
- "Export my receipts", since a reinstall loses the local list by design.
- Receipts and delete keys are made on the device (H2) and stored only there.

**E6. Never sent** (H2's allow-list enforces it on the server too): MIDI devices or notes, project names or content, audio, code, file paths, user component names, account info, contact details, location, or any install or user ID.

### F. Feedback: the app's side

- **F1. The form** (Settings and a "Send feedback" item in the ⋯ menu):
  - Type: Bug / Idea / Something's confusing / Praise.
  - Text, up to 5,000 characters.
  - Optional "Attach device info", "Attach last stress-test result" and "Attach recent error log", each shown in full before sending.
  - An optional contact email.
  - It says plainly: "Feedback is posted publicly on GitHub; don't include personal details. Your email (if given) is never published."
  - Offline, it queues and sends later; then "Sent, thanks".
  - Ask the owner how it looks before building.
- **F2.** It sends to H4. Feedback works even with telemetry off.

### G. Builds, platforms and docs

- **G1.** CI: a beta/release channel flag (E1), and the relay URL and app key from build config (`--dart-define`). The other session will give the owner the final URL; until then use a placeholder that disables sending.
- **G2.** Everything above works on Android, Windows and Linux, the way each platform works. Write a per-platform section in `docs/performance.md` saying what's done, measured and assumed.
- **G3.** Docs: update `docs/app.md`, `docs/performance.md`, `docs/engine-performance.md` and `docs/decisions.md`. Update CLAUDE.md's description: it currently says there is no cloud integration; it should say the beta sends anonymous telemetry and feedback through a relay, and that audio stays local.

### H. The contract with caw-telemetry (shared; don't change it alone)

**H1. Where the data appears** (public, at `github.com/Kmandevr/caw-telemetry`):
- Each report: `data/<first 2 hex chars of receipt>/<receipt>.json`, committed once a day.
- Weekly summaries: `summaries/<ISO week>.md`.
- Feedback: public Issues on `Kmandevr/C.A.W`, labelled `beta-feedback` plus `fb-bug`, `fb-idea`, `fb-confusing` or `fb-praise`.

**H2. Report schema v1** (`POST /v1/report`, JSON, at most 8 KB; the server drops unknown fields and rejects wrong types):
```
{
  "schema": 1,
  "receipt": "<32 lowercase hex: 128 random bits, made on the device>",
  "deleteHash": "<64 lowercase hex: SHA-256 of a 32-byte random delete key kept on the device>",
  "channel": "beta" | "release",
  "day": "YYYY-MM-DD",                     // the UTC day the report covers; no time of day
  "app": { "version": "1.0.0-beta.1", "engineVersion": "...", "capiVersion": 23 },
  "device": {
    "platform": "android" | "windows" | "linux",
    "osVersion": "14",                     // major version only
    "cpu": "Cortex-X2/A710/A510" | "<CPU model string>",
    "cores": { "big": 4, "little": 4, "other": 0 },
    "maxClockMHz": [3000, 2500, 1800],     // per core type, rounded to 100 MHz
    "ramGB": 8,                            // rounded to a whole GB
    "gpu": "<renderer string>",
    "refreshHz": 120,
    "audio": { "backend": "aaudio", "exclusive": true, "lowLatency": true,
               "bufferFrames": 192, "sampleRate": 48000 },
    "profile": "full" | "balanced" | "lightweight" | "minimal",
    "eco": false
  },
  "perf": {
    "cpuLoadHistogram": [ /* 10 buckets of 10% each: share of playing time */ ],
    "dropouts": 0,
    "worstCallbackPct": 0,                 // of budget, rounded to 5%
    "frames": { "p50ms": 0, "p99ms": 0, "slowPct": 0 },
    "startupMs": 0,                        // rounded to 50 ms
    "thermalEvents": 0, "batterySaverMinutes": 0,
    "schedHint": "on" | "off" | "unsupported",
    "callbackCoreType": "big" | "little" | "other" | "unknown"
  },
  "usage": {
    "minutesOpen": 0, "minutesPlaying": 0, // rounded to 5 min
    "screens": { "<screen id>": <minutes, rounded to 5> },
    "builtins": { "<built-in instrument/effect id>": <uses> },
    "projectSize": { "tracks": "1-4" | "5-8" | "9-16" | "17-32" | "33+",
                     "clips":  "1-10" | "11-50" | "51-200" | "201+" }
  },
  "stress": null | { "version": 1, "tiers": { "normal": "comfortable" | "tight" | "over",
                     "heavy": "...", "extreme": "..." },
                     "limits": { "tracks": 0, "voices": 0, "effects": 0 },
                     "scenarios": { "<id>": { "meanPct": 0, "p99Pct": 0, "worstPct": 0, "dropouts": 0 } },
                     "topCosts": [ { "component": "<built-in id>", "pct": 0 } ] },
  "errors": [ { "type": "<exception type>", "where": "<file:line in C.A.W code>", "count": 0 } ]  // at most 20
}
```
Only built-in ids go in `screens`, `builtins` and `topCosts`. The server replaces anything else with `"other"`.

**H3. Endpoints** (base URL from build config; every request sends the header `X-CAW-App-Key: <per-build value>`, which is not a secret and only blocks casual spam):

| Request | Body | Response |
|---|---|---|
| `POST /v1/report` | H2 | `202` accepted; `400` bad schema; `413` too large; `429`/`503` + `Retry-After` (keep it queued) |
| `GET /v1/report/<receipt>` | none | `200` the published JSON; `202 {"status":"queued"}` not yet committed; `404` unknown or deleted |
| `POST /v1/delete` | `{"items":[{"receipt":"...","deleteKey":"<64 hex>"}]}` (up to 100) | `202 {"deleted":<n>}`, removed in the next daily commit |

**H4. Feedback:**

| Request | Body | Response |
|---|---|---|
| `POST /v1/feedback` | `{"schema":1,"kind":"bug"\|"idea"\|"confusing"\|"praise","text":"≤5000 chars","appVersion":"...","platform":"...","attachments":{"device":{H2 device}?,"stress":{H2 stress}?,"errors":[H2 errors]?},"contact":"<email>"?}` (at most 32 KB) | `201 {"issue":"<url>"}`; `202 {"status":"queued"}` if GitHub is slow; `400`/`413`/`429`/`503` as for reports |

The email is never published; the server keeps it privately for the owner.

**H5. Limits the app must respect:** one report per device per UTC day, at most 5 feedback posts a day, and back off on any 429 or 503.

---

**Done when:** A1–A6 are merged with numbers and A7 is written up and asked; B–G are merged after the owner approves each look; all tests are green; docs are updated; and the owner has a before/after table of results. Ask the owner for a release APK check on the S22+ and a Windows check at the end.

## Updates to section H (2026-11-12, owner)

**[Fact]** Agreed with the owner on 2026-11-12 and passed on by the owner's other session, which runs the relay. The verbatim prompt above is unchanged; where it differs, these win. The other copy of the contract is `PLAN.md` in Kmandevr/C.A.W-Telemetry.

- **Repository:** the data repository is **Kmandevr/C.A.W-Telemetry** (not `caw-telemetry`). Reports appear at `data/<first 2 hex of receipt>/<receipt>.json` on its `main` branch; the Privacy Policy and Terms are its `PRIVACY.md` and `TERMS.md`.
- **Relay and key:** `https://caw-telemetry.kmandevr.workers.dev`, app key `caw-beta-1` (not a secret), the `--dart-define` defaults CI passes. Release builds still send only when the user turns telemetry on. `GET /` is a health check that needs no key.
- **Feedback** becomes Issues in Kmandevr/C.A.W-Telemetry, not C.A.W; the app shows the issue URL the relay returns.
- **`errors[].where`** is a relative C.A.W source location: it starts with `lib/`, `src/`, `engine/`, `app/`, `platform/`, `include/` or `package:caw/` and ends with `:<line>`. Absolute paths get a 400, so the app makes frames relative on the device and drops any it can't.
- **Rules the relay enforces:** `deleteHash` is SHA-256 of the delete key's 32 raw bytes, lowercase hex; `cpuLoadHistogram` is exactly 10 numbers from 0 to 1; `osVersion` is digits only; `audio.backend` is `a-z`, `0-9` and `_` only; a receipt is good for one POST (a second gets a 400), so each report gets a fresh one and a 400 on a resend counts as sent.
- **Publishing and limits:** publishing is hourly (a lookup moves from 202 to 200 within about an hour). Per sender per UTC day: 10 reports, 5 feedback posts, 200 lookups. The app sends one daily report a day; stress-test results take the other slots ([decisions](decisions.md), 2026-11-12).
- **`app.build` (owner, 2026-11-12):** reports may carry `app.build` and feedback a top-level `build`: optional, 7–12 lowercase hex characters, the short commit the build came from. `app.version`, `engineVersion` and `capiVersion` stay required, and `app.version` is the real version from pubspec.
- **PLAN.md's stricter rules are H's too (owner, 2026-11-12):** `maxClockMHz` at most 4 values; `frames.slowPct`, the stress scenario percentages and `topCosts[].pct` whole numbers; `topCosts` at most 10.
- **Reports:** one daily report plus one per Benchmark (stress test) run, at most 10 a day, each with an optional top-level `"kind": "daily" | "stress"` (default daily; a stress report carries `stress`).
- **Unknowns are `null` or left out, never 0:** every measurement (core counts, clocks, RAM, refresh rate, buffer size, sample rate, `exclusive`/`lowLatency`, every `perf` number, `cpuLoadHistogram`), `osVersion`, `cpu` and `gpu`.
- **Delete:** `/v1/delete` accepts any receipt and key; unknown or already-deleted receipts aren't counted.
- **Keys:** `caw-release-1` for release-channel builds beside `caw-beta-1`.
- **Device and peripherals (all optional):** `platform` also `ios` and `macos`; `arch` (arm64, arm, x64, x86, riscv64, other); `osName`; `osVersion` as major or major.minor[.build]; `manufacturer` and `model`, maker-defined only; `formFactor` (phone, tablet, laptop, desktop, tv, other, unknown); `screen` `{widthPx, heightPx, dpi?, displays?}`; `audio.output` (builtin, usb, bluetooth, wired, hdmi, displayport, network, other, unknown); `peripherals`, up to 16 `{kind, connection, model?, vendorId?, productId?, channels?, inUse?}`. Never a name the user can set, a serial number, a hardware address, a port path or a full OS build string.
- **What the app actually sends of these (security review, 2026-11-12):** no `peripherals[].model` and no `inUse`; at most 8 peripherals, sorted by kind; `screen` without `dpi`, pixels to the nearest 10. `model` only from the platform's maker data.
- **Dashboard:** `https://caw-telemetry.kmandevr.workers.dev/dashboard` shows everything collected; the data is kept 400 days on the relay (PRIVACY.md).
- **Differences between PLAN.md (fetched 2026-11-12) and section H, for the owner:**
  - PLAN.md's `screens` accept any id of `a-z 0-9 _ . -`; the app sends only its three section ids.
  - PLAN.md now lists the same ten Benchmark scenario ids as the app; any other, such as the bench's `tail`, arrives as "other". The relay counts Benchmark results from daily reports too, so the fallback onto the next daily report stays.
  - PRIVACY.md calls it the **Stress test**; the app's UI says **Benchmark**.

