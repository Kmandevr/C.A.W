// FlagshipInstrument's period render: the voice filter queue, shared filter and effects (hand-written; included by builtin_flagship.cpp, not compiled alone).
    // A voice's piece of the period between its oscillators and its output: its filters' buffers, and where it
    // goes. Voices wait in a short queue (renderPeriod) so that several voices' filters run side by side.
    struct VoiceWork {
        enum Kind { kStereo, kMono } kind = kStereo;  // filter 1 (and 2) on both sides, or filter 1 on the left alone
        Voice* v = nullptr;
        float* outL = nullptr;
        float* outR = nullptr;
        bool second = false, bypass = false;  // filter 2's path carries anything; an oscillator bypasses the filters
        float f1L[kControlFrames], f1R[kControlFrames], f2L[kControlFrames], f2R[kControlFrames];
        float byL[kControlFrames], byR[kControlFrames];
    };
    static constexpr uint32_t kQueue = 8;  // voices waiting for their filters
    // How many voices' filters run side by side: four on x86-64 (SSE2: 2 % faster than two on the Bench), two on
    // Arm64, where four were no faster (Android) or 0.5 % slower (GCC; four voices' state outgrows the registers).
#if defined(__aarch64__)
    static constexpr int kSideBySide = 2;
#else
    static constexpr int kSideBySide = 4;
