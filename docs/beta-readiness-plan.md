---
title: Beta readiness plan
summary: The owner's 2026-11-12 beta direction as it concerns built work and contracts: who does what, the rules, the stress test (C), telemetry and feedback (E, F), builds (G) and the C.A.W-Telemetry contract (section H, with its 2026-11-12 updates); sections A, B and D are kept privately.
updated: 2026-11-18
---

# Beta readiness plan

**[Proposal] Owner direction, 2026-11-12, verbatim.** The owner's other session wrote it with the owner and sent it here; the owner confirmed it in this session. Tracked in issue #187. Section H is shared with the caw-telemetry repo: change it only through the owner. What is built is recorded in the notes that own each area, not here. Sections A (engine speed), B (frame rate) and D (startup screen) and the prompt's closing line are kept privately; what of them is built is in [engine performance](engine-performance.md), [performance](performance.md) and [app](app.md).

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
