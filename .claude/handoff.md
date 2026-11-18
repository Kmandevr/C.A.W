# Handoff

Commit: 9eedcc0 (Main: v1.0.6-alpha.1 published; 1.0.7 silent work merged through PR #252)
Branch: ccr-56285e11-0xrj3h. Main is protected: PRs only; merge yourself when CI is green. Plans, the vision and feature tasks live in the private Kmandevr/AutoStacc-Hub (docs/caw/, its Issues); this repository's Issues are public bugs only.

## Goal
1.0.7: security and the AutoStacc Hub (owner, 2026-11-18), plus silent groundwork. The Hub is AutoStacc's app and C.A.W's companion, package `com.autostacc.hub`, in the private repo.

## Done and verified
- General mixer routing, engine and app model, no screens (owner: engine only for now); C API 36; file version 6 only when used. Checks: `ctest` 11/11, `CAW_LIB=… flutter test` 2372, every CI job green on PR #252.
- C.A.W accepts the Hub only by its pinned certificate (`HUB_CERT_SHA256`, empty = none), binds with `BIND_ALLOW_ACTIVITY_STARTS` on Android 14+. Security review: nothing exploitable.
- The Hub's first Android build (service + site window) in the Hub repo, reviewed and hardened; its tests and builds pass locally.

## Open
- Owner: the Hub's signing key and secrets, `CAW_CERT_SHA256` (Hub) and `HUB_CERT_SHA256` (C.A.W) variables, an icon; which release channel the Hub installs; a foreground service for long downloads.
- First device test once the keys exist: a wrongly signed Hub is refused; an update installs through the Hub.
- #251 (music video switches erase manual work), #20 (keyboard Backspace).

## Next
1. Wait for the owner's keys and answers; then run the Hub's Actions build and test on the S22+.
2. Other 1.0.7 work from the private roadmap.
