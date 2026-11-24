# Handoff

Commit: Main after 1.1.2-alpha.1 (PR #261, released 2026-11-24) and #256.
Branch: start your own from Main. Main is protected, so changes go in by PR only; merge it yourself once CI is green. **The plan and the owner's decisions** are in the private Kmandevr/AutoStacc-Hub: docs/caw/decisions.md ("2026-11-24: realism after 1.1.2, and compatibility in the alpha"), docs/caw/realism-research.md, docs/caw/roadmap.md (1.1.3) and Hub issues #30 (realism) and #29 (maintenance). Read those first.

## Goal
Build **1.1.3**, the realistic instruments, one instrument per step, and let the owner listen after each.
- Timber splits into Starling (piano, guitar, harp), Nightingale (bowed strings), Curlew (winds), Woodpecker (percussion) and Bittern (pipe organ).
- Each is a synthesized source with recorded bodies and noises (CC0/CC-BY, about 15 MB bundled), dry by default, with only the noises the real instrument makes.
- Start with Starling's piano: the hybrid from the Salamander Grand, about 1.5 MB.

## Done and verified
- 1.1.2-alpha.1 is released (app.yml run 2278 succeeded).
- The lessons from 1.1.2 are in .claude/rules (engine, ci, app) and .claude/README.md ("Session quirks").

## State
- Nothing for 1.1.3 is built yet. The research names the causes:
  - the bowed strings' force is not tied to bow speed;
  - the winds' bore click is the "piano on the flute";
  - every model has a heavy default room;
  - Rook's kit presets are buried at positions 93–116;
  - Randomize draws its values uniformly.
- The name check of the new names was run on 2026-11-24; see the Hub decisions for its result.

## Open (owner)
- Branch cleanup: the proxy refuses branch deletes, so the owner deletes merged branches on GitHub.
- Before any new UI look (the four instruments' pages, Rook's kit kinds, the Randomness knob), ask the owner.

## Rules for continuing
- **No lost work:** push after every commit, and back up agent worktrees to `caw-backup-*`.
- **Loop guard:** one CI re-run per failure.
- **Efficiency:** 2–3 agents at a time, short output, a recommendation with every question.
- **No Claude Code or claude.ai session links** anywhere (owner).

## Next
Starling's piano first. Plan its build against the research (Part B piano, recorded parts list), then the shared recordings loader with load-on-use, the knob gesture, and Rook's presets and Randomize.
