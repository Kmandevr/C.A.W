---
title: Routing plan
summary: The target model and silent staged plan for 1.1.0's visual, non-linear routing (#233): nodes and wires everywhere, patches, feedback in sub-blocks, the steps per batch and the owner's open questions; planned, not built.
updated: 2026-11-17
---

# Routing plan

**[Proposal]** None of this is built. It is an architect review from 2026-11-17, laid down silently in steps (the owner's groundwork rule, [decisions](decisions.md)), and goes live in 1.1.0 (#233). The owner's goals are in #233 and [decisions](decisions.md): everything works with everything, any output wires to any input, sidechain and second inputs, shared effects, free modulators, Odin-style selectors.

## What exists **[Fact]** (checked 2026-11-17)
- **The typed graph executor already exists:** `GraphExecutor` in `engine/src/graph.h`, with ports and connections. The routing extends it; it doesn't get a second graph.
- **The mixer (`Engine::MixGraph`, in `engine/src/engine.cpp`) works per track.** Each track is one node that holds its instrument, inserts and fader. Buses and the master are nodes. Sends and keys are side tables, not edges. Loops are refused in `validateRouting` (`engine/src/project.cpp`).
- **Flagship's matrix already has a scale-by source (`via`).** Project modulation links don't have one yet.

## The target model
- **Nodes and wires:**
  - a node has typed ports: audio, control, modulation and events;
  - a wire goes from one port to another, with a gain and a feedback flag;
  - ports can be optional, so a device's extra outputs and inputs can stay unconnected.
- **Two levels:**
  - **The outer graph:** tracks, buses, shared effect nodes and the master, in 64-frame chunks with the parallel mix pool, as today.
  - **Patches:** a compiled graph that runs as one outer node. This covers a device-chain graph, generator nodes and, later, Flagship.
- **Feedback:**
  - Each feedback wire compiles to a send/return pair that shares a small ring, so the graph stays acyclic.
  - Inside a patch, the graph runs in 16-frame sub-blocks counted from Play, so the result is the same at any buffer size. A feedback wire there costs 16 frames.
  - Between tracks, a feedback wire costs one 64-frame chunk.
  - A limiter (soft clip plus DC block) sits on each feedback return.
- **Old projects map unchanged:**
  - a track is a patch: instrument, then its chain, then the fader;
  - a bus is a summing node;
  - a send is a wire with gain;
  - a key is a wire into a sidechain port;
  - a modulator is a node, and a link is a modulation wire.

  The loader derives this and never writes it back, so old files load and save byte-identical.
- **Latency compensation** is per edge over the graph, with feedback wires and keys left uncompensated.
- **Changes** compile off the audio thread, are swapped in whole with the usual crossfade, and keep the state of unchanged nodes.
- **Limits per patch:** 64 nodes, 256 wires, 16 feedback wires and 8 ports per node.

## Silent steps
1. **1.0.6, part of the FX consolidation (#227): node-ready devices.**
   - The merged devices declare optional extra outputs: Filter low/high, Utility mid/side, Transient transient/sustain, dry/wet.
   - They also declare sidechain inputs (compressor, gates, Drive's key, the filter's envelope) and carrier inputs (ring mod, frequency shift).
   - Unconnected, they cost nothing and render the same.
   - This must be designed into #227 itself, since a later pass over the same files would conflict.
2. **1.0.6 or 1.0.7:** a `scale` source on modulation links, with Flagship's `via` meaning. The app doesn't write it yet.
3. **1.0.7: the patch model, engine-only.**
   - A new patch module and its tests. Nothing in the engine calls it yet.
   - A linear patch must null against today's chain.
   - A render must be identical at any block size.
   - A swap must allocate nothing on the audio thread.
   - A linear patch must cost within 5% of the chain.
4. **1.0.8, with #217:**
   - the mixer's routes become general edges, so receives, parallel paths and drum multi-out are built as edges;
   - this sits behind an off-by-default engine flag;
   - it waits for the automation branch to merge, since both change the same code.
5. **1.0.9:** a patch inside a track, and shared effect nodes, behind the flag. The app never writes them.
6. **1.0.9 or 1.0.10:** generator nodes: an oscillator and noise.
7. **1.0.10 or 1.0.11:** Flagship's filter and FX routing becomes a data table, with bit-identical renders.
8. **1.1.0:** the C API and the app, after the owner reviews the look.

## Risks
- **Executor rules:**
  - the executor refuses re-routing while modulation links are set, so patches compile and swap whole;
  - loop refusal exempts only flagged feedback wires;
  - optional ports in third-party components need a component ABI extension (built-ins go first).
- **CPU:** 16-frame sub-blocks mean four times the per-call overhead, so measure on the S22+.
- **Determinism:** feedback renders go in the tolerance tests' chaotic class.
- **Docs:** `architecture.md` and `engine-progress.md` still say "a node per module". Fix that when step 4 lands.

## Open questions for the owner
1. The feedback delay inside a patch: 16 frames, a per-sample mode for small patches, or both.
2. Is a 64-frame delay acceptable for feedback between tracks?
3. Is a shared effect node a new kind of track, or a generalised bus?
4. Is the feedback limiter on by default?
5. Does Flagship's graph run per voice? That costs CPU on every voice.
6. May third-party plug-ins (#212) sit inside patches?
7. When an old project is saved again, does it keep today's fields or write a patch?
