// Control thread: the project diff (setProject*), slot growth, native components and latency compensation.
#include "engine_impl.h"

namespace caw {

namespace {
// An instrument chain's entries: the instrument, then the track's MIDI effects (1.1.0).
std::vector<ComponentSpec> instrumentSpecs(const ComponentSpec& instrument, const std::vector<ComponentSpec>* midi) {
    std::vector<ComponentSpec> specs{instrument};
    if (midi) specs.insert(specs.end(), midi->begin(), midi->end());
    return specs;
}

constexpr size_t kMaxProjectComponents = 256;  // native component instances in one project (tracks and master)
constexpr int64_t kMaxCompensationFrames = 1 << 15;  // latency compensation up to about 0.7 s at 48 kHz

 // An upper bound on the bytes compileArrangement builds, so a huge looping clip is refused before it is expanded.
double arrangementBytes(const std::vector<ClipSpec>& clips,
    const std::map<std::string, std::shared_ptr<const Pattern>>& sources, int beatsPerBar) {
    double total = 0;
    for (const ClipSpec& clip : clips) {
        if (clip.mute) continue;
        const auto found = sources.find(clip.pattern);
        if (found == sources.end() || !found->second || found->second->notes.empty()) continue;
        const Pattern& src = *found->second;
        const double sourceLength = clip.loopSteps > 0 ? clip.loopSteps : std::max(1, src.steps(beatsPerBar));
        const double passes = clip.loop ? 2.0 + std::floor(clip.lengthSteps / sourceLength) : 1.0;
        double ratchets = 0;
        for (const PatternNote& note : src.notes) ratchets += std::max(1, static_cast<int>(note.ratchet));
        total += passes * (static_cast<double>(src.notes.size()) * sizeof(PatternNote) + 2.0 * ratchets * sizeof(PatternEvent));
    }
    return total;
}

