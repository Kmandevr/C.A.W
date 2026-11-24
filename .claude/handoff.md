# Handoff

Branch: `ccr-bd7ac4df-86w0bh`, PR #264 (Starling + Nightingale; merge it yourself once CI is green). A 5-hourly scheduled wake-up resumes this session.
**The plan and the owner's decisions** are in the private Kmandevr/AutoStacc-Hub: docs/caw/decisions.md (2026-11-24 entries, incl. "the road to 1.2.0, worked without listening gates"), docs/caw/realism-research.md, docs/caw/roadmap.md.

## Goal
Take C.A.W from 1.1.2-alpha.1 to 1.2.0 (roadmap order: 1.1.3 realistic instruments + maintenance, 1.1.4–1.1.7, silent groundwork, 1.2.0 switch-on).
- Owner: don't wait to listen; keep working; input now and then is weighed, not an order unless said. Ask only for UI looks (one mockup page per release).
- Never link Claude Code or a claude.ai session in commits/PRs/files (commits were refused with the session line).

## Done and verified
- Starling (org.caw.starling, hybrid piano, Salamander CC-BY 3.0, embedded FLAC, recorded_bank load-on-use) — tests, rt, references; flutter test 2819 passed with CAW_LIB.
- Nightingale (org.caw.nightingale, bowed strings) — measured window/tuning tables (tests under --update-references), bodies from VSCO 2 CE (CC0) via engine/tools/nightingale_bodies.py; all realism tests pass; cost ~8.7k vs 9.6k.
- Flutter 3.47.7 is installed at /opt/fl/flutter (analytics off). Sample sources in the scratchpad dl/ (Salamander, VSCO 2 CE, VCSL).

## Next
1. Merge #264 when green; release 1.1.3-alpha.1 (version bump in pubspec + lib/version.dart, CHANGELOG at root and app/assets).
2. Curlew (winds: research B3, the bore click is the "piano on the flute"), Bittern (pipe organ, cathedral room on), Woodpecker (percussion), Starling guitar/harp; then Timber removed with migration (EP + tonewheel to Raven).
3. Rook realistic kit/presets/Randomness, sideways knob drag, 60 Hz UI while playing; maintenance (Hub #29).
4. Mockups for the new pages (one page per release), ask the owner.
