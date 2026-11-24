# Handoff

Commit: b6ec43f (branch ccr-bd7ac4df-86w0bh, PR #264: Starling, Nightingale, Curlew; merge it yourself once CI is green)
A 5-hourly scheduled wake-up resumes this session. The plan and the owner's decisions: private Kmandevr/AutoStacc-Hub
docs/caw/decisions.md (2026-11-24, "the road to 1.2.0, worked without listening gates"), realism-research.md, roadmap.md.

## Goal
Take C.A.W from 1.1.2-alpha.1 to 1.2.0 in the roadmap's order (1.1.3 realistic instruments and maintenance,
1.1.4-1.1.7, the silent groundwork, 1.2.0's switch-on). Don't wait for the owner to listen; ask only for UI looks
(one mockup page per release). Never link Claude Code or a claude.ai session in commits, PRs or files.

## Done and verified
- Starling (hybrid piano, Salamander CC-BY 3.0 embedded, `engine/src/recorded_bank.cpp` load-on-use).
- Nightingale (bowed strings: measured window and tuning tables, VSCO 2 CE bodies) and Curlew (winds: no bore
  click, brass lips 1.15, per-semitone pull table, bodies; the sax has none yet).
- `engine/tools/instrument_bodies.py` (both families); local ctest 24/24 at Nightingale; flutter test 2819 passed.
- Flutter 3.47.7 at /opt/fl/flutter; sample sources (Salamander, VSCO 2 CE, VCSL) in the scratchpad's dl/.

## Open
- Curlew limits: flute C7, trombone E2, the horn's lowest notes; the sax's octave jump at C#4; key/valve noises.
- The owner's look for the new instrument pages (fallback knob pages until then).

## Next
1. Merge #264; release 1.1.3-alpha.1 (pubspec, `app/lib/version.dart`, both CHANGELOGs).
2. Bittern (pipe organ: table pipes, chiff, living wind, York Minster room on, VCSL organ CC0), Woodpecker,
   Starling guitar/harp; then Timber removed with migration (EP and tonewheel to Raven).
3. Rook realistic kit, presets, Randomness; sideways knob drag; 60 Hz UI while playing; maintenance (Hub #29).
