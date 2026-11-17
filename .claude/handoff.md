# Handoff

Commit: 845026f (session branch; Main has v1.0.4-alpha.1, published)
Branch: ccr-56285e11-0xrj3h. Main is protected: PRs only; merge yourself when CI is green. Publish with app.yml's workflow_dispatch (installables + release) on Main. Each release needs a CHANGELOG.md entry, copied to app/assets/CHANGELOG.md.

## Goal
1.0.5-alpha.1 (#215): MIDI storage #216, freeze/bounce/comping/consolidate #209, clip fixes #226/#228, automation #230, sample library #229, latency #236, the audio hint #234. Then 1.0.6 (FX consolidation and device UI, #227/#231) and 1.0.7. Silent 1.1.0 groundwork rides along (docs/routing-plan.md, docs/plugin-hosting-plan.md).

## Done and verified
- `batch-105` (.claude/worktrees/batch-105) merges midi-store, clip-fixes, freeze, automation and sample-library. C API 33, project format v5. Checks: ctest 11/11; flutter test 2229 with CAW_LIB; docs --strict.
- Comping, Consolidate, a take per loop pass and "Record just works" are committed on batch-105 (343ece0). Their final CAW_LIB run is in progress.
- `audio-threads` (4fff774), not yet merged:
  - ADPF hint retries and hint_state;
  - the device warm-up kept out of the CPU meter;
  - Benchmark foreground redo, ramp cap and live parts label;
  - USAGE_GAME;
  - a buffer tuner, off by default.
  
  It also claims C API 33, so renumber to 34 when merging it after batch-105. ctest 11/11; flutter 2122.

## Open
- **Still running (agents):** `latency` (#236) and `platform-audio` (#237, built on audio-threads). Both were stopped by the rate limit and resumed at 19:39 UTC.
- **Merge order into batch-105:** audio-threads (API to 34), then platform-audio, then latency. Then version bump 1.0.5-alpha.1 (pubspec, version.dart, docs/app.md, architecture.md, 4 goldens), CHANGELOG, PR, merge, release.
- **Owner questions:**
  - buffer tuner as a Settings row or hidden;
  - the AutoStacc pack's 4th device;
  - MIDI manufacturer ID (7D or register);
  - look confirmations for automation and the sample browser;
  - routing plan questions 3, 6 and 7;
  - hosting plan questions 2, 4, 5 and 6.
- **Device checks on the S22+:**
  - hint_state;
  - worstCallbackPct;
  - USAGE_GAME on Bluetooth;
  - linked folders from cloud providers.
- **Known flake:** stress_profile_parts_add_up_and_name_the_feature, under load.

## Next
1. Collect the three agents' reports and merge as above.
2. Release 1.0.5-alpha.1.
3. Start 1.0.6, with routing step S1 designed into #227.