#endif

    // One voice's oscillators into its filters' buffers. A voice in the instrument's shared filter 1 is finished
    // here (false); otherwise w waits for its filters (true).
    bool startVoice(Voice& v, VoiceWork& w, uint32_t n, uint32_t first) noexcept {
        float* const f1L = w.f1L;
        float* const f1R = w.f1R;
        float* const f2L = w.f2L;
        float* const f2R = w.f2R;
        float* const byL = w.byL;
        float* const byR = w.byR;
        bool bypass = false, second = v.filter[1].on;  // second: filter 2's path carries anything
        bool feeds[kOscs] = {};  // Osc FM listens to it
        for (uint32_t k = 0; k < kOscs; ++k) {
            const OscVoice& o = v.osc[k];
            if (!o.on || o.count == 0) continue;
            bypass = bypass || o.dest == kToBypass;
            second = second || o.dest == kToFilter2 || (v.parallel && o.dest == kToBoth);
            if (hearsSource(o.warpMode) && o.modSrc < static_cast<int>(kOscs)) feeds[o.modSrc] = true;
        }
        w.v = &v;
        w.second = second;
        w.bypass = bypass;
        // Whole periods cleared (a fixed count: inline stores, no memset call).
        zero(f1L), zero(f1R);
        if (second) zero(f2L), zero(f2R);
        if (bypass) zero(byL), zero(byR);
        for (uint32_t k = 0; k < kOscs; ++k) {
            OscVoice& o = v.osc[k];
            if (!o.on || o.count == 0) {
                if (feeds[k]) std::memset(v.fmBuf[k] + first, 0, n * sizeof(float));  // nothing to hear
                continue;
            }
            const float* fm = hearsSource(o.warpMode) ? v.fmBuf[o.modSrc] : nullptr;
            const OscVoice* master = o.warpMode == kWarpOscSync && o.modSrc < static_cast<int>(kOscs) &&
                                             o.modSrc != static_cast<int>(k) && v.osc[o.modSrc].on
                                         ? &v.osc[o.modSrc]
                                         : nullptr;
            if (feeds[k]) {
                float* M = v.fmBuf[k] + first;
                std::memset(M, 0, n * sizeof(float));
                addOscillator(o, M, nullptr, n, first, fm, true, master);
            }
            switch (o.dest) {
                case kToFilter2: addOscillator(o, f2L, f2R, n, first, fm, false, master); break;
                case kToBypass: addOscillator(o, byL, byR, n, first, fm, false, master); break;
                case kToBoth:
                    if (v.parallel) {
                        float tL[kControlFrames] = {}, tR[kControlFrames] = {};
                        addOscillator(o, tL, tR, n, first, fm, false, master);
                        for (uint32_t i = 0; i < n; ++i) {
                            f1L[i] += tL[i];
                            f1R[i] += tR[i];
                            f2L[i] += tL[i];
                            f2R[i] += tR[i];
                        }
                        break;
                    }
                    [[fallthrough]];  // in series, filter 1 feeds filter 2 anyway
                default: addOscillator(o, f1L, f1R, n, first, fm, false, master); break;
            }
        }
        // Filter 1 linear and set like every other voice's (no slot moves it for this voice, no key tracking):
        // the voice's level goes on before the filter and the instrument's one shared filter runs for all of them,
        // as the Morph synth did (2026-11-10 second performance pass; linear and time-invariant, so the sum is
        // the same filter on each voice, but for the level's place: perceptually the same). Once a voice's filter
        // is set apart it keeps its own to the note's end: its own filter starts from rest while the shared one
        // rings out what it had, which by linearity sums to the same signal.
        if (v.shared) {
            v.shared = !second && !bypass && sharedOn_ && v.filter[0].sameAs(shared_);
            if (v.shared) {
                float amp[kControlFrames];
                levelOf(v, amp, n, first);
                for (uint32_t i = 0; i < n; ++i) {
                    sharedL_[i] += f1L[i] * amp[i];
                    sharedR_[i] += f1R[i] * amp[i];
                }
                sharedUsed_ = true;
                if (!v.env[0].active()) v.active = false;
                return false;
            }
        }
        // A centred voice through filter 1 alone (the bass, the acid line, Basic): one side filtered, both sides
        // the same bits as before at half the filter's cost (2026-11-10 performance pass).
        w.kind = VoiceWork::kStereo;
        if (!second && !bypass && v.filter[0].monoCapable()) {
            bool centred = true;
            for (const OscVoice& o : v.osc)
                if (o.on && o.count > 0) centred = centred && o.centred;
            if (centred) w.kind = VoiceWork::kMono;
        }
        return true;
    }

    // The level ramp times envelope 1 over the piece.
    static void levelOf(Voice& v, float* amp, uint32_t n, uint32_t first) noexcept {
        const double step = (v.gain1 - v.gain0) / kControlFrames;
        double level[kControlFrames];
        v.env[0].run(level, n);  // its next() n times; then the product vectorizes
        for (uint32_t i = 0; i < n; ++i) amp[i] = static_cast<float>(level[i] * (v.gain0 + step * static_cast<double>(first + i)));
    }

    // The queued voices' filters, then each voice's output in the order they were queued (so the sums are added
    // as the one-voice-at-a-time path adds them). Voices whose filter 1 is set to the same ladder or SVF low-pass run side by
    // side, kSideBySide at a time, then their filter 2 likewise (VoiceFilter::stereoSideBySide).
    void finishVoices(VoiceWork* q, uint32_t count, uint32_t n, uint32_t first) noexcept {
        bool done[kQueue] = {};
        for (uint32_t i = 0; i < count; ++i) {
            if (done[i]) continue;
            VoiceWork* group[4] = {&q[i]};
            int size = 1;
            const VoiceWork::Kind kind = q[i].kind;
            for (uint32_t j = i + 1; j < count && size < kSideBySide; ++j)
                if (!done[j] && q[j].kind == kind && VoiceFilter::sideBySide(q[i].v->filter[0], q[j].v->filter[0]))
                    group[size++] = &q[j], done[j] = true;
            done[i] = true;
            if (kind == VoiceWork::kMono) filterMono(group, size, n);
            else filterStereo(group, size, n);
        }
        for (uint32_t i = 0; i < count; ++i) {
            VoiceWork& w = q[i];
            Voice& v = *w.v;
            float amp[kControlFrames];
            levelOf(v, amp, n, first);
            if (w.kind == VoiceWork::kMono) {
                for (uint32_t k = 0; k < n; ++k) {
                    const float y = w.f1L[k] * amp[k];
                    w.outL[k] += y;
                    w.outR[k] += y;
                }
            } else {
                // The voice's output: filter 1's, through or beside filter 2's, plus the bypass.
                const bool through = w.second && !v.parallel;
                float* yL = through ? w.f2L : w.f1L;
                float* yR = through ? w.f2R : w.f1R;
                if (w.bypass)
                    for (uint32_t k = 0; k < n; ++k) yL[k] += w.byL[k], yR[k] += w.byR[k];
                for (uint32_t k = 0; k < n; ++k) {
                    w.outL[k] += yL[k] * amp[k];
                    w.outR[k] += yR[k] * amp[k];
                }
            }
            if (!v.env[0].active()) v.active = false;
        }
    }

    // Filter 1 of `size` centred voices (their left sides), two at a time where it can.
    static void filterMono(VoiceWork* const* g, int size, uint32_t n) noexcept {
        VoiceFilter* f[4];
        float* L[4];
        for (int k = 0; k < size; ++k) f[k] = &g[k]->v->filter[0], L[k] = g[k]->f1L;
        int k = 0;
        if (size == 4) VoiceFilter::monoSideBySide<2>(f, L, n), k = 4;
        else if (size >= 2) VoiceFilter::monoSideBySide<1>(f, L, n), k = 2;
        for (; k < size; ++k) f[k]->processMono(L[k], n);
    }

    // Filters 1 and 2 of `size` stereo voices whose filter 1 runs side by side; their filter 2 too where it can.
    static void filterStereo(VoiceWork* const* g, int size, uint32_t n) noexcept {
        {
            VoiceFilter* f[4];
            float* L[4];
            float* R[4];
            for (int k = 0; k < size; ++k) f[k] = &g[k]->v->filter[0], L[k] = g[k]->f1L, R[k] = g[k]->f1R;
            sideBySide(f, L, R, size, n);
        }
        // Filter 2: in series it hears filter 1's output added to its own oscillators'.
        VoiceFilter* f[4];
        float* L[4];
        float* R[4];
        int m = 0;
        for (int k = 0; k < size; ++k) {
            VoiceWork& w = *g[k];
            if (!w.second) continue;
            if (!w.v->parallel)
                for (uint32_t i = 0; i < n; ++i) w.f2L[i] += w.f1L[i], w.f2R[i] += w.f1R[i];
            f[m] = &w.v->filter[1], L[m] = w.f2L, R[m] = w.f2R, ++m;
        }
        // The ones set alike side by side, in order; the rest one at a time.
        VoiceFilter* h[4];
        float* hL[4];
        float* hR[4];
        bool done[4] = {};
        for (int a = 0; a < m; ++a) {
            if (done[a]) continue;
            int c = 0;
            for (int b = a; b < m; ++b)
                if (!done[b] && (b == a || VoiceFilter::sideBySide(*f[a], *f[b]))) h[c] = f[b], hL[c] = L[b], hR[c] = R[b], ++c, done[b] = true;
            sideBySide(h, hL, hR, c, n);
        }
        for (int k = 0; k < size; ++k) {
            VoiceWork& w = *g[k];
            if (w.second && w.v->parallel)
                for (uint32_t i = 0; i < n; ++i) w.f1L[i] += w.f2L[i], w.f1R[i] += w.f2R[i];
        }
    }
    // `size` filters, side by side in fours and twos where they can (sideBySide()), else one at a time.
    static void sideBySide(VoiceFilter* const* f, float* const* L, float* const* R, int size, uint32_t n) noexcept {
        if (size >= 2 && VoiceFilter::sideBySide(*f[0], *f[1])) {
            if (size == 4) return VoiceFilter::stereoSideBySide<4>(f, L, R, n);
            VoiceFilter::stereoSideBySide<2>(f, L, R, n);
            if (size == 3) f[2]->process(L[2], R[2], n);
            return;
        }
        for (int k = 0; k < size; ++k) f[k]->process(L[k], R[k], n);
    }

    // One piece (n <= kControlFrames frames) of the control period, sinceControl_ frames into it; `at` is its
    // first frame in the block.
    void renderPeriod(float* left, float* right, uint32_t n, uint32_t at) noexcept {
        if (idle_) {
            std::memset(left, 0, n * sizeof(float));
            std::memset(right, 0, n * sizeof(float));
            return;
        }
        const uint32_t first = sinceControl_;
        float L[kControlFrames] = {}, R[kControlFrames] = {};
        zero(sharedL_), zero(sharedR_);
        sharedUsed_ = false;
        // Each voice's oscillators, then its filters with up to seven others' (finishVoices: side by side where
        // they are set alike), its level and its sum, in the voices' order.
        VoiceWork queue[kQueue];
        uint32_t queued = 0;
        const auto render = [&](Voice& v, float* outL, float* outR) noexcept {
            VoiceWork& w = queue[queued];
            w.outL = outL;
            w.outR = outR;
            if (startVoice(v, w, n, first) && ++queued == kQueue) finishVoices(queue, queued, n, first), queued = 0;
        };
        if (lanes_.any()) {
            // The voice bus (#127): a voice whose note has a lane renders there (with its own filter 1, never the
            // shared one, which sums voices), the host runs its per-note FX, and the lanes join the voices' sum
            // before the shared stage below (distortion, EQ, chorus, delay, reverb, volume).
            lanes_.begin(at, n);
            voices_.forEachActive([&](Voice& v) noexcept {
                if (VoiceLane* lane = lanes_.laneFor(v.noteId)) {
                    v.shared = false;
                    render(v, lane->channels[0] + at, lane->channels[1] + at);
                } else {
                    render(v, L, R);
                }
            });
            finishVoices(queue, queued, n, first);
            lanes_.runAndSum(L, R, at, n);
        } else {
            voices_.forEachActive([&](Voice& v) noexcept { render(v, L, R); });
            finishVoices(queue, queued, n, first);
        }
        // finishVoices() ends a voice after forEachActive() has kept it in the pool's list: drop it now, so the
        // list holds only the voices sounding at the period's end (VoicePool's contract).
        voices_.dropSilent();
        runShared(L, R, n);
        const double volumeStep = (volume1_ - volume0_) / kControlFrames;
        const double delayStep = (delayTime1_ - delayTime0_) / kControlFrames;
        float peak = periodPeak_;
        // Both sides the same (every voice centred: the bass, the acid line): the distortion, which holds no state,
        // runs on one and gives the other the same bits.
        // Silence (between notes) stays silence through every type (what the sum below gives for a 0 in: +0).
        const bool same = distOn_ && std::memcmp(L, R, n * sizeof(float)) == 0;
        const auto dist = [&](double x) noexcept { return x == 0.0 ? 0.0 : x + (distort(x) - x) * distMix_; };
        const bool rest = eqOn_ || chorusOn_ || delayOn_ || reverbOn_;
        if (distOn_ && !rest) {  // the distortion alone: in place (to float, as below), then the dry loops
            distortInPlace(L, n, dist);
            if (same) std::memcpy(R, L, n * sizeof(float));
            else distortInPlace(R, n, dist);
        }
        if (!rest) {  // dry: two plain loops the compiler vectorizes
            for (uint32_t i = 0; i < n; ++i) {
                const double volume = volume0_ + volumeStep * static_cast<double>(first + i);
                left[i] = static_cast<float>(finite0(L[i] * volume));
                right[i] = static_cast<float>(finite0(R[i] * volume));
            }
            periodPeak_ = peakOf(left, right, n, peak);
            return;
        }
        for (uint32_t i = 0; i < n; ++i) {
            const double at = static_cast<double>(first + i);
            double l = L[i], r = R[i];
            if (distOn_) {
                l = dist(l);
                r = same ? l : dist(r);
            }
            if (eqOn_) {
                l += (eqL_.process(l) - l) * eqMix_;
                r += (eqR_.process(r) - r) * eqMix_;
            }
            float fl = static_cast<float>(l), fr = static_cast<float>(r);
            if (chorusOn_) chorus_.step(chorusMix_, fl, fr);
            if (delayOn_) delay_.process((delayTime0_ + delayStep * at) / sr_, delayFeedback_, 1.0, delayMix_, fl, fr);
            L[i] = fl;
            R[i] = fr;
        }
        // The reverb, last, over the period at once (lib::Reverb's block form: the frame-by-frame bits).
        if (reverbOn_) reverb_.process(L, R, static_cast<int>(n));
        for (uint32_t i = 0; i < n; ++i) {
            const double volume = volume0_ + volumeStep * static_cast<double>(first + i);
            const float ol = static_cast<float>(finiteOr0(L[i] * volume)), orr = static_cast<float>(finiteOr0(R[i] * volume));
            left[i] = ol;
            right[i] = orr;
            peak = std::max(peak, std::max(std::fabs(ol), std::fabs(orr)));
        }
        periodPeak_ = peak;
    }

    // The shared filter 1 over the levelled sum of the voices that share it, added to the voices' output. With no
    // voice in it and its output below -140 dB it is cleared and rests until a voice uses it again.
    void runShared(float* L, float* R, uint32_t n) noexcept {
        if (!sharedUsed_ && sharedQuiet_) return;
        sharedQuiet_ = false;
        sharedRan_ = sharedRan_ || sharedUsed_;
        shared_.svf[0].flushDenormals();  // a voice held at level 0 feeds it silence
        shared_.svf[1].flushDenormals();
        shared_.process(sharedL_, sharedR_, n);
        float peak = sharedPeak_;
        for (uint32_t i = 0; i < n; ++i) {
            L[i] += sharedL_[i];
            R[i] += sharedR_[i];
            peak = std::max(peak, std::max(std::fabs(sharedL_[i]), std::fabs(sharedR_[i])));
        }
        sharedPeak_ = peak;
    }
    // At each control (the same grid at any block size): a shared filter that no voice fed over the last period
    // and that stayed below -140 dB is cleared and rests.
    void restShared() noexcept {
        if (!sharedQuiet_ && !sharedRan_ && sharedPeak_ < 1e-7f) {
            shared_.clear();
            sharedQuiet_ = true;
        }
        sharedRan_ = false;
        sharedPeak_ = 0.0f;
    }

    // finiteOr0 as a select (x - x is 0 exactly when x is finite), which vectorizes.
    static double finite0(double x) noexcept { return x - x == 0.0 ? x : 0.0; }
    // The largest |x| of both sides and `peak`: as integers (the bits of non-negative floats sort as the floats
    // do), so the loop vectorizes; a float max reduction does not without fast-math.
    static float peakOf(const float* l, const float* r, uint32_t n, float peak) noexcept {
        int32_t top = std::bit_cast<int32_t>(peak);
        for (uint32_t i = 0; i < n; ++i) {
            const int32_t a = std::bit_cast<int32_t>(l[i]) & 0x7FFFFFFF, b = std::bit_cast<int32_t>(r[i]) & 0x7FFFFFFF;
            top = std::max(top, std::max(a, b));
        }
        return std::bit_cast<float>(top);
    }

    // dist() on each of n samples, in place: the drive two samples at a time (Saturator::process2, the same bits).
    template <class Dist>
    void distortInPlace(float* x, uint32_t n, const Dist& dist) const noexcept {
        uint32_t i = 0;
        if (distType_ == 0) {
            for (; i + 1 < n; i += 2) {
                const double in[2] = {x[i], x[i + 1]};
                double d[2];
                saturator_.process2Approx(in, d);
                for (int j = 0; j < 2; ++j) x[i + j] = static_cast<float>(in[j] == 0.0 ? 0.0 : in[j] + (d[j] - in[j]) * distMix_);
            }
        }
        for (; i < n; ++i) x[i] = static_cast<float>(dist(x[i]));
    }

    double distort(double x) const noexcept {
        switch (distType_) {
            case 1: return lib::hardClip(x, distDrive_);
            case 2: return lib::fastSinCycles(finiteOr0(x) * distDrive_ * 0.25);  // lib::fold: sin(x d pi / 2)
            case 3: return std::floor(finiteOr0(x) * crushSteps_ + 0.5) / crushSteps_;
            default: return saturator_.processApprox(x);
        }
    }