 // Compile clip instances off the audio thread into one immutable, absolute-time event stream.
std::shared_ptr<const Pattern> compileArrangement(
    const std::vector<ClipSpec>& clips,
    const std::map<std::string, std::shared_ptr<const Pattern>>& sources,
    int beatsPerBar,
    int projectLengthSteps) {
    auto out = std::make_shared<Pattern>();
    out->name = "Arrangement";
    out->lengthSteps = projectLengthSteps;
    for (const ClipSpec& clip : clips) {
        if (clip.mute) continue;  // a muted clip plays nothing; the layer still follows the arrangement
        const auto found = sources.find(clip.pattern);
        if (found == sources.end() || !found->second) continue;
        const Pattern& src = *found->second;
        if (src.notes.empty()) continue;  // nothing to place, however often the clip repeats it
        // The clip's own loop point (0: the pattern's length): notes past it never play, and a loop past the
        // pattern's end plays silence up to it before repeating.
        const int sourceLength = clip.loopSteps > 0 ? clip.loopSteps : std::max(1, src.steps(beatsPerBar));
        double sourcePos = static_cast<double>(clip.sourceOffsetSteps);
        int consumed = 0;
        int timeline = clip.startSteps;
        while (consumed < clip.lengthSteps) {
            if (sourcePos >= sourceLength) {
                if (!clip.loop) break;
                sourcePos = std::fmod(sourcePos, static_cast<double>(sourceLength));
            }
            const int segment = static_cast<int>(std::min<double>(
                clip.lengthSteps - consumed, sourceLength - sourcePos));
            if (segment <= 0) break;
            const double sourceEnd = sourcePos + segment;
            const size_t noteBase = out->notes.size();
            struct RatchetSpan { double start, end; uint16_t sub; };
            std::vector<std::vector<RatchetSpan>> eventSpans;
            std::vector<int> remap(src.notes.size(), -1);
            for (size_t i = 0; i < src.notes.size(); ++i) {
                const PatternNote& original = src.notes[i];
                const double originalEnd = original.at + original.len;
                if (originalEnd <= sourcePos || original.at >= sourceEnd) continue;
                const double clippedStart = std::max(original.at, sourcePos);
                const double clippedEnd = std::min(originalEnd, sourceEnd);
                const bool trimmedAtStart = clippedStart > original.at;
                const bool trimmedAtEnd = clippedEnd < originalEnd;
                // Intersect each ratchet with the source window. This preserves both sustained
                // note tails and the original ratchet grid when a clip starts or ends mid-note.
                std::vector<RatchetSpan> spans;
                for (int q = 0; q < original.ratchet; ++q) {
                    const double ratchetStart = sampletime::ratchetStep(original.at, original.len, original.ratchet, q);
                    const double ratchetEnd = sampletime::ratchetStep(original.at, original.len, original.ratchet, q + 1);
                    const double start = std::max(ratchetStart, sourcePos);
                    const double end = std::min(ratchetEnd, sourceEnd);
                    if (end > start)
                        spans.push_back({sampletime::clipStep(timeline, start, sourcePos), sampletime::clipStep(timeline, end, sourcePos),
                                         static_cast<uint16_t>(q)});
                }
                if (spans.empty()) continue;
                PatternNote note = original;
                note.at = sampletime::clipStep(timeline, clippedStart, sourcePos);
                note.len = clippedEnd - clippedStart;
                // The note's expression (bend, vibrato, pressure, timbre) comes along: `extra` indexes the
                // source's list, so it is copied into the arrangement's and pointed there.
                if (original.extra >= 0 && static_cast<size_t>(original.extra) < src.expressions.size()) {
                    note.extra = static_cast<int>(out->expressions.size());
                    NoteExpression x = src.expressions[static_cast<size_t>(original.extra)];
                    // A cut note plays its own part of the curves (#226), not all of them squeezed into it.
                    if ((trimmedAtStart || trimmedAtEnd) && original.len > 0 && note.len > 0) {
                        x.from += x.span * (clippedStart - original.at) / original.len;
                        x.span *= note.len / original.len;
                    }
                    out->expressions.push_back(std::move(x));
                } else {
                    note.extra = -1;
                }
                if (trimmedAtStart || trimmedAtEnd) note.slideFrom = note.slideTo = -1;
                remap[i] = static_cast<int>(out->notes.size());
                out->notes.push_back(note);
                eventSpans.push_back(std::move(spans));
                out->lastEnd = std::max(out->lastEnd, note.at + note.len);
            }
            for (size_t i = 0; i < remap.size(); ++i) {
                if (remap[i] < 0) continue;
                const PatternNote& original = src.notes[i];
                PatternNote& note = out->notes[static_cast<size_t>(remap[i])];
                if (original.slideFrom >= 0 && static_cast<size_t>(original.slideFrom) < remap.size() &&
                    remap[static_cast<size_t>(original.slideFrom)] >= 0)
                    note.slideFrom = remap[static_cast<size_t>(original.slideFrom)];
                if (original.slideTo >= 0 && static_cast<size_t>(original.slideTo) < remap.size() &&
                    remap[static_cast<size_t>(original.slideTo)] >= 0)
                    note.slideTo = remap[static_cast<size_t>(original.slideTo)];
            }
            for (size_t i = 0; i < eventSpans.size(); ++i) {
                const uint32_t noteIndex = static_cast<uint32_t>(noteBase + i);
                for (const RatchetSpan& span : eventSpans[i]) {
                    out->events.push_back({span.start, noteIndex, span.sub, true});
                    out->events.push_back({span.end, noteIndex, span.sub, false});
                }
            }
            timeline += segment;
            consumed += segment;
            sourcePos = 0;
            if (!clip.loop) break;
        }
    }
    std::stable_sort(out->events.begin(), out->events.end(), [](const PatternEvent& a, const PatternEvent& b) {
        if (a.step != b.step) return a.step < b.step;
        // Release notes ending on this sample before starting notes at the same sample.
        // This allows a just-freed voice to be reused at clip and note boundaries.
        return !a.on && b.on;
    });
    return out;
}

}  // namespace

// ===================== control thread =====================

void Engine::drainRetired() {
    Retired r;
    while (retired_->pop(r)) {
        delete r.pattern;
        delete r.automation;
        delete r.order;
        delete r.table;
        delete r.masterChain;
        delete r.componentAutomation;
        delete r.delay;
        delete r.sends;
        delete r.song;
        delete r.vca;
        if (r.freed) r.freed->ctlBusy = false;
    }
}

bool Engine::send(const Cmd& c) {
    // Reclaim completed objects before publishing more work. This also makes room
    // for the audio thread to transfer any pending retirements into the SPSC queue.
    drainRetired();
    if (offlineControl_) applyCommands();
    // The audio thread empties the queue every callback; offline installation drains it synchronously.
    for (int tries = 0; !cmds_->push(c); ++tries) {
        drainRetired();
        if (offlineControl_) applyCommands();
        if (tries > sendRetries_) {
            delete c.pattern;  // audio stalled; drop rather than hang the app
            delete c.automation;
            delete c.orderList;
            delete c.table;
            delete c.masterChain;
            delete c.componentAutomation;
            delete c.delay;
            delete c.sends;
            delete c.song;
            delete c.vca;
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (offlineControl_) applyCommands();
    return true;
}

int Engine::freeSlot() {
    for (int s = 0; s < ctlTable_->capacity; ++s)
        if (!ctlSlot(s).ctlBusy) {
            ctlSlot(s).ctlBusy = true;
            return s;
        }
    return -1;
}

// Control thread, under ctl_: a table of `capacity` layer slots that keeps every existing Slot
// (layer slots at their indices, the audition moved to the new last one), a mix graph sized for
// it; sent to the audio thread as one Grow command.
std::string Engine::grow(int capacity, int routes) {
    SlotTable& old = *ctlTable_;
    capacity = std::max(capacity, old.capacity);
    routes = std::max(routes, old.graph->routesPerSlot);
    if (capacity == old.capacity && routes == old.graph->routesPerSlot) return {};
    if (capacity > maxLayers_)
        return "the project needs " + std::to_string(capacity) + " layer slots; this device's memory budget allows at most " +
               std::to_string(maxLayers_);
    const size_t storeBefore = slotStore_.size();
    auto rollBack = [&] {  // nothing new reached the audio thread: drop it again
        slotStore_.resize(storeBefore);
    };
    auto t = std::make_unique<SlotTable>();
    try {
        t->capacity = capacity;
        t->slots.reset(new Slot*[static_cast<size_t>(capacity + 1)]);
        t->processOrder.reset(new int[static_cast<size_t>(capacity + 1)]());
        t->live.reset(new int[static_cast<size_t>(capacity + 1)]());
        for (int s = 0; s < old.capacity; ++s) t->slots[s] = old.slots[s];
        t->slots[capacity] = old.slots[old.capacity];  // the audition; the audio thread sets its index
        slotStore_.reserve(storeBefore + static_cast<size_t>(capacity - old.capacity));
        for (int s = old.capacity; s < capacity; ++s) {
            slotStore_.push_back(std::make_unique<Slot>());
            slotStore_.back()->correlation.prepare(sr_);
            Slot& slot = *slotStore_.back();
            slot.index = s;
            for (int i = 0; i < kScopeSize; ++i) slot.scope[i].store(0);
            t->slots[s] = &slot;
        }
        t->graph.reset(new MixGraph(*this, capacity, sr_, resourceBudget_, routes));
        // The budget holds the old graph and the new one at once (maxLayers() allows for that).
        const uint64_t perSlot = sizeof(Slot) + sizeof(std::unique_ptr<Slot>) + sizeof(Slot*) + 2 * sizeof(int) +
                                 2 * sizeof(Retired);
        const uint64_t peak = static_cast<uint64_t>(old.graph->bytes()) + t->graph->bytes() +
                              perSlot * static_cast<uint64_t>(capacity + 1);
        if (peak > resourceBudget_.graphWorkingBytes) {
            rollBack();
            return "growing to " + std::to_string(capacity) + " layer slots needs " + std::to_string(peak) +
                   " bytes of graph working memory; this device's budget is " +
                   std::to_string(resourceBudget_.graphWorkingBytes);
        }
    } catch (const std::bad_alloc&) {
        rollBack();
        return "unable to allocate " + std::to_string(capacity) + " layer slots within the hardware-derived memory budget";
    } catch (const std::runtime_error&) {
        rollBack();
        return "the mix graph for " + std::to_string(capacity) + " layer slots could not be prepared";
    }
    const int oldAudition = old.capacity;
    Cmd c;
    c.type = Cmd::Grow;
    c.table = t.release();
    SlotTable* sent = c.table;
    if (!send(c)) {  // send() freed the table
        rollBack();
        return "audio command queue is not accepting project updates";
    }
    ctlTable_ = sent;
    ctlCapacity_.store(capacity, std::memory_order_relaxed);
    for (auto& [id, ls] : layers_)
        if (ls.slot == oldAudition) ls.slot = capacity;  // the audition's layer state follows it
    return {};
}

void Engine::writeMix(int slot, double vol, double pan, bool mute, bool solo) {
    Slot& s = ctlSlot(slot);
    s.vol.store(doubleToBits(vol), std::memory_order_relaxed);
    s.pan.store(doubleToBits(pan), std::memory_order_relaxed);
    s.mute.store(mute, std::memory_order_relaxed);
    s.solo.store(solo, std::memory_order_relaxed);
}

std::string Engine::setProjectJson(std::string_view json) {
    ProjectSpec p;
    std::string err;
    if (!parseProject(json, p, err)) return "{\"ok\":false,\"error\":\"" + jsonEscape(err) + "\",\"modules\":{}}";
    return setProject(p);
}

ModuleLoadResult Engine::loadNativeComponent(
    const std::string& path, const std::string& expectedId, NativeModuleTrust trust, const std::string& legacySha256) {
    std::lock_guard<std::mutex> lock(ctl_);
    return nativeModules_.loadSharedLibrary(path, expectedId, trust, false, legacySha256);
}

ModuleLoadResult Engine::reloadNativeComponent(
    const std::string& path, const std::string& expectedId, NativeModuleTrust trust) {
    std::lock_guard<std::mutex> lock(ctl_);
    drainRetired();
    // Every chain that uses the component, rebuilt before anything is sent: one that can't be keeps the old build.
    struct Rebuilt {
        int slot;  // -1: the master
        LayerState* layer;
        std::unique_ptr<ComponentChain> chain;
    };
    ModuleLoadResult result = nativeModules_.loadSharedLibrary(path, expectedId, trust, true);
    if (!result.success) return result;
    std::vector<Rebuilt> rebuilt;
    std::string error;
    const BuildingQuality building(&quality_);
    const BuildingLiveAudio buildingInput(audioIn_.get());
    auto rebuild = [&](ComponentChain* old, int slot, LayerState* layer, const std::string& layerId) {
        if (!old || !old->uses(expectedId)) return true;
        const std::vector<ComponentSpec> specs = old->currentSpecs();
        auto chain = old->instrument()
                         ? ComponentChain::buildInstrument(nativeModules_, specs.front(), sr_, error, {specs.begin() + 1, specs.end()})
                         : ComponentChain::build(nativeModules_, specs, sr_, error);
        if (!chain) return false;
        delete chain->swapAutomation(chain->automationFor(ctlAutomation_, layerId).release());
        rebuilt.push_back({slot, layer, std::move(chain)});
        return true;
    };
    bool ok = rebuild(ctlMasterChain_, -1, nullptr, "");
    for (auto& [id, ls] : layers_) {
        if (ok && ls.slot >= 0 && !ls.bus) ok = rebuild(ls.inserts, ls.slot, &ls, id);
        if (ok && ls.slot >= 0 && !ls.bus) ok = rebuild(ls.instrument, ls.slot, &ls, id);
    }
    if (!ok) {
        // The new build is loaded but can't take over (its ports changed, it failed to activate, ...).
        result.success = false;
        result.error = ModuleLoadError::InvalidDescriptor;
        result.message = "The rebuild is now the loaded build (new instances use it), but the playing project keeps "
                         "the previous build until it is fixed: " + error;
        return result;
    }
    for (Rebuilt& r : rebuilt) {
        Cmd c;
        const bool instrument = r.chain->instrument();
        c.type = r.slot < 0 ? Cmd::SetMasterChain : instrument ? Cmd::SetInstrument : Cmd::SetInserts;
        c.slot = r.slot;
        ComponentChain* sent = r.chain.release();
        c.masterChain = sent;
        if (!send(c)) continue;  // send() freed it; the old build plays on there
        if (r.layer) (instrument ? r.layer->instrument : r.layer->inserts) = sent;
        else ctlMasterChain_ = sent;
    }
    std::map<std::string, std::vector<std::string>> warnings;
    updateCompensation(warnings);  // the rebuild may add a different latency
    return result;
}

bool Engine::unloadNativeComponent(const std::string& id) {
    std::lock_guard<std::mutex> lock(ctl_);
    drainRetired();
    return nativeModules_.unload(id);
}

std::string Engine::nativeComponentsJson() {
    std::lock_guard<std::mutex> lock(ctl_);
    std::string json = "{\"ok\":true,\"components\":[";
    bool first = true;
    // Built-in components first, marked so the app can tell them from loaded ones (they need no trust).
    for (const ModuleDescriptor* d : nativeModules_.builtinComponents()) {
        std::string one = moduleDescriptorJson(*d);
        std::string head = first ? "{\"builtin\":true," : ",{\"builtin\":true,";
        if (!builtinPresets(d->id).empty()) head += "\"presets\":" + builtinPresetsJson(d->id) + ",";
        if (const std::string_view pack = fx::packOf(d->id); !pack.empty())  // a pack device (builtin_pack.h)
            head += "\"pack\":\"" + std::string(pack) + "\",";
        if (const fx::MergedDevice* m = fx::findMergedDevice(d->id)) {  // every variant's own descriptor
            head += "\"variants\":[";
            for (size_t v = 0; v < m->variants.size(); ++v)
                head += (v ? "," : "") + moduleDescriptorJson(m->variants[v].descriptor());
            head += "],";
        }
        json += head + one.substr(1);
        first = false;
    }
    for (const ModuleDescriptor* d : nativeModules_.loadedComponents()) {
        json += (first ? "" : ",") + moduleDescriptorJson(*d);
        first = false;
    }
    return json + "]}";
}

std::unique_ptr<ModuleProcessor> Engine::createNativeComponent(const std::string& id) {
    std::lock_guard<std::mutex> lock(ctl_);
    // A retired id makes its merged device's variant (fx_migrate.h), as a project naming it plays.
    std::string own = id;
    std::vector<std::pair<std::string, double>> params;
    if (nativeModules_.find(id) || !fx::migrateLegacyId(own, params)) return nativeModules_.create(id);
    return createComponent(nativeModules_, own, params);
}

void Engine::setQuality(int quality) noexcept {
    quality_.store(quality < kQualityEco ? kQualityEco : (quality > kQualityHigh ? kQualityHigh : quality), std::memory_order_relaxed);
}

std::string Engine::setProject(const ProjectSpec& p) {
    return setProjectImpl(p, false);
}

std::string Engine::setProjectOffline(const ProjectSpec& p) {
    offline_.store(true, std::memory_order_relaxed);
    return setProjectImpl(p, true);
}

std::string Engine::setProjectImpl(const ProjectSpec& p, bool offline) {
    {
        bool monitors = false;  // an audio track that monitors its input runs while stopped (wakeMonitors)
        for (const LayerSpec& l : p.layers)
            monitors = monitors || (l.instrument.audioTrack && l.instrument.audioTrack->input.present &&
                                    l.instrument.audioTrack->input.monitor != 0);
        monitorWanted_.store(monitors, std::memory_order_relaxed);
    }
    const BuildingQuality building(&quality_);
    const BuildingOffline buildingOffline(offline);
    const BuildingLiveAudio buildingInput(audioIn_.get());
    {
        // Sends to buses only, keys from playing layers, and no loops (parseProject checks it too; this covers
        // projects built in code).
        std::string error;
        if (!validateRouting(p, error)) return "{\"ok\":false,\"error\":\"" + jsonEscape(error) + "\",\"modules\":{}}";
    }
    // The synths that became Flagship presets (2026-11-10, one synth): an old project's track plays Flagship with
    // the matching preset and its knobs mapped, and its lanes on those knobs move Flagship's.
    if (std::any_of(p.layers.begin(), p.layers.end(), [](const LayerSpec& l) { return isLegacyInstrument(l.instrument.id); })) {
        ProjectSpec migrated = p;
        for (LayerSpec& l : migrated.layers) {
            if (!isLegacyInstrument(l.instrument.id)) continue;
            const std::string legacy = l.instrument.id;
            const auto oldParams = l.instrument.params;  // Timber's lanes follow the model it played
            migrateLegacyInstrument(l.instrument.id, l.instrument.params);
            l.instrument.hasState = false;  // the old synths saved no state
            auto& lanes = migrated.automation;
            for (auto it = lanes.begin(); it != lanes.end();) {
                if (it->targetType == "instrument" && it->moduleId == l.id) {
                    it->target = migratedLegacyParameter(legacy, it->target, &oldParams);
                    if (it->target.empty()) {  // an old knob with no Flagship knob in its units
                        it = lanes.erase(it);
                        continue;
                    }
                }
                ++it;
            }
        }
        return setProjectImpl(migrated, offline);
    }
    // The effects merged into one device each (FX consolidation, 1.0.8, fx_migrate.h): an old id plays its merged
    // device's variant with its values moved, in every component list and rack, and its lanes and links follow.
    if (fx::hasLegacyEffects(p)) {
        ProjectSpec migrated = p;
        fx::migrateLegacyEffects(migrated);
        return setProjectImpl(migrated, offline);
    }
    std::lock_guard<std::mutex> lock(ctl_);
    offlineControl_ = offline;
    struct OfflineControlReset {
        bool& active;
        ~OfflineControlReset() { active = false; }
    } reset{offlineControl_};
    drainRetired();

    // Native component chains: the master's and each track's inserts. Components must already be
    // explicitly loaded through the trust-gated Engine API. Every chain is built (and activated) here,
    // before anything is sent, so a component that can't run refuses the whole update. A chain with
    // the same components in the same order is kept, running state and all, and only takes values.
    std::unique_ptr<ComponentChain> nextMasterChain;
    const bool keepMasterChain = ctlMasterChain_ && ctlMasterChain_->sameComponents(p.masterComponents, sr_);
    std::map<std::string, std::unique_ptr<ComponentChain>> nextInserts;
    std::map<std::string, std::unique_ptr<ComponentChain>> nextInstruments;  // native instruments to send
    uint64_t masterChainBytes = 0;  // every component chain the project holds, for the state budget
    {
        auto charge = [&](const std::vector<ComponentSpec>& specs) {
            size_t parameters = 0;
            for (const ComponentSpec& c : specs)
                if (const ModuleDescriptor* d = nativeModules_.find(c.id)) parameters += d->parameterCount;
            masterChainBytes += ComponentChain::estimateBytes(specs.size(), parameters);
        };
        if (!p.masterComponents.empty()) charge(p.masterComponents);
        size_t total = p.masterComponents.size();
        for (const LayerSpec& l : p.layers) {
            if (!(l.folder && !l.busEnabled) && !l.components.empty()) {  // tracks and bus folders run inserts
                charge(l.components);
                total += l.components.size();
            }
            if (!l.folder && l.hasInstrument) {
                charge(instrumentSpecs(l.instrument, &l.midiComponents));
                masterChainBytes += sizeof(NoteEvents) + NoteEvents::kBytes;  // its note list and held notes
                if (!l.midiComponents.empty()) masterChainBytes += NoteEvents::kCapacity * sizeof(Event);  // their scratch
                total += 1 + l.midiComponents.size();
            }
            if (!l.folder && !l.noteComponents.empty())  // per-note FX (#127): each slot chain and the overflow chain
                for (int k = 0; k <= noteFxSlots(l.noteVoices); ++k) {
                    charge(l.noteComponents);
                    total += l.noteComponents.size();
                }
        }
        if (p.auditionOnly) {  // the preview's own chain, as a track's
            if (!p.auditionComponents.empty()) {
                charge(p.auditionComponents);
                total += p.auditionComponents.size();
            }
            if (p.hasAuditionInstrument) {
                charge({p.auditionInstrument});
                masterChainBytes += sizeof(NoteEvents) + NoteEvents::kBytes;
                ++total;
            }
        }
        // Each instance may allocate what it likes when activated; the cap bounds how many there are.
        if (total > kMaxProjectComponents)
            return "{\"ok\":false,\"error\":\"the project uses " + std::to_string(total) +
                   " native components; at most " + std::to_string(kMaxProjectComponents) + " can run\",\"modules\":{}}";
        if (masterChainBytes > resourceBudget_.projectStateBytes)
            return R"({"ok":false,"error":"native component chains exceed this Engine's project-state memory budget","modules":{}})";
        std::string error;
        if (!keepMasterChain && !p.masterComponents.empty()) {
            nextMasterChain = ComponentChain::build(nativeModules_, p.masterComponents, sr_, error);
            if (!nextMasterChain)
                return "{\"ok\":false,\"error\":\"master: " + jsonEscape(error) + "\",\"modules\":{}}";
        }
        for (const LayerSpec& l : p.layers) {
            if ((l.folder && !l.busEnabled) || l.components.empty()) continue;  // organization-only folders run none
            auto it = layers_.find(l.id);
            // A layer that turns from a track into a bus (or back) starts its inserts afresh: its slot drops them.
            if (it != layers_.end() && it->second.inserts && it->second.bus == l.folder &&
                it->second.inserts->sameComponents(l.components, sr_))
                continue;
            auto chain = ComponentChain::build(nativeModules_, l.components, sr_, error);
            if (!chain)
                return "{\"ok\":false,\"error\":\"layer '" + jsonEscape(l.id) + "': " + jsonEscape(error) +
                       "\",\"modules\":{}}";
            nextInserts[l.id] = std::move(chain);
        }
        for (const LayerSpec& l : p.layers) {
            if (l.folder || !l.hasInstrument) continue;
            auto it = layers_.find(l.id);
            if (it != layers_.end() && it->second.instrument &&
                it->second.instrument->sameComponents(instrumentSpecs(l.instrument, &l.midiComponents), sr_))
                continue;
            auto instrument = ComponentChain::buildInstrument(nativeModules_, l.instrument, sr_, error, l.midiComponents);
            if (!instrument)
                return "{\"ok\":false,\"error\":\"layer '" + jsonEscape(l.id) + "' instrument: " + jsonEscape(error) +
                       "\",\"modules\":{}}";
            nextInstruments[l.id] = std::move(instrument);
        }
        // Per-note FX (#127, note_fx_host.cpp): built here too, so one that can't run refuses the update.
        if (const std::string why = noteFx_->prepare(nativeModules_, p, sr_); !why.empty())
            return "{\"ok\":false,\"error\":\"" + jsonEscape(why) + "\",\"modules\":{}}";
        if (p.auditionOnly) {
            const std::string id = "\1audition";
            auto it = layers_.find(id);
            if (!p.auditionComponents.empty() &&
                !(it != layers_.end() && it->second.inserts && it->second.inserts->sameComponents(p.auditionComponents, sr_))) {
                auto chain = ComponentChain::build(nativeModules_, p.auditionComponents, sr_, error);
                if (!chain)
                    return "{\"ok\":false,\"error\":\"audition: " + jsonEscape(error) + "\",\"modules\":{}}";
                nextInserts[id] = std::move(chain);
            }
            if (p.hasAuditionInstrument &&
                !(it != layers_.end() && it->second.instrument && it->second.instrument->sameComponents({p.auditionInstrument}, sr_))) {
                auto instrument = ComponentChain::buildInstrument(nativeModules_, p.auditionInstrument, sr_, error);
                if (!instrument)
                    return "{\"ok\":false,\"error\":\"audition instrument: " + jsonEscape(error) + "\",\"modules\":{}}";
                nextInstruments[id] = std::move(instrument);
            }
        }
    }
    // Layer slots: refuse a project the budget cannot hold, then grow before any layer is sent, so
    // every command below uses the new table. A folder without a bus takes no slot.
    {
        int layerCount = 0;
        for (const LayerSpec& l : p.layers) layerCount += !(l.folder && !l.busEnabled);
        if (layerCount > maxLayers_)
            return "{\"ok\":false,\"error\":\"project has " + std::to_string(layerCount) +
                   " layers; this device's memory budget allows at most " + std::to_string(maxLayers_) +
                   "\",\"modules\":{}}";
        // Slots still busy (layers that stay, or are fading out) plus one per layer that has none yet.
        int needed = 0;
        for (int s = 0; s < ctlTable_->capacity; ++s) needed += ctlSlot(s).ctlBusy;
        for (const LayerSpec& l : p.layers) {
            if (l.folder && !l.busEnabled) continue;
            auto it = layers_.find(l.id);
            if (it == layers_.end() || it->second.slot < 0) ++needed;
        }
        // Routes per slot (owner, 2026-11-19): the most any one layer feeds, its sends plus the keys it gives.
        std::map<std::string, int> routesOf;
        for (const LayerSpec& l : p.layers) {
            routesOf[l.id] += static_cast<int>(l.sends.size());
            for (const ComponentSpec& c : l.components)
                if (c.hasKey) ++routesOf[c.key.layer];
        }
        int routes = 0;
        for (const auto& [id, n] : routesOf) routes = std::max(routes, n);
        if (needed > ctlTable_->capacity || routes > ctlTable_->graph->routesPerSlot) {
            const int capacity =
                needed > ctlTable_->capacity ? std::min(maxLayers_, std::max(needed, 2 * ctlTable_->capacity)) : 0;
            const std::string error = grow(capacity, routes);
            if (!error.empty()) return "{\"ok\":false,\"error\":\"" + jsonEscape(error) + "\",\"modules\":{}}";
        }
    }
    const int slotCount = ctlTable_->capacity + 1;
    const int auditionSlot = ctlTable_->capacity;

    // Transport first, so new layers start with the right timing.
    Cmd t;
    t.type = Cmd::Transport;
    t.bpm = p.bpm;
    t.beatsPerBar = p.beatsPerBar;
    t.loopSteps = p.loopSteps();
    t.loopRange = p.loopRange && p.loopEndSteps > p.loopStartSteps && p.loopEndSteps <= p.loopSteps();
    t.loopFromSteps = p.loopStartSteps;
    t.loopToSteps = p.loopEndSteps;
    t.seed = p.seed;
    t.master = p.master;
    SongTime song = songTimeOf(p, ctlSr_);
    // Following a MIDI clock (API 47): the live tempo stays the follower's; the project's map waits for it to stop.
    if (ctlFollowBpm_ > 0) {
        ctlProjectTempo_ = song.tempo.points();
        song.tempo.build({TempoPointSpec{0, ctlFollowBpm_, false}}, ctlSr_);
    }
    // While recording, the tempo map stays: a take's steps are worked out on the map it was played against.
    const bool keepTempo = audioIn_->recordingNow() && song.tempo.points() != ctlSong_.tempo.points();
    if (keepTempo) song.tempo = ctlSong_.tempo;
    song.serial = ++songSerial_;
    t.song = new SongTime(song);
    if (!send(t))
        return "{\"ok\":false,\"error\":\"audio command queue is not accepting project updates\",\"modules\":{}}";
    ctlSong_ = std::move(song);
    audioIn_->setTempoPoints(ctlSong_.tempo.points());
    ctlLoopSteps_ = p.loopSteps();
    ctlLoopLen_ = static_cast<int64_t>(ctlSong_.tempo.roundFrame(p.loopSteps()));

    const auto projectAutomation = std::make_shared<const std::vector<ProjectAutomationLaneSpec>>(p.automation);
    ctlAutomation_ = projectAutomation;

    // Modules are patterns (note clips): parse the changed ones. A broken one keeps its last good version playing.
    bool allOk = true;
    std::map<std::string, ModuleState> next;
    for (const ModuleSpec& m : p.modules) {
        ModuleState st;
        auto it = modules_.find(m.id);
        if (it != modules_.end()) st = it->second;
        if (it == modules_.end() || st.source != m.source || (!st.pattern && st.error.empty())) {
            PatternResult r = parsePattern(m.source);
            st.source = m.source;
            if (r.pattern) {
                st.pattern = r.pattern;
                st.error.clear();
                st.line = st.col = 0;
            } else {
                st.error = r.error;
                st.line = r.line;
                st.col = r.col;
            }
        }
        if (!st.error.empty()) allOk = false;
        next[m.id] = std::move(st);
    }
    modules_ = std::move(next);

    // Layers: diff against what the audio thread has, sending only what changed.
    struct Want {
        std::string id;
        std::string pattern;
        int steps;
        double vol, pan;
        bool mute, solo;
        int order;
        std::vector<ClipSpec> clips;
        std::vector<AutomationLaneSpec> automation;
        std::string parentId;
        bool bus = false;
        const std::vector<ComponentSpec>* components = nullptr;  // the layer's native inserts
        const ComponentSpec* instrument = nullptr;  // the layer's native instrument, if any
        std::string outputId;  // "output": the bus its audio goes to instead of its folder's ("": that)
        const std::vector<ComponentSpec>* midi = nullptr;  // the layer's MIDI effects (its instrument's entries 1..)
        // The armed signal (1.1.0): an audio track armed with monitoring on or auto plays its inserts' near-zero-delay
        // versions (ArmedVersion); an export never does.
        bool armed = false;
        const MidiOutSpec* midiOut = nullptr;  // a MIDI-out layer (API 47): its notes go out as MIDI, not to an instrument
    };
    std::vector<Want> wants;
    int order = 0;
    if (p.auditionOnly) {
        wants.push_back({"\1audition", p.auditionPattern, p.auditionSteps, 0.8, 0.0, false, false, 100000, {}, {}, "", false,
                         &p.auditionComponents, p.hasAuditionInstrument ? &p.auditionInstrument : nullptr, ""});
    }
    order_.clear();
    for (const LayerSpec& l : p.layers) {
        order_.push_back(l.id);
        wants.push_back({l.id, l.pattern, l.lengthSteps, l.volume, l.pan, l.mute, l.solo, ++order, l.clips, l.automation, l.parentId, l.folder && l.busEnabled, &l.components,
                         l.hasInstrument && !l.folder ? &l.instrument : nullptr, l.outputId, &l.midiComponents});
        const auto& track = l.instrument.audioTrack;
        wants.back().armed = !offline && !l.folder && track && track->input.present && track->input.armed &&
                             track->input.monitor != 0;
        wants.back().midiOut = l.hasMidiOut && !l.folder ? &l.midiOut : nullptr;
    }

    // Pass 1: whether each layer plays (a track needs an instrument), its notes, and its slot.
    struct Planned {
        Want w;
        LayerState ls;
        std::shared_ptr<const Pattern> pattern;
        std::string arrangementSig;
        std::string automationSig;
        bool track = false;  // a native instrument plays the layer's notes
    };
    std::vector<Planned> plan;
    std::map<std::string, LayerState> nextLayers;
    std::map<std::string, std::vector<std::string>> warnings;
    for (std::string& w : modulationCostWarnings(p)) warnings["project"].push_back(std::move(w));  // never a refusal
    if (keepTempo)
        warnings["project"].push_back("the tempo map can't change while recording: it stays until the recording stops");
    // A native component chain's automation lanes: a chain about to be sent takes its table now (the
    // audio thread doesn't have it yet); a kept chain gets a new table only when its lanes changed.
    auto attachAutomation = [&](ComponentChain& chain, const std::string& layer) {
        delete chain.swapAutomation(chain.automationFor(projectAutomation, layer).release());
    };
    auto updateAutomation = [&](int slot, ComponentChain& chain, const std::string& layer, std::string& key) {
        std::string next = ComponentChain::automationKey(p.automation, layer, chain.instrument() ? "instrument" : "component");
        if (next == key) return;
        Cmd c;
        c.type = Cmd::SetComponentAutomation;
        c.slot = slot;
        c.flag = chain.instrument();
        c.componentAutomation = chain.automationFor(projectAutomation, layer).release();
        if (send(c)) {
            key = std::move(next);
        } else {
            allOk = false;
            warnings["project"].push_back("audio command queue rejected a native component automation update");
        }
    };
    for (const auto& [id, st] : modules_) {
        if (!st.pattern) continue;
        const int steps = st.pattern->steps(p.beatsPerBar);
        int late = 0;
        for (const PatternNote& n : st.pattern->notes) late += n.at >= steps;
        if (late > 0)
            warnings[id].push_back(std::to_string(late) + " note" + (late == 1 ? " starts" : "s start") +
                                   " after the pattern's length and never play" + (late == 1 ? "s" : ""));
    }
    uint64_t projectStateBytes = masterChainBytes;  // includes the known master-chain object and processor pointer storage
    std::vector<std::vector<int>> readsFrom(static_cast<size_t>(slotCount));
    for (Want& w : wants) {
        Planned pl{w, {}, nullptr, {}, {}};
        pl.track = (w.instrument != nullptr || w.midiOut != nullptr) && !w.bus;
        uint64_t layerStateBytes = 0;
        // Arrangement clips are compiled into an immutable absolute-time event stream here,
        // on the control thread. A layer still plays them on one instrument through one chain.
        if (!w.clips.empty() && pl.track) {
            pl.arrangementSig = std::to_string(p.beatsPerBar) + "|" + std::to_string(p.loopSteps()) + "|";
            std::map<std::string, std::shared_ptr<const Pattern>> sources;
            for (const auto& [moduleId, module] : modules_)
                if (module.pattern) sources.emplace(moduleId, module.pattern);
            for (const ClipSpec& clip : w.clips) {
                pl.arrangementSig += clip.id + "|" + clip.pattern + "|" + std::to_string(clip.startSteps) + "|" +
                    std::to_string(clip.lengthSteps) + "|" + std::to_string(clip.sourceOffsetSteps) + "|" +
                    std::to_string(clip.loopSteps) + "|" + (clip.loop ? "1" : "0") + (clip.mute ? "m" : "") + "|";
                auto source = modules_.find(clip.pattern);
                if (source != modules_.end()) pl.arrangementSig += source->second.source;
                pl.arrangementSig += "\x1e";
            }
            // The expanded clips are project state: refuse them, before building them, past the budget left after
            // the project so far. Building takes about three times the result (vectors grow by doubling and the sort
            // takes a buffer the size of the events), so that peak must fit too.
            const double expanded = arrangementBytes(w.clips, sources, p.beatsPerBar);
            const double left = static_cast<double>(resourceBudget_.projectStateBytes) - static_cast<double>(projectStateBytes);
            if (expanded > 0 && 3.0 * expanded > left) {
                warnings["project"].push_back("layer '" + w.id + "' not installed: its arrangement clips expand to about " +
                    std::to_string(static_cast<uint64_t>(std::min(expanded, 1.8e19))) +
                    " bytes of notes, over this Engine's project-state budget of " +
                    std::to_string(resourceBudget_.projectStateBytes) + " bytes");
                allOk = false;
                pl.track = false;
            } else {
                auto previous = layers_.find(w.id);
                if (previous != layers_.end() && previous->second.arrangementSig == pl.arrangementSig &&
                    previous->second.pattern) {
                    pl.pattern = previous->second.pattern;
                } else {
                    pl.pattern = compileArrangement(w.clips, sources, p.beatsPerBar, p.loopSteps());
                }
                pl.w.steps = 0;  // arrangement follows the project transport, not an individual clip loop
                layerStateBytes = static_cast<uint64_t>(std::ceil(expanded));
            }
        } else if (!w.pattern.empty() && pl.track) {
            auto it = modules_.find(w.pattern);
            if (it != modules_.end() && it->second.pattern) {
                pl.pattern = it->second.pattern;
                pl.w.steps = pl.pattern->steps(p.beatsPerBar);
            } else {
                warnings["project"].push_back("layer '" + w.id + "': pattern '" + w.pattern +
                                              "' is missing or has an error, so it plays without one");
            }
        }
        if (pl.track && layerStateBytes > resourceBudget_.projectStateBytes - std::min(projectStateBytes, resourceBudget_.projectStateBytes)) {
            warnings["project"].push_back("layer '" + w.id + "' not installed: its notes exceed this Engine's project-state budget of " +
                std::to_string(resourceBudget_.projectStateBytes) + " bytes");
            allOk = false;
            pl.track = false;
        }
        if (pl.track) projectStateBytes += layerStateBytes;
        auto it = layers_.find(w.id);
        if (it != layers_.end()) {
            pl.ls = it->second;
            layers_.erase(it);
        }
        const bool isAudition = w.id[0] == '\x01';
        if (!w.bus && !pl.track) {
            // Nothing plays it (no instrument): it takes no slot.
            if (pl.ls.slot >= 0) {
                Cmd c;
                c.type = Cmd::Remove;
                c.slot = pl.ls.slot;
                if (!send(c)) {
                    allOk = false;
                    warnings[w.id].push_back("audio command queue rejected removal of a layer that plays nothing");
                    nextLayers[w.id] = pl.ls;
                }
            }
            continue;
        }
        if (pl.ls.slot < 0) {
            pl.ls.slot = isAudition ? auditionSlot : freeSlot();
            if (isAudition) ctlSlot(auditionSlot).ctlBusy = true;
            if (pl.ls.slot < 0) {
                allOk = false;
                warnings[w.id].push_back("no free engine layer slot; layer was not installed because previous removals are still fading");
                nextLayers[w.id] = pl.ls;
                continue;
            }
            pl.ls.automationSig = "\x01new-slot";  // force an empty-or-populated automation command on slot reuse
            pl.ls.track = false;
            pl.ls.inserts = nullptr;
            pl.ls.instrument = nullptr;
            pl.ls.midiOut = false;
            pl.ls.compensation = 0;
            pl.ls.pattern = nullptr;
            pl.ls.steps = -1;
            pl.ls.volume = -1;
        }
        plan.push_back(std::move(pl));
    }

    // Resolve nested folder buses and make parents depend on their children in render order.
    std::map<std::string, int> slotByLayer;
    std::map<std::string, const LayerSpec*> specByLayer;
    for (const LayerSpec& layer : p.layers) specByLayer[layer.id] = &layer;
    for (const Planned& pl : plan) slotByLayer[pl.w.id] = pl.ls.slot;
    // Parent walks are bounded by the layer count (a chain has fewer ancestors), so they also end on a cycle.
    const int maxDepth = static_cast<int>(p.layers.size());
    for (Planned& pl : plan) {
        // Recompute routing from the new project, not the previous snapshot.
        pl.ls.parentSlot = -1;
        // An "output" names the bus the audio goes to (validateRouting: an enabled bus folder); the folder it shows
        // in (parent) then only organizes it.
        std::string parent = pl.w.outputId.empty() ? pl.w.parentId : pl.w.outputId == kMasterOutput ? "" : pl.w.outputId;
        for (int depth = 0; !parent.empty() && depth < maxDepth; ++depth) {
            auto spec = specByLayer.find(parent);
            if (spec == specByLayer.end()) break;
            auto bus = slotByLayer.find(parent);
            if (spec->second->folder && spec->second->busEnabled && bus != slotByLayer.end()) {
                pl.ls.parentSlot = bus->second;
                break;
            }
            parent = spec->second->parentId;
        }
        if (pl.ls.parentSlot >= 0) readsFrom[pl.ls.parentSlot].push_back(pl.ls.slot);
        // Soloing a folder solos its descendants; soloing a child keeps every ancestor bus open.
        std::string ancestor = pl.w.parentId;
        for (int depth = 0; !ancestor.empty() && depth < maxDepth; ++depth) {
            auto spec = specByLayer.find(ancestor);
            if (spec == specByLayer.end()) break;
            if (spec->second->solo) pl.w.solo = true;
            if (spec->second->folder && !spec->second->busEnabled && spec->second->mute) pl.w.mute = true;
            ancestor = spec->second->parentId;
        }
        if (pl.w.bus) {
            for (const LayerSpec& candidate : p.layers) {
                if (!candidate.solo) continue;
                std::string parent = candidate.parentId;
                for (int depth = 0; !parent.empty() && depth < maxDepth; ++depth) {
                    if (parent == pl.w.id) { pl.w.solo = true; break; }
                    auto spec = specByLayer.find(parent);
                    if (spec == specByLayer.end()) break;
                    parent = spec->second->parentId;
                }
            }
        }
    }

    // A soloed layer keeps open every bus it is heard through: its sends' buses and theirs, and the buses above them.
    {
        std::map<std::string, Planned*> byId;
        for (Planned& pl : plan) byId[pl.w.id] = &pl;
        for (bool changed = true; changed;) {
            changed = false;
            for (Planned& pl : plan) {
                if (!pl.w.solo) continue;
                auto spec = specByLayer.find(pl.w.id);
                if (spec == specByLayer.end()) continue;
                auto open = [&](const std::string& id) {
                    auto it = byId.find(id);
                    if (it != byId.end() && !it->second->w.solo) {
                        it->second->w.solo = true;
                        changed = true;
                    }
                };
                for (const SendSpec& send : spec->second->sends) open(send.to);
                open(routeTarget(p, *spec->second));
            }
        }
    }

    // VCA groups (vca.h): members resolved to the slots planned above (the audition, and layers without a slot, are
    // never members), sent before any Install so a layer new in a slot never runs under its last owner's groups. A
    // project without groups sends nothing unless it clears a table an earlier one had.
    if (!p.vcaGroups.empty() || ctlVca_) {
        Cmd vc;
        vc.type = Cmd::SetVca;
        vc.vca = makeVcaTable(p, [&](const std::string& id) {
            if (id.empty() || id[0] == '\x01') return -1;
            auto it = slotByLayer.find(id);
            return it == slotByLayer.end() ? -1 : it->second;
        }, ctlVca_).release();
        VcaTable* sent = vc.vca;
        if (send(vc)) {  // send() frees the table if the queue rejects the command
            ctlVca_ = sent;
        } else {
            allOk = false;
            warnings["project"].push_back("audio command queue rejected the VCA groups update");
        }
    }

    // Pass 2: send what changed, and order layers so buses run after their children.
    std::vector<int> projectOrder;
    for (Planned& pl : plan) {
        LayerState& ls = pl.ls;
        const Want& w = pl.w;
        ls.arrangementSig = pl.arrangementSig;
        for (const AutomationLaneSpec& lane : w.automation) {
            pl.automationSig += lane.target + "|";
            for (const AutomationPointSpec& point : lane.points)
                pl.automationSig += std::to_string(point.step) + ":" + std::to_string(point.value) + ":" +
                                    std::to_string(point.curve) + ":" + std::to_string(doubleToBits(point.tension)) + ";";
        }
        if (w.vol != ls.volume || w.pan != ls.pan || w.mute != ls.mute || w.solo != ls.solo) {
            writeMix(ls.slot, w.vol, w.pan, w.mute, w.solo);
            ls.volume = w.vol;
            ls.pan = w.pan;
            ls.mute = w.mute;
            ls.solo = w.solo;
        }
        // A layer's native inserts: a new chain (crossfaded in), none, or new values for the one it keeps.
        auto syncInserts = [&]() {
            const bool wantsInserts = w.components && !w.components->empty();
            auto made = nextInserts.find(w.id);
            if (made != nextInserts.end() || (!wantsInserts && ls.inserts)) {
                Cmd inserts;
                inserts.type = Cmd::SetInserts;
                inserts.slot = ls.slot;
                ComponentChain* sent = made != nextInserts.end() ? made->second.release() : nullptr;
                if (sent) attachAutomation(*sent, w.id);
                if (sent) sent->setArmed(w.armed);
                inserts.masterChain = sent;
                if (send(inserts)) {
                    ls.inserts = sent;
                    ls.insertsAutomationKey = ComponentChain::automationKey(p.automation, w.id);
                } else {
                    allOk = false;
                    warnings["project"].push_back("layer '" + w.id + "': audio command queue rejected its native component update");
                }
            } else if (wantsInserts && ls.inserts) {
                ls.inserts->setValues(*w.components);
                updateAutomation(ls.slot, *ls.inserts, w.id, ls.insertsAutomationKey);
                ls.inserts->setArmed(w.armed);  // updateCompensation below follows its latency
            }
        };
        if (!w.bus) {
            syncInserts();
            auto madeInstrument = nextInstruments.find(w.id);
            if ((pl.track && madeInstrument != nextInstruments.end()) || (!pl.track && ls.instrument)) {
                Cmd instrument;
                instrument.type = Cmd::SetInstrument;
                instrument.slot = ls.slot;
                ComponentChain* sent = pl.track ? madeInstrument->second.release() : nullptr;
                if (sent) attachAutomation(*sent, w.id);
                instrument.masterChain = sent;
                if (send(instrument)) {
                    ls.instrument = sent;
                    ls.instrumentAutomationKey = ComponentChain::automationKey(p.automation, w.id, "instrument");
                } else {
                    allOk = false;
                    warnings["project"].push_back("layer '" + w.id + "': audio command queue rejected its native instrument update");
                }
            } else if (pl.track && ls.instrument) {
                ls.instrument->setValues(instrumentSpecs(*w.instrument, w.midi));
                updateAutomation(ls.slot, *ls.instrument, w.id, ls.instrumentAutomationKey);
            }
            // A MIDI-out layer (API 47): its lane (made once per slot, kept while the Engine lives) and settings.
            const bool wantsMidi = pl.track && w.midiOut;
            if (wantsMidi ? (!ls.midiOut || ls.midiSpec != *w.midiOut) : ls.midiOut) {
                Cmd midi;
                midi.type = Cmd::SetMidiOut;
                midi.slot = ls.slot;
                if (wantsMidi) {
                    std::unique_ptr<MidiOutLane>& lane = ctlMidiLanes_[ls.slot];
                    if (!lane) lane = std::make_unique<MidiOutLane>();
                    midi.midiLane = lane.get();
                    midi.midiSpec = *w.midiOut;
                }
                if (send(midi)) {
                    ls.midiOut = wantsMidi;
                    if (wantsMidi) ls.midiSpec = *w.midiOut;
                } else {
                    allOk = false;
                    warnings["project"].push_back("layer '" + w.id + "': audio command queue rejected its MIDI out");
                }
            }
        }
        if (w.bus) {
            Cmd bus;
            bus.type = Cmd::ConfigureBus;
            bus.slot = ls.slot;
            bus.parentSlot = pl.ls.parentSlot;
            bus.order = w.order;
            const bool newBus = !ls.bus;
            bus.flag = newBus;
            if (newBus) ls.automationSig = "\\x01new-slot";
            if (!send(bus)) {
                allOk = false;
                warnings[w.id].push_back("audio command queue rejected folder-bus configuration");
                nextLayers[w.id] = ls;
                continue;
            }
            if (newBus) {  // the slot dropped what it had as a track (its chain, inserts, instrument and delay)
                ls.inserts = nullptr;
                ls.instrument = nullptr;
                ls.midiOut = false;
                ls.compensation = 0;
            }
            ls.bus = true;
            syncInserts();  // after ConfigureBus, so a new bus keeps them
            ls.parentSlot = pl.ls.parentSlot;
            if (ls.automationSig != pl.automationSig) {
                Cmd automation;
                automation.type = Cmd::SetAutomation;
                automation.slot = ls.slot;
                automation.flag = newBus;
                auto* data = new AutomationData();
                for (const AutomationLaneSpec& lane : w.automation) {
                    auto& points = lane.target == "volume" ? data->volume : data->pan;
                    points.insert(points.end(), lane.points.begin(), lane.points.end());
                }
                if (data->volume.empty() && data->pan.empty()) delete data;
                else automation.automation = data;
                if (send(automation)) ls.automationSig = pl.automationSig;
                else {
                    allOk = false;
                    warnings[w.id].push_back("audio command queue rejected folder automation update");
                    nextLayers[w.id] = ls;
                    continue;
                }
            }
            ls.track = false;
            ls.pattern.reset();
            ls.steps = 0;
            projectOrder.push_back(ls.slot);
            nextLayers[w.id] = ls;
            continue;
        }
        if (ls.bus) ls.automationSig = "\\x01new-slot";
        if (ls.automationSig != pl.automationSig) {
            Cmd automation; automation.type = Cmd::SetAutomation; automation.slot = ls.slot;
            auto* data = new AutomationData();
            for (const AutomationLaneSpec& lane : w.automation) {
                auto& points = lane.target == "volume" ? data->volume : data->pan;
                points.insert(points.end(), lane.points.begin(), lane.points.end());
            }
            if (data->volume.empty() && data->pan.empty()) delete data;
            else automation.automation = data;
            if (send(automation)) ls.automationSig = pl.automationSig;
            else {
                allOk = false;
                warnings[w.id].push_back("audio command queue rejected layer automation update");
                nextLayers[w.id] = ls;
                continue;
            }
        }
        {
            Cmd routing;
            routing.type = Cmd::SetRouting;
            routing.slot = ls.slot;
            routing.parentSlot = pl.ls.parentSlot;
            if (!send(routing)) {
                allOk = false;
                warnings[w.id].push_back("audio command queue rejected track routing update");
                nextLayers[w.id] = ls;
                continue;
            }
            ls.bus = false;
            ls.parentSlot = pl.ls.parentSlot;
        }
        if (!ls.track) {
            Cmd cmd;
            cmd.type = Cmd::Install;
            cmd.slot = ls.slot;
            cmd.steps = w.steps;
            cmd.order = w.order;
            if (!send(cmd)) {
                allOk = false;
                warnings[w.id].push_back("audio command queue rejected the track");
                nextLayers[w.id] = ls;
                continue;
            }
            ls.track = true;
            ls.steps = w.steps;
        } else {
            if (w.steps != ls.steps) {
                Cmd cmd;
                cmd.type = Cmd::SetSteps;
                cmd.slot = ls.slot;
                cmd.steps = w.steps;
                if (!send(cmd)) {
                    allOk = false;
                    warnings[w.id].push_back("audio command queue rejected layer-length update");
                    nextLayers[w.id] = ls;
                    continue;
                }
                ls.steps = w.steps;
            }
        }
        if (pl.pattern != ls.pattern) {
            Cmd cmd;
            cmd.type = Cmd::SetPattern;
            cmd.slot = ls.slot;
            cmd.pattern = pl.pattern ? new std::shared_ptr<const Pattern>(pl.pattern) : nullptr;
            // Which new note carries on each old one, so held notes follow the edit (worked out here, off the
            // audio thread; send() frees it if the queue rejects the command).
            if (pl.pattern && ls.pattern)
                cmd.orderList = new std::vector<int>(matchPatternNotes(*ls.pattern, *pl.pattern));
            if (!send(cmd)) {
                allOk = false;
                warnings[w.id].push_back("audio command queue rejected pattern update");
                nextLayers[w.id] = ls;
                continue;
            }
            ls.pattern = pl.pattern;
        }
        projectOrder.push_back(ls.slot);
        nextLayers[w.id] = ls;
    }
    // Layers that disappeared fade out and free their slot.
    for (auto& [id, ls] : layers_) {
        if (ls.slot < 0) continue;
        Cmd c;
        c.type = Cmd::Remove;
        c.slot = ls.slot;
        if (!send(c)) {
            allOk = false;
            warnings[id].push_back("audio command queue rejected layer removal");
            nextLayers[id] = ls;
        }
    }
    layers_ = std::move(nextLayers);

    // Routes: each layer's sends (in project order, so a send's index stays its index), then the sidechain keys
    // it feeds. updateCompensation sends them with their delays.
    for (auto& [id, ls] : layers_) {
        ls.routes.clear();
        ls.userSends = 0;
    }
    for (const LayerSpec& l : p.layers) {
        auto it = layers_.find(l.id);
        if (it == layers_.end() || it->second.slot < 0) continue;
        LayerState& ls = it->second;
        for (const SendSpec& send : l.sends) {
            LayerState::Route r;
            auto to = layers_.find(send.to);
            // Into a bus's input, or a track's (after its instrument, before its inserts); a feedback send may
            // come back to its own layer.
            if (to != layers_.end() && to->second.slot >= 0 && (to->second.bus || to->second.track) &&
                (to->second.slot != ls.slot || send.feedback))
                r.dest = to->second.slot;
            else warnings["project"].push_back("layer '" + l.id + "': send to '" + send.to + "': that bus or track isn't playing, so the send is silent");
            r.level = send.level;
            r.pre = send.pre;
            r.mute = send.mute;
            r.feedback = send.feedback;
            r.limiter = send.limiter;
            ls.routes.push_back(r);
        }
        ls.userSends = static_cast<int>(ls.routes.size());
    }
    for (const LayerSpec& l : p.layers) {
        auto it = layers_.find(l.id);
        if (it == layers_.end() || it->second.slot < 0) continue;
        for (size_t i = 0; i < l.components.size(); ++i) {
            const ComponentSpec& c = l.components[i];
            if (!c.hasKey) continue;
            if (!it->second.inserts || !it->second.inserts->keyed(i)) {
                warnings["project"].push_back("layer '" + l.id + "': component '" + c.id + "' has no sidechain input, so its key is ignored");
                continue;
            }
            auto from = layers_.find(c.key.layer);
            if (from == layers_.end() || from->second.slot < 0) {
                warnings["project"].push_back("layer '" + l.id + "': component '" + c.id + "': its key '" + c.key.layer + "' isn't playing");
                continue;
            }
            if (from->second.routes.size() >= static_cast<size_t>(ctlTable_->graph->routesPerSlot)) {  // never: sized above
                warnings["project"].push_back("layer '" + c.key.layer + "' keys more components than its routes hold; the rest hear no key");
                continue;
            }
            LayerState::Route r;
            r.dest = it->second.slot;
            r.key = static_cast<int>(i);
            r.level = c.key.level;
            r.pre = c.key.pre;
            from->second.routes.push_back(r);
        }
    }

    if (!updateCompensation(warnings)) allOk = false;

    // Dependency order: repeatedly take the first layer (in project order) whose children are all placed (a bus
    // after the tracks and buses in it). validateRouting refuses loops, so every layer is placed; the audio
    // thread's routing (updateRouting) then also runs each send's and key's source before its destination.
    {
        Cmd oc;
        oc.type = Cmd::SetOrder;
        auto orderList = std::make_unique<std::vector<int>>();
        orderList->reserve(static_cast<size_t>(slotCount));
        std::vector<bool> placed(static_cast<size_t>(slotCount), false);
        bool progress = true;
        while (progress) {
            progress = false;
            for (int slot : projectOrder) {
                if (placed[slot]) continue;
                bool ready = true;
                for (int src : readsFrom[slot])
                    if (!placed[src] && std::find(projectOrder.begin(), projectOrder.end(), src) != projectOrder.end())
                        ready = false;
                if (!ready) continue;
                placed[slot] = true;
                orderList->push_back(slot);
                progress = true;
            }
        }
        for (int slot : projectOrder)
            if (!placed[slot]) orderList->push_back(slot);  // never expected: kept playing in project order
        oc.orderList = orderList.release();  // send() frees it if the queue rejects the command
        if (!send(oc)) {
            allOk = false;
            warnings["project"].push_back("audio command queue rejected project layer ordering");
        }
    }

    Cmd a;
    a.type = Cmd::AuditionOnly;
    a.flag = p.auditionOnly;
    if (!send(a)) {
        allOk = false;
        warnings["project"].push_back("audio command queue rejected audition mode update");
    }

    if (keepMasterChain) {
        ctlMasterChain_->setValues(p.masterComponents);
        updateAutomation(-1, *ctlMasterChain_, "", ctlMasterAutomationKey_);
    } else if (nextMasterChain || ctlMasterChain_) {
        Cmd masterChainCommand;
        masterChainCommand.type = Cmd::SetMasterChain;
        ComponentChain* sent = nextMasterChain.release();
        if (sent) attachAutomation(*sent, "");
        masterChainCommand.masterChain = sent;
        if (send(masterChainCommand)) {
            ctlMasterChain_ = sent;
            ctlMasterAutomationKey_ = ComponentChain::automationKey(p.automation, "");
        } else {
            allOk = false;
            warnings["project"].push_back("audio command queue rejected native master-chain update");
        }
    }

    // Per-note FX (#127): its own plan, swapped in lock-free at the next chunk, as modulation's.
    noteFx_->commit(p, [&](const std::string& id) {
        auto it = layers_.find(id);
        return it == layers_.end() || it->second.bus ? -1 : it->second.slot;
    }, ctlAutomation_, warnings["project"]);
    // Project modulation (#161, modulation_links.cpp): its own plan, swapped in lock-free at the next chunk.
    {
        std::vector<std::string>& w = warnings["project"];
        const std::string modError = modulation_->update(nativeModules_, p, sr_, [&](const std::string& id) {
            ModulationHost::LayerInfo info;
            if (id.empty()) {
                info.inserts = ctlMasterChain_;
                return info;
            }
            auto it = layers_.find(id);
            if (it == layers_.end()) return info;
            info.slot = it->second.slot;
            info.bus = it->second.bus;
            info.sends = it->second.userSends;
            info.inserts = it->second.inserts;
            info.instrument = it->second.instrument;
            info.noteFx = noteFx_->chainFor(id);
            return info;
        }, w);
        if (!modError.empty()) {
            allOk = false;
            w.push_back(modError);
        }
    }

    std::string mods;
    for (const ModuleSpec& m : p.modules) {
        const ModuleState& st = modules_.at(m.id);
        if (!mods.empty()) mods += ",";
        mods += "\"" + jsonEscape(m.id) + "\":{\"ok\":" + (st.error.empty() ? "true" : "false");
        if (!st.error.empty())
            mods += ",\"error\":\"" + jsonEscape(st.error) + "\",\"line\":" + std::to_string(st.line) +
                    ",\"col\":" + std::to_string(st.col);
        if (st.pattern) mods += "," + describePattern(*st.pattern);
        else mods += ",\"kind\":\"pattern\"";
        mods += ",\"warnings\":[";
        auto wit = warnings.find(m.id);
        if (wit != warnings.end()) {
            std::sort(wit->second.begin(), wit->second.end());
            wit->second.erase(std::unique(wit->second.begin(), wit->second.end()), wit->second.end());
            for (size_t i = 0; i < wit->second.size(); ++i)
                mods += (i ? ",\"" : "\"") + jsonEscape(wit->second[i]) + "\"";
        }
        mods += "]}";
    }
    std::string projectWarnings;
    auto projectWarningIt = warnings.find("project");
    if (projectWarningIt != warnings.end()) {
        auto& messages = projectWarningIt->second;
        std::sort(messages.begin(), messages.end());
        messages.erase(std::unique(messages.begin(), messages.end()), messages.end());
        for (size_t i = 0; i < messages.size(); ++i)
            projectWarnings += (i ? ",\"" : "\"") + jsonEscape(messages[i]) + "\"";
    }
    return std::string("{\"ok\":") + (allOk ? "true" : "false") +
           ",\"modules\":{" + mods + "},\"warnings\":{\"project\":[" + projectWarnings + "]}}";
}

ComponentChain* Engine::ctlComponentChain(const std::string& layerId, uint32_t& index) noexcept {
    const bool midi = index != kInstrumentIndex && (index & kMidiComponentFlag) && !(index & kNoteComponentFlag);
    const bool instrument = index == kInstrumentIndex || midi;
    if (midi) index = 1 + (index & ~kMidiComponentFlag);  // its MIDI effects follow the instrument in its chain
    else if (instrument) index = 0;
    if (layerId.empty()) return instrument ? nullptr : ctlMasterChain_;
    auto it = layers_.find(layerId);
    if (it == layers_.end()) return nullptr;
    return instrument ? it->second.instrument : it->second.inserts;
}

// Latency compensation: each track is delayed so it lines up with the track whose native effects add the most
// latency (the master chain delays everything alike, so it needs none). Control thread, under ctl_.
bool Engine::updateCompensation(std::map<std::string, std::vector<std::string>>& warnings) {
    bool ok = true;
    // Plugin delay compensation over the whole routing: a slot's own latency is its instrument's and inserts';
    // a bus's input arrives at the latest of what feeds it (children, outputs routed to it and sends), and every
    // route into a bus (or the master) is delayed by how much earlier it arrives, so everything that meets is in
    // time. A send into a track meets that track's instrument: it is delayed to the instrument's latency when it
    // is earlier, and stays late (with a warning) when it is later. Keys and feedback sends are not delayed: keys
    // arrive as early as they can (a ducker's look-ahead covers a late one), and a feedback send is a chunk late
    // by design.
    struct Node {
        LayerState* ls = nullptr;
        const std::string* id = nullptr;
        int64_t own = 0, in = 0, raw = 0;
        int64_t inst = 0;  // a track's instrument latency: where sends into it meet it
        int indegree = 0;
        std::vector<int> out;  // slots it feeds (its output bus, its sends' buses)
    };
    std::map<int, Node> nodes;
    for (auto& [id, ls] : layers_) {
        if (ls.slot < 0) continue;
        Node& n = nodes[ls.slot];
        n.ls = &ls;
        n.id = &id;
        uint64_t frames = 0;
        if (ls.instrument && !ls.bus) frames += ls.instrument->latencyFrames() + noteFx_->latencyFrames(id);
        n.inst = static_cast<int64_t>(std::min<uint64_t>(frames, 1u << 30));
        if (ls.inserts) frames += ls.inserts->latencyFrames();
        n.own = static_cast<int64_t>(std::min<uint64_t>(frames, 1u << 30));
    }
    auto trackAt = [&](int slot) -> Node* {
        auto it = nodes.find(slot);
        return it != nodes.end() && !it->second.ls->bus ? &it->second : nullptr;
    };
    auto busAt = [&](int slot) -> Node* {
        auto it = nodes.find(slot);
        return it != nodes.end() && it->second.ls->bus ? &it->second : nullptr;
    };
    for (auto& [slot, n] : nodes) {
        if (Node* parent = busAt(n.ls->parentSlot); parent && n.ls->parentSlot != slot) n.out.push_back(n.ls->parentSlot);
        for (const LayerState::Route& r : n.ls->routes)
            if (r.key < 0 && !r.feedback && busAt(r.dest) && r.dest != slot) n.out.push_back(r.dest);
        for (int to : n.out) ++nodes[to].indegree;
    }
    // Kahn's order (routing loops are refused before here; any left over go last).
    std::vector<int> order, ready;
    for (auto& [slot, n] : nodes)
        if (n.indegree == 0) ready.push_back(slot);
    while (!ready.empty()) {
        const int x = ready.back();
        ready.pop_back();
        order.push_back(x);
        for (int to : nodes[x].out)
            if (--nodes[to].indegree == 0) ready.push_back(to);
    }
    if (order.size() < nodes.size())
        for (auto& [slot, n] : nodes)
            if (n.indegree > 0) order.push_back(slot);
    int64_t masterIn = 0;
    for (int x : order) {
        Node& n = nodes[x];
        n.raw = n.in + n.own;
        bool toMaster = !busAt(n.ls->parentSlot) || n.ls->parentSlot == x;
        for (int to : n.out) nodes[to].in = std::max(nodes[to].in, n.raw);
        if (toMaster) masterIn = std::max(masterIn, n.raw);
    }
    // MIDI out (API 47): a layer with no latency of its own reaches the master after masterIn frames, then the
    // master chain's: what every MIDI-out time adds so the external sound lines up with the mix.
    midiOutDelayFrames_.store(masterIn + static_cast<int64_t>(std::min<uint64_t>(
                                             ctlMasterChain_ ? ctlMasterChain_->latencyFrames() : 0, 1u << 30)),
                              std::memory_order_relaxed);
    bool capped = false;
    auto delayTo = [&](const Node& from, int64_t arrival) {
        const int64_t d = arrival - from.raw;
        if (d > kMaxCompensationFrames) capped = true;
        return std::clamp<int64_t>(d, 0, kMaxCompensationFrames);
    };
    auto makeDelay = [](int64_t frames) -> DelayLine* {
        if (frames <= 0) return nullptr;
        auto* d = new DelayLine();
        d->l.assign(static_cast<size_t>(frames), 0.0f);
        d->r.assign(static_cast<size_t>(frames), 0.0f);
        return d;
    };
    for (int x : order) {
        Node& n = nodes[x];
        LayerState& ls = *n.ls;
        const Node* parent = busAt(ls.parentSlot);
        const int64_t want = delayTo(n, parent && ls.parentSlot != x ? parent->in : masterIn);
        if (want != ls.compensation) {
            Cmd d;
            d.type = Cmd::SetDelay;
            d.slot = ls.slot;
            d.delay = makeDelay(want);
            if (send(d)) {
                ls.compensation = want;
            } else {
                ok = false;
                warnings["project"].push_back("layer '" + *n.id + "': audio command queue rejected its latency compensation");
            }
        }
        // The routes: a new table when a destination or a delay changed, else just the levels that moved.
        std::vector<int64_t> delays;
        std::string sig;
        for (const LayerState::Route& r : ls.routes) {
            const Node* to = r.key < 0 && !r.feedback ? busAt(r.dest) : nullptr;
            const Node* track = r.key < 0 && !r.feedback && r.dest != x ? trackAt(r.dest) : nullptr;
            delays.push_back(to ? delayTo(n, to->in) : track ? delayTo(n, track->inst) : 0);
            if (track && n.raw > track->inst)
                warnings["project"].push_back("layer '" + *n.id + "': its send into track '" + *track->id + "' arrives " +
                                              std::to_string(n.raw - track->inst) +
                                              " frames after that track's instrument (its latency isn't compensated there)");
            // A feedback send's DC block is tuned to the rate: a new rate rebuilds its table.
            sig += std::to_string(r.dest) + ":" + std::to_string(r.key) + ":" + std::to_string(delays.back()) +
                   (r.feedback ? (r.limiter ? ":f" : ":F") + std::to_string(ctlSr_) : "") + ";";
        }
        if (sig != ls.routesSig) {
            Cmd c;
            c.type = Cmd::SetSends;
            c.slot = ls.slot;
            if (!ls.routes.empty()) {
                c.sends = new SendTable(static_cast<int>(ls.routes.size()));
                for (size_t k = 0; k < ls.routes.size(); ++k) {
                    const LayerState::Route& r = ls.routes[k];
                    SendTable::Route& t = c.sends->routes[k];
                    t.dest = r.dest;
                    t.key = r.key;
                    t.level = r.level;
                    t.pre = t.tapPre = r.pre;
                    t.mute = r.mute;
                    t.delay = makeDelay(delays[k]);
                    if (r.feedback && r.key < 0) {
                        t.feedback = true;
                        t.ring = new FeedbackRing();
                        t.ring->limiter = r.limiter;
                        // The DC block's pole: about 10 Hz at this rate.
                        t.ring->pole = std::exp(-2.0 * 3.14159265358979323846 * 10.0 / (ctlSr_ > 0 ? ctlSr_ : 48000.0));
                    }
                    c.sends->keys = c.sends->keys || (r.key >= 0 && r.dest >= 0);
                }
            }
            if (send(c)) {
                ls.routesSig = sig;
                ls.routesSent = ls.routes;
            } else {
                ok = false;
                warnings["project"].push_back("layer '" + *n.id + "': audio command queue rejected its sends");
            }
            continue;
        }
        for (size_t k = 0; k < ls.routes.size() && k < ls.routesSent.size(); ++k) {
            const LayerState::Route& r = ls.routes[k];
            LayerState::Route& was = ls.routesSent[k];
            if (r.level == was.level && r.pre == was.pre && r.mute == was.mute) continue;
            Cmd c;
            c.type = Cmd::SetSendLevel;
            c.slot = ls.slot;
            c.order = static_cast<int>(k);
            c.master = r.level;
            c.flag = r.pre;
            c.sendMute = r.mute;
            if (send(c)) was = r;
            else {
                ok = false;
                warnings["project"].push_back("layer '" + *n.id + "': audio command queue rejected a send level");
            }
        }
    }
    if (capped)
        warnings["project"].push_back("native effects add more latency than the " + std::to_string(kMaxCompensationFrames) +
                                      " frames tracks are kept in time over");
    return ok;
}

}  // namespace caw
