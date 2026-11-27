// DrumsProcessor's control grid and block render, the Acoustic kit, the voice bus and the display (hand-written; included by builtin_drums.cpp, not compiled alone).
    // ---------- The control grid and the block ----------

    void control(const ProcessBlock& b, uint32_t at) noexcept {
        prune();
        uint64_t updated = 0;  // pads whose settings were read this control
        for (uint32_t i = 0; i < live_; ++i) {
            DrumVoice& v = voices_[list_[i]];
            const uint32_t pad = static_cast<uint32_t>(v.pad);
            const uint64_t bit = 1ull << pad;
            if (!(updated & bit)) {
                readPad(b, pad, at, settings_[pad], blockCount_);
                updated |= bit;
            }
            if (v.res) v.ringing = v.exciteLeft > 0 || v.modal.ringing();
            const bool done = !v.sounding() || (v.fading && v.fadeGain < 1e-4) || (v.releasing && v.relGain < 1e-4) ||
                              v.dampGain < 1e-4;
            if (done) {
                v.active = false;
                continue;
            }
            v.physPeak = 0.0;  // the waveguide's loudest since this control: it ends once that is below -94 dB
            coefficients(v, settings_[pad], false);
        }
        prune();
        // 1.1.2: the Acoustic kit's settings while it rings, and the hi-hat pedal (CC 4) always: closing it can
        // sound the hat on its own (the chick).
        const double pedal = parameterAt(b, acouParam(kAcouHatPedal), at, 1.0);
        if (pedal != lastPedal_) {
            const bool first = lastPedal_ < 0.0;
            lastPedal_ = pedal;
            if (!first || acoustic_.awake()) {
                readAcousticKit(b, at);
                for (uint32_t pc = 0; pc < kPieces; ++pc)
                    if (clampi(parameterAt(b, pieceParam(pc, kPcKind), at, 0), 0, kPieceKindCount - 1) == kPieceHiHat) {
                        readPiece(b, pc, at);
                        if (acoustic_.wakeHat(pc) && settled_) settled_ = false;
                    }
            }
        }
        if (acoustic_.awake()) {
            acoustic_.endCell();  // the last 16 frames' glide, clamping, waking and sleeping
            // The knobs move between blocks (or ramp within one): read once a block unless one ramps.
            if (acousticRead_ != blockCount_ || acousticRamps_) {
                acousticRead_ = blockCount_;
                acousticRamps_ = false;
                readAcousticKit(b, at);
                for (uint32_t pc = 0; pc < kPieces; ++pc)
                    if (acoustic_.piece(pc).awake) readPiece(b, pc, at);
            }
        }
        // Kit effects' knobs.
        glueAmount_ = clampd(parameterAt(b, kGlue, at, 0), 0, 1);
        if (glueAmount_ > 0.0) {
            glueThr_ = clampd(parameterAt(b, kGlueThreshold, at, -12), -40, 0);
            glueRatio_ = clampd(parameterAt(b, kGlueRatio, at, 4), 1, 20);
            glueMakeup_ = lib::dbToGain(clampd(parameterAt(b, kGlueMakeup, at, 0), 0, 24));
            glue_.setCoefficients(lib::timeCoefficient(clampd(parameterAt(b, kGlueAttack, at, 10), 0.1, 100) * 0.001, sr_),
                                  lib::timeCoefficient(clampd(parameterAt(b, kGlueRelease, at, 120), 10, 1000) * 0.001, sr_));
        }
        kitDriveType_ = clampi(parameterAt(b, kKitDriveType, at, 0), 0, 4);
        if (kitDriveType_ != 0) {
            static constexpr int kMap[] = {kDriveOff, kDriveSoft, kDriveTube, kDriveHard, kDriveCrush};
            const double amount = parameterAt(b, kKitDrive, at, 2);
            kitDriveL_.set(kMap[kitDriveType_], amount);
            kitDriveR_.set(kMap[kitDriveType_], amount);
            kitDriveMix_ = clampd(parameterAt(b, kKitDriveMix, at, 1), 0, 1);
        }
        const double room = clampd(parameterAt(b, kRoom, at, 0), 0, 1);
        if (room > 0.0) {
            lib::ReverbSettings r;
            r.size = clampd(parameterAt(b, kRoomSize, at, 0.35), 0, 1);
            r.decay = clampd(parameterAt(b, kRoomDecay, at, 0.8), 0.1, 10);
            r.damping = clampd(parameterAt(b, kRoomDamping, at, 0.5), 0, 1);
            r.mix = 1.0;  // wet only: it is a send's return
            r.width = 1.0;
            r.preDelay = clampd(parameterAt(b, kRoomPredelay, at, 0), 0, 100) * 0.001;
            const lib::ReverbSettings& was = room_.settings();
            if (!roomOn_ || r.size != was.size || r.decay != was.decay || r.damping != was.damping ||
                r.preDelay != was.preDelay)
                room_.set(r);
            room_.setLight(qualityNow(quality_) == kQualityEco);
            roomOn_ = true;
        } else if (roomOn_) {
            room_.clear();  // turned off: its tail stops
            roomOn_ = false;
        }
        roomMix_ = room;
        // The echo (1.1.0): a send bus as the room is; its time free or a note value at the transport's tempo.
        const double echo = clampd(parameterAt(b, kEcho, at, 0), 0, 1);
        if (echo > 0.0 && !echoL_.empty()) {
            const int sync = clampi(parameterAt(b, kEchoSync, at, kEcho8Dotted), 0, kEcho8Triplet);
            static constexpr double kBeats[] = {0.0, 0.25, 0.5, 0.75, 1.0, 1.0 / 3.0};
            const double tempo = b.transport && b.transport->tempo > 0.0 ? clampd(b.transport->tempo, 20, 999) : 120.0;
            const double seconds = sync == kEchoFree ? clampd(parameterAt(b, kEchoTime, at, 0.375), 0.01, 2)
                                                     : kBeats[sync] * 60.0 / tempo;
            echoTarget_ = clampd(seconds * sr_, 1.0, static_cast<double>(echoL_.size()) - 4.0);
            if (!echoOn_) echoDelay_ = echoTarget_;
            echoFb_ = clampd(parameterAt(b, kEchoFeedback, at, 0.35), 0, 0.95);
            echoSpread_ = clampd(parameterAt(b, kEchoSpread, at, 0.6), 0, 1);
            const double tone = clampd(parameterAt(b, kEchoTone, at, 5000), 500, std::min(16000.0, 0.45 * sr_));
            echoK_ = 1.0 - lib::fastExp(-kTwoPi * tone / sr_);
            echoOn_ = true;
        } else if (echoOn_) {
            clearEcho();  // turned off: its tail stops
        }
        echoMix_ = echo;
        // Nothing sounding and the room's tail below -100 dB for half a second: every state goes to exact zero and
        // the instrument says it is quiet (the host may skip it until the next note).
        if (live_ == 0 && !settled_ && !acoustic_.awake() && (!roomOn_ || roomQuiet_ >= static_cast<uint32_t>(sr_ * 0.5)) &&
            (!echoOn_ || echoQuiet_ >= static_cast<uint32_t>(sr_ * 0.5)) && pending_ == 0) {
            glue_.clear();
            kitDriveL_.clear();
            kitDriveR_.clear();
            if (roomOn_) room_.clear();
            if (echoOn_) clearEcho(), echoOn_ = true;
            settled_ = true;
        }
        volume_ = dbGain(parameterAt(b, kVolume, at, 0));
        const double low = clampd(parameterAt(b, kKitLow, at, 0), -12, 12), high = clampd(parameterAt(b, kKitHigh, at, 0), -12, 12);
        kitEq_ = low != 0.0 || high != 0.0;
        if (kitEq_ && (low != kitLowDb_ || high != kitHighDb_)) {
            kitLowDb_ = low;
            kitHighDb_ = high;
            kitLowL_.set(lib::EqBand::Kind::LowShelf, 100.0, low, 0.70710678118654752, sr_);
            kitLowR_.set(lib::EqBand::Kind::LowShelf, 100.0, low, 0.70710678118654752, sr_);
            kitHighL_.set(lib::EqBand::Kind::HighShelf, std::min(8000.0, 0.4 * sr_), high, 0.70710678118654752, sr_);
            kitHighR_.set(lib::EqBand::Kind::HighShelf, std::min(8000.0, 0.4 * sr_), high, 0.70710678118654752, sr_);
        }
        kitClip_ = clampi(parameterAt(b, kKitClip, at, 0), 0, kClipHard);
        if (kitClip_ != 0) {
            const double g = lib::dbToGain(clampd(parameterAt(b, kKitClipGain, at, 0), 0, 24));
            const int type = kitClip_ == kClipSoft ? kDriveClipSoft : kDriveHard;
            kitClipL_.set(type, g);
            kitClipR_.set(type, g);
        }
    }

    // One chunk (n <= kControlFrames frames), `at` its first frame in the block.
    void renderChunk(float* left, float* right, uint32_t n, uint32_t at) noexcept {
        double busL[kOutputs][kControlFrames], busR[kOutputs][kControlFrames], send[kControlFrames];
        double laneL[kControlFrames], laneR[kControlFrames];  // a hit with a voice-bus lane (#127), before the lane
        // 1.1.0: the echo's send, and what skips the kit bus (glue and kit drive: each pad's 1 - bus_send)
        double echoIn[kControlFrames], skipL[kControlFrames], skipR[kControlFrames];
        bool skipping = false;
        uint32_t used = 1;  // buses 0..used-1 written
        for (uint32_t i = 0; i < n; ++i) busL[0][i] = busR[0][i] = send[i] = echoIn[i] = skipL[i] = skipR[i] = 0.0;
        if (lanes_.any()) lanes_.begin(at, n);
        for (uint32_t i = 0; i < live_; ++i) {
            DrumVoice& v = voices_[list_[i]];
            if (!v.active) continue;
            const uint32_t pad = static_cast<uint32_t>(v.pad);
            const uint32_t out = static_cast<uint32_t>(settings_[pad].out);
            while (used <= out) {
                for (uint32_t k = 0; k < n; ++k) busL[used][k] = busR[used][k] = 0.0;
                ++used;
            }
            // A hit whose note has a lane: the same sums into laneL/R, then into the lane (summed back into its
            // output below, after the host's per-note FX). Its room send stays dry.
            // The overflow lane (kLaneRest) takes only hits on the main output: one lane can't sum into two.
            VoiceLane* lane = lanes_.any() ? lanes_.laneFor(v.noteId, out == 0) : nullptr;
            double* dl = busL[out];
            double* dr = busR[out];
            if (lane) {
                for (uint32_t k = 0; k < n; ++k) laneL[k] = laneR[k] = 0.0;
                dl = laneL, dr = laneR;
                if (!(lane->flags & kLaneRest)) laneOut(v.noteId, out);
            }
            float peak = padLevel_[pad];
            const bool toRoom = roomOn_ && v.roomSend > 0.0;
            const bool toEcho = echoOn_ && v.echoSend > 0.0;
            const bool skip = v.busSend < 1.0 && out == 0 && !lane;
            if (!toRoom && !v.sub && !v.wide && !toEcho && !skip) {  // the plain voice: mono, panned, no send
                for (uint32_t k = 0; k < n; ++k) {
                    const double y = voiceSample(v);
                    dl[k] += y * v.gainL;
                    dr[k] += y * v.gainR;
                    const float a = static_cast<float>(y < 0.0 ? -y : y);
                    if (a > peak) peak = a;
                    if (v.capture) captureSample(pad, static_cast<float>(y));
                }
                padLevel_[pad] = peak;
                if (lane) toLane(*lane, laneL, laneR, at, n);
                continue;
            }
            double* sl = skip ? skipL : dl;  // the share that skips the kit bus
            double* sr = skip ? skipR : dr;
            const double through = skip ? v.busSend : 1.0, past = 1.0 - v.busSend;
            skipping = skipping || skip;
            for (uint32_t k = 0; k < n; ++k) {
                const double y = voiceSample(v);
                // Pan the voice; a clean sub goes to both sides whole (mono), the side signal opposite ways.
                const double c = v.subOut * v.gainMid, w = v.wide ? v.side : 0.0;
                const double l = y * v.gainL + c + w, r = y * v.gainR + c - w;
                if (skip) {
                    dl[k] += l * through;
                    dr[k] += r * through;
                    sl[k] += l * past;
                    sr[k] += r * past;
                } else {
                    dl[k] += l;
                    dr[k] += r;
                }
                if (toRoom) send[k] += y * v.gainMid * v.roomSend;  // the room hears the voice, not its sub
                if (toEcho) echoIn[k] += y * v.gainMid * v.echoSend;
                const double all = y + v.subOut;
                const float a = static_cast<float>(all < 0.0 ? -all : all);
                if (a > peak) peak = a;
                if (v.capture) captureSample(pad, static_cast<float>(all));
            }
            padLevel_[pad] = peak;
            if (lane) toLane(*lane, laneL, laneR, at, n);
        }
        const bool quietKit = live_ == 0 && !acoustic_.awake();  // (the kit sleeps only at a control: see control())
        if (acoustic_.awake()) acoustic_.process(busL[0], busR[0], roomOn_ ? send : nullptr, n);  // 1.1.2: the kit's pieces
        if (lanes_.any()) {  // the host's per-note FX, then each lane into the output its hit plays to
            lanes_.run(at, n);
            for (uint32_t k = 0; k < lanes_.count(); ++k) {
                const VoiceLane& l = lanes_.lane(k);
                const uint32_t out = laneOutOf(l.noteId);
                while (used <= out) {
                    for (uint32_t j = 0; j < n; ++j) busL[used][j] = busR[used][j] = 0.0;
                    ++used;
                }
                for (uint32_t j = 0; j < n; ++j) {
                    busL[out][j] += l.channels[0][at + j];
                    busR[out][j] += l.channels[1][at + j];
                }
            }
        }
        // Kit effects on the main bus.
        for (uint32_t k = 0; k < n; ++k) {
            double l = busL[0][k], r = busR[0][k];
            if (glueAmount_ > 0.0) {
                const double a = std::max(l < 0.0 ? -l : l, r < 0.0 ? -r : r);
                const double gr = lib::compressorGainDb(lib::gainToDb(glue_.process(a)), glueThr_, glueRatio_, 6.0);
                glueGr_ = gr;
                const double g = lib::dbToGain(gr) * glueMakeup_;
                const double w = (g - 1.0) * glueAmount_ + 1.0;
                l *= w;
                r *= w;
            }
            if (kitDriveType_ != 0) {
                const int q = qualityNow(quality_);
                const int os = q == kQualityEco ? 1 : (q == kQualityHigh ? 4 : 2);
                l += (kitDriveL_.process(l, os) - l) * kitDriveMix_;
                r += (kitDriveR_.process(r, os) - r) * kitDriveMix_;
            }
            if (skipping) l += skipL[k], r += skipR[k];
            if (kitEq_) {
                l = kitHighL_.process(kitLowL_.process(l));
                r = kitHighR_.process(kitLowR_.process(r));
            }
            if (roomOn_) {  // the room: a send bus (each pad's room_send), its wet return added at `room`
                float wl = static_cast<float>(send[k]), wr = wl;
                room_.process(wl, wr);
                l += wl * roomMix_;
                r += wr * roomMix_;
                if (quietKit) roomQuiet_ = std::fabs(wl) + std::fabs(wr) < 1e-5f ? roomQuiet_ + 1 : 0;
            }
            if (echoOn_) {  // the echo: a stereo delay, its feedback low-passed and crossed by `spread` (ping-pong)
                double el, er;
                echo(echoIn[k], el, er);
                l += el * echoMix_;
                r += er * echoMix_;
                if (quietKit) echoQuiet_ = std::fabs(el) + std::fabs(er) < 1e-5 ? echoQuiet_ + 1 : 0;
            }
            if (kitClip_ != 0) {
                const int q = qualityNow(quality_);
                const int os = q == kQualityEco ? 1 : (q == kQualityHigh ? 4 : 2);
                l = ceiling(kitClipL_.process(l, os));
                r = ceiling(kitClipR_.process(r, os));
            }
            const float fl = static_cast<float>(l), fr = static_cast<float>(r);
            double outL = fl, outR = fr;
            for (uint32_t o = 1; o < used; ++o) {  // the other outputs: past the kit effects, into the one output
                outL += busL[o][k];
                outR += busR[o][k];
            }
            left[k] = static_cast<float>(outL * volume_);
            right[k] = static_cast<float>(outR * volume_);
        }
    }

    // ---------- The Acoustic kit (1.1.2) ----------

    double knob(const ProcessBlock& b, uint32_t index, uint32_t at) noexcept {
        if (b.parameters && index < b.parameterCount && b.parameters[index].samples) acousticRamps_ = true;
        return parameterAt(b, index, at, table_[index].defaultValue);
    }
    void readAcousticKit(const ProcessBlock& b, uint32_t at) noexcept {
        acoustic::KitSettings k;
        k.mics = clampi(knob(b, acouParam(kAcouMics), at), 0, kMicsOverheads);
        k.stick = clampi(knob(b, acouParam(kAcouStick), at), 0, kStickMallets);
        k.hatPedal = clampd(knob(b, acouParam(kAcouHatPedal), at), 0, 1);
        k.sympathy = clampd(knob(b, acouParam(kAcouSympathy), at), 0, 1);
        k.bleed = clampd(knob(b, acouParam(kAcouBleed), at), 0, 1);
        k.noise = clampd(knob(b, acouParam(kAcouNoise), at), 0, 1);
        k.level = clampd(knob(b, acouParam(kAcouLevel), at), -60, 12);
        k.room = clampd(knob(b, acouParam(kAcouRoom), at), 0, 1);
        acoustic_.setKit(k);
    }
    void readPiece(const ProcessBlock& b, uint32_t pc, uint32_t at) noexcept {
        acoustic::PieceSettings s;
        auto v = [&](uint32_t p) noexcept { return knob(b, pieceParam(pc, p), at); };
        s.kind = clampi(v(kPcKind), 0, kPieceKindCount - 1);
        s.size = clampd(v(kPcSize), 6, 26);
        s.depth = clampd(v(kPcDepth), 3, 22);
        s.tune = clampd(v(kPcTune), -24, 24);
        s.reso = clampd(v(kPcReso), -12, 12);
        s.head = clampi(v(kPcHead), 0, kHeadCalf);
        s.shell = clampi(v(kPcShell), 0, kShellAcrylic);
        s.damp = clampd(v(kPcDamp), 0, 1);
        s.decay = clampd(v(kPcDecay), 0.25, 4);
        s.glide = clampd(v(kPcGlide), 0, 1);
        s.wires = clampd(v(kPcWires), 0, 1);
        s.wireLevel = clampd(v(kPcWireLevel), -24, 12);
        s.beater = clampi(v(kPcBeater), 0, kBeaterFleece);
        s.port = clampi(v(kPcPort), 0, 1);
        s.air = clampd(v(kPcAir), 0, 1);
        s.alloy = clampi(v(kPcAlloy), 0, kAlloyDark);
        s.swell = clampd(v(kPcSwell), 0, 1);
        s.level = clampd(v(kPcLevel), -60, 12);
        s.pan = clampd(v(kPcPan), -1, 1);
        s.dist = clampd(v(kPcDist), 0.3, 2);
        s.shellLevel = clampd(v(kPcShellLevel), 0, 1);
        s.rec = clampd(v(kPcRec), 0, 1);
        acoustic_.setPiece(pc, s, qualityNow(quality_));
    }
    // A stroke on the pad's piece: the velocity as the pad's level and accent scale it, the strike position
    // varied per hit (rnd_pos) and the velocity (rnd_level), both seeded as the Layers pads' variation is.
    void strikePiece(uint32_t pad, const PadSettings& s, const NoteMessage& m, uint32_t at, double accent) noexcept {
        const uint32_t pc = static_cast<uint32_t>(s.engine == kEngineAcoustic ? s.acouPiece : s.acouLayer - 1);
        const int artic = s.engine == kEngineAcoustic ? s.acouArtic : kArtHit;
        readAcousticKit(*block_, at);
        readPiece(*block_, pc, at);
        double vel = clampd(m.velocity, 0, 1) * s.gain * (1.0 + accent) * (1.0 + 0.25 * s.rndLevel * random(pad, 5));
        vel = clampd(vel, 0, 1.6);
        const double jitter = s.rndPos * random(pad, 6);
        if (settled_) {
            left_ = 0;
            settled_ = false;
        }
        roomQuiet_ = 0;
        acoustic_.strike(pc, artic, vel, jitter, m.noteId);
    }

    // ---------- The voice bus (#127) ----------

    static void toLane(VoiceLane& lane, const double* l, const double* r, uint32_t at, uint32_t n) noexcept {
        for (uint32_t k = 0; k < n; ++k) {
            lane.channels[0][at + k] += static_cast<float>(l[k]);
            lane.channels[1][at + k] += static_cast<float>(r[k]);
        }
    }
    // The output each laned note's hit plays to, kept after the hit ends (its lane's FX tail goes there too).
    void laneOut(uint32_t noteId, uint32_t out) noexcept {
        for (LaneOut& o : laneOuts_)
            if (o.noteId == noteId) {
                o.out = static_cast<uint8_t>(out);
                return;
            }
        laneOuts_[laneOutNext_] = {noteId, static_cast<uint8_t>(out)};
        laneOutNext_ = (laneOutNext_ + 1) % VoiceLanes::kMaxLanes;
    }
    uint32_t laneOutOf(uint32_t noteId) const noexcept {
        for (const LaneOut& o : laneOuts_)
            if (o.noteId == noteId && noteId != 0) return o.out;
        return 0;
    }

    // ---------- Display ----------

    static constexpr uint32_t kBins = 256, kPitchPoints = 64;

    void startCapture(uint32_t pad, const PadSettings& s, const DrumVoice& v) noexcept {
        double length = 0.05;
        if (s.bodyOn) length = std::max(length, s.attack + s.hold + s.decay);
        if (s.clickOn) length = std::max(length, s.clickLength);
        if (s.noiseOn) length = std::max(length, s.noiseAttack + s.noiseDecay + (s.noiseMode == kNoiseClap ? s.bursts * s.spacing : 0.0));
        if (s.metalOn) length = std::max(length, s.metalAttack + s.metalDecay);
        if (s.resOn) length = std::max(length, s.resDecay);
        if (s.smpOn && v.sample)
            length = std::max(length, std::min(s.smpDecay, std::fabs(s.end - s.start) * v.sample->data.size() / sr_));
        length = clampd(length * v.var.decayMul * 1.1, 0.05, 4.0);
        captureMax_[pad].fill(0.0f);
        captureMin_[pad].fill(0.0f);
        captureAt_[pad] = 0;
        captureBin_[pad] = std::max<uint32_t>(1, static_cast<uint32_t>(length * sr_ / kBins));
        captureLength_[pad] = static_cast<float>(captureBin_[pad] * kBins / sr_);
    }
    void captureSample(uint32_t pad, float y) noexcept {
        const uint32_t bin = captureAt_[pad] / captureBin_[pad];
        if (bin >= kBins) return;
        ++captureAt_[pad];
        if (y > captureMax_[pad][bin]) captureMax_[pad][bin] = y;
        if (y < captureMin_[pad][bin]) captureMin_[pad][bin] = y;
    }

    // Layout (docs/engine.md, "Drums", Display data): 16 header floats, 64 pad levels, the shown pad's waveform
    // (256 maxima, 256 minima) and its body pitch curve (64 points, Hz).
    void publish(const ProcessBlock& b, uint32_t at) noexcept {
        if (qualityNow(quality_) == kQualityEco && (++publishCount_ & 1)) return;  // Eco: half as often
        const int view = clampi(parameterAt(b, kViewPad, at, 0), 0, static_cast<int>(kPads));
        const int pad = view > 0 ? view - 1 : (lastPad_ >= 0 ? lastPad_ : 0);
        float* d = frame_;
        for (uint32_t i = 0; i < 16; ++i) d[i] = 0.0f;
        d[0] = 2.0f;  // layout version
        d[1] = static_cast<float>(mode_);
        d[2] = static_cast<float>(pad);
        d[3] = static_cast<float>(-glueGr_);
        float gr = 0.0f;
        uint32_t sounding = 0;
        for (uint32_t i = 0; i < live_; ++i) {
            const DrumVoice& v = voices_[list_[i]];
            if (!v.active) continue;
            ++sounding;
            if (v.pad == pad && v.comp) gr = std::max(gr, static_cast<float>(-v.gr));
        }
        d[4] = gr;
        d[5] = captureLength_[pad];
        d[6] = kBins;
        d[7] = kPitchPoints;
        d[9] = static_cast<float>(sounding);
        d[10] = static_cast<float>(lastPad_);
        d[11] = static_cast<float>(lastKey_);  // note learn: the last note in (-1: none), its channel 1..16, velocity
        d[12] = static_cast<float>(lastChannel_);
        d[13] = lastVelocity_;
        d[14] = static_cast<float>(notesSeen_ & 0xFFFFFFu);  // counts notes in: a change means a new note
        uint64_t mask = 0;
        for (uint32_t i = 0; i < live_; ++i)
            if (voices_[list_[i]].active) mask |= 1ull << voices_[list_[i]].pad;
        for (uint32_t p = 0; p < kPads; ++p) {
            d[16 + p] = (mask >> p & 1) ? std::max(padLevel_[p], 1e-6f) : 0.0f;
            padLevel_[p] = 0.0f;
        }
        for (uint32_t i = 0; i < kBins; ++i) {
            d[80 + i] = captureMax_[pad][i];
            d[80 + kBins + i] = captureMin_[pad][i];
        }
        // The body's pitch over the pitch envelope's first three time spans, as a hit at full velocity plays it.
        PadSettings s;
        readPad(b, static_cast<uint32_t>(pad), at, s);
        double span = 0.0;
        if (s.bodyOn) {
            if (s.points) span = clampd(1.15 * (s.pt[0] + s.pt[1] + s.pt[2] + s.pt[3]), 0.01, 4.0);
            else span = clampd(s.ptime * 3.0, 0.01, 2.0);
        }
        d[8] = static_cast<float>(span);
        d[15] = s.bodyOn && s.points ? 1.0f : 0.0f;  // the pitch shape's mode
        float* curve = d + 80 + 2 * kBins;
        if (s.bodyOn) {
            const double mul = exp2d(s.tune / 12.0), fEnd = s.freq * mul, fStart = fEnd * exp2d(s.pitchSt / 12.0);
            const double c = s.pcurve;
            for (uint32_t i = 0; i < kPitchPoints; ++i) {
                const double t = span * i / (kPitchPoints - 1);
                if (s.points) {  // the same segments the voice plays
                    double from = s.pitchSt, at = 0.0, st = s.pp[3];
                    for (int k = 0; k < 4; ++k) {
                        if (t < at + s.pt[k]) {
                            const double u = (t - at) / s.pt[k], kk = 1.0 + 7.0 * std::fabs(s.pc[k]);
                            const double shaped = s.pc[k] > 0.0 ? 1.0 - std::pow(1.0 - u, kk)
                                                                : (s.pc[k] < 0.0 ? std::pow(u, kk) : u);
                            st = from + (s.pp[k] - from) * shaped;
                            break;
                        }
                        at += s.pt[k];
                        from = s.pp[k];
                    }
                    curve[i] = static_cast<float>(fEnd * exp2d(st / 12.0));
                    continue;
                }
                const double e = lib::fastExp(-kSixtyDb * t / s.ptime);
                const double shaped = c >= 0.0 ? e + c * (lib::fastExp(-kSixtyDb * 6.0 * t / s.ptime) - e)
                                               : e - c * (std::max(0.0, 1.0 - t / s.ptime) - e);
                curve[i] = static_cast<float>(fEnd + (fStart - fEnd) * shaped);
            }
        } else {
            for (uint32_t i = 0; i < kPitchPoints; ++i) curve[i] = 0.0f;
        }
        display_.publish(d, kDisplayFloats);
        watched_ = display_.watched();
    }
