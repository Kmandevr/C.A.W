# Quick check: gpt/94-export-fixes

- Commit: `7565f4291eff383040c544bca0ebc0ddc441060f` (trust this report only if it is your latest commit)
- Finished: 2026-11-05T21:02:06Z
- Status: FINISHED
- Verdict: **FAIL**
- Environment: GitHub-hosted Linux x64 runner (ubuntu-24.04): no audio device, GPU, phone or Windows. A PASS here never proves behaviour on real hardware; only the owner's device runs can.
- Commands: as requested by `run:` lines in the commit message
- Rules for the files you changed: `.claude/rules/engine.md` (all bundled in `START.md` on `agent-results`)
- Full logs: https://github.com/Kmandevr/C.A.W/actions/runs/42105748990

| # | Command | Result | Time |
| --- | --- | --- | --- |
| 1 | `test offline_export_installs_projects_larger_than_the_command_queue_and_matches_playback` | FAIL | 1206s |
| 2 | `grep "Engine::send\|setProject\(\|renderExport\|exportPerSlot_\|applyCommands\|planChunk\|updateSolo\|CAW_API_VERSION" engine/src/engine.cpp engine/src/render.cpp engine/src/engine.h engine/src/render.h engine/include/caw.h` | PASS | 0s |

## 1. test offline_export_installs_projects_larger_than_the_command_queue_and_matches_playback: FAIL

```text
$ engine/build/caw_tests offline_export_installs_projects_larger_than_the_command_queue_and_matches_playback
timed out after 1200s
```

## 2. grep "Engine::send|setProject\(|renderExport|exportPerSlot_|applyCommands|planChunk|updateSolo|CAW_API_VERSION" engine/src/engine.cpp engine/src/render.cpp engine/src/engine.h engine/src/render.h engine/include/caw.h: PASS

```text
engine/include/caw.h:17:#define CAW_API_VERSION 1
engine/src/engine.cpp:79:    // This chunk's plan (planChunk), read by the slot's graph nodes. Chunks end at every loop
engine/src/engine.cpp:602:      exportPerSlot_(static_cast<size_t>(resourceBudget.graphWorkingBytes /
engine/src/engine.cpp:640:            static_cast<double>(exportPerSlot_) * static_cast<double>(kExportSlotBytes - kExportBufferBytes);
engine/src/engine.cpp:724:bool Engine::send(const Cmd& c) {
engine/src/engine.cpp:786:                                 2 * sizeof(Retired) + exportPerSlot_ * (kExportSlotBytes - kExportBufferBytes);
engine/src/engine.cpp:982:    return setProject(p);
engine/src/engine.cpp:985:std::string Engine::setProject(const ProjectSpec& p) {
engine/src/engine.cpp:1386:        // Every slot may hold exportPerSlot_ buffers (fixed from the budget at construction); the
engine/src/engine.cpp:1388:        const size_t budgetCapacity = exportPerSlot_;
engine/src/engine.cpp:2000:void Engine::applyCommands() noexcept {
engine/src/engine.cpp:2052:                    updateSolo();
engine/src/engine.cpp:2104:                updateSolo();
engine/src/engine.cpp:2198:                    updateSolo();
engine/src/engine.cpp:2257:void Engine::updateSolo() noexcept {
engine/src/engine.cpp:2838:int Engine::planChunk(int maxFrames) noexcept {
engine/src/engine.cpp:2905:    const int m = planChunk(maxFrames);
engine/src/engine.cpp:3261:    updateSolo();
engine/src/engine.cpp:3262:    applyCommands();
engine/src/engine.cpp:3263:    updateSolo();
engine/src/render.cpp:94:    eng.setProject(p);
engine/src/render.cpp:276:bool renderExport(const ProjectSpec& in, const ExportOptions& o, RenderResult& out, int32_t* progress,
engine/src/render.cpp:333:bool renderExportToWav(const ProjectSpec& in, const ExportOptions& o, const std::string& path, bool float32,
engine/src/render.cpp:357:    if (!renderExport(in, o, r, progress, cancel)) {
engine/src/engine.h:70:    std::string setProject(const ProjectSpec& p);  // result JSON: per-module ok/error and params
engine/src/engine.h:115:    void applyCommands() noexcept;
engine/src/engine.h:121:    int planChunk(int maxFrames) noexcept;
engine/src/engine.h:131:    void updateSolo() noexcept;
engine/src/engine.h:154:    const size_t exportPerSlot_;
engine/src/render.h:38:bool renderExport(const ProjectSpec& p, const ExportOptions& o, RenderResult& out, int32_t* progress = nullptr,
engine/src/render.h:43:// renderExport. On failure or cancel no file is left behind.
engine/src/render.h:44:bool renderExportToWav(const ProjectSpec& p, const ExportOptions& o, const std::string& path, bool float32,
```

Next: fix only what the failing sections name, push once (with `run:` lines for just the failing commands), then read this file again for the new commit.
