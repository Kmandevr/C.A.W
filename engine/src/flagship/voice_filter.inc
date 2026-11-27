// Flagship's mip-level choice and a voice's filter section (VoiceFilter) (hand-written; included by builtin_flagship.cpp, not compiled alone).
// The mip level whose harmonics all stay at or below Nyquist at `dt` cycles per sample (Wavetable::levelFor
// without its loop: the first k with frameSize * dt <= 2^k).
int mipLevel(double dt, int levels) noexcept {
    const double x = kFrameSize * dt;
    if (!(x > 1.0)) return 0;
    // x = 1.f * 2^e from its bits (x > 1 is normal): the smallest k with x <= 2^k is e, or e + 1 if f > 0.
    const uint64_t bits = std::bit_cast<uint64_t>(x);
    const int e = static_cast<int>((bits >> 52) & 0x7FF) - 1023;
    const int k = (bits & 0xFFFFFFFFFFFFFull) ? e + 1 : e;
    return k < levels ? k : levels - 1;
}

// ---------- A voice's filter ----------

struct VoiceFilter {
    bool on = false, drive = false;
    int type = -1;
    float mix = 1.0f;
    lib::MultiLadder ladder[2];
    lib::Svf svf[2];
    lib::FormantFilter formant[2];
    flagship::DiodeLp diode[2];
    flagship::SallenKey sallen[2];
    flagship::Phaser phaser[2];
    lib::CombFilter* comb[2] = {nullptr, nullptr};  // the instrument's, one pair per voice (they hold memory)
    lib::Saturator saturator;
    double qFor = -1.0, q = 0.70710678118654752;  // the SVF's q, for the resonance it was worked out from

    void configure(bool enabled, int t, double cutoff, double resonance, double amount, double morph, double wet,
                   double sampleRate, bool fresh) noexcept {
        on = enabled;
        if (fresh) type = -1;  // a new note starts every filter from rest
        if (!on) return;
        cutoffSet = cutoff, resonanceSet = resonance;
        if (t != type) {  // a new type starts from rest
            for (int c = 0; c < 2; ++c) {
                ladder[c].clear();
                svf[c].clear();
                formant[c].clear();
                diode[c].clear(), sallen[c].clear(), phaser[c].clear();
                if (comb[c] && (t == kComb || t == kCombNeg)) comb[c]->clear();
            }
            type = t;
        }
        mix = static_cast<float>(wet);
        drive = amount > 1.0001;
        saturator.set(amount);
        for (int c = 0; c < 2; ++c) {
            switch (type) {
                case kLadderLp:
                case kLadderHp:
                case kLadderBp:
                    if (c == 0) ladder[0].setApprox(cutoff, resonance, sampleRate);
                    else ladder[1].setLike(ladder[0]);  // one tan for the pair
                    break;
                case kComb:
                    if (comb[c]) comb[c]->set(cutoff, 0.4 + 0.595 * resonance, morph);
                    break;
                case kFormant: formant[c].set(morph, cutoff / 1000.0, 4.0 + 16.0 * resonance, sampleRate); break;
                // 1.1.0's models. The comb's negative feedback rings odd harmonics an octave below its frequency; the
                // vowel is the formant filter's peaks over the dry signal (the body kept), the morph choosing the vowel.
                case kDiodeLp: diode[c].set(cutoff, resonance, sampleRate); break;
                case kSallenKeyLp: sallen[c].set(cutoff, resonance, sampleRate); break;
                case kPhaser: phaser[c].set(cutoff, resonance, morph, sampleRate); break;
                case kCombNeg:
                    if (comb[c]) comb[c]->set(cutoff, -(0.4 + 0.595 * resonance), morph);
                    break;
                case kVowel: formant[c].set(morph, cutoff / 1000.0, 4.0 + 16.0 * resonance, sampleRate); break;
                default:
                    if (resonance != qFor) qFor = resonance, q = lib::resonanceQ(resonance);  // a pow: only on a change
                    if (c == 0) svf[0].setApprox(cutoff, q, sampleRate);
                    else svf[1].setLike(svf[0]);  // one tan for the pair
                    break;
            }
        }
    }
    // The drive on one side, in float four samples at a time (Saturator::processApproxFloat, #197).
    void driveMono(float* x, uint32_t n) noexcept { saturator.processApproxFloat(x, n); }
    template <class F>
    void each(float* x, uint32_t n, F&& f) noexcept {
        for (uint32_t i = 0; i < n; ++i) x[i] = static_cast<float>(f(static_cast<double>(x[i])));
    }
    // In place: drive (when above 1) into the filter, then the dry/wet mix.
    // A centred voice (both sides the same): only the left side is filtered, and stands for both. Ladder and SVF
    // low-pass only; the right side's state takes the left's when it is filtered again (it was the same).
    bool monoCapable() const noexcept { return !on || type <= kLadderBp || type == kSvfLp; }
    void processMono(float* L, uint32_t n) noexcept {
        if (!on) return;
        float dry[kControlFrames];
        beginMono(L, n, dry);
        if (type == kLadderLp) ladder[0].process<lib::LadderMode::LowPass>(L, n);
        else if (type == kLadderHp) ladder[0].process<lib::LadderMode::HighPass>(L, n);
        else if (type == kLadderBp) ladder[0].process<lib::LadderMode::BandPass>(L, n);
        else
            for (uint32_t i = 0; i < n; ++i) L[i] = static_cast<float>(svf[0].lowpass(static_cast<double>(L[i])));
        endMono(L, n, dry);
    }
    bool monoUsed = false;  // the left side ran alone: the right's state is behind
    double cutoffSet = -1.0, resonanceSet = -1.0;  // what configure() was last given

    // An SVF without drive is linear: voices whose filters are set alike can share one (see FlagshipInstrument).
    bool linear() const noexcept { return on && type >= kSvfLp && type <= kSvfNotch && !drive; }
    bool sameAs(const VoiceFilter& f) const noexcept {
        return on == f.on && type == f.type && drive == f.drive && mix == f.mix && cutoffSet == f.cutoffSet &&
               resonanceSet == f.resonanceSet;
    }
    void clear() noexcept {
        for (int c = 0; c < 2; ++c)
            ladder[c].clear(), svf[c].clear(), formant[c].clear(), diode[c].clear(), sallen[c].clear(), phaser[c].clear();
        monoUsed = false;
    }

    void process(float* L, float* R, uint32_t n) noexcept {
        if (!on) return;
        float dryL[kControlFrames], dryR[kControlFrames];
        begin(L, R, n, dryL, dryR);
        if (type <= kLadderBp) {  // both sides in one loop
            if (type == kLadderLp) ladder[0].processPair<lib::LadderMode::LowPass>(ladder[1], L, R, n);
            else if (type == kLadderHp) ladder[0].processPair<lib::LadderMode::HighPass>(ladder[1], L, R, n);
            else ladder[0].processPair<lib::LadderMode::BandPass>(ladder[1], L, R, n);
        }
        if (type == kSvfLp) svf[0].lowpassPair(svf[1], L, R, n);  // both sides in one loop, as a two-wide vector
        // 1.1.0's serial models: both sides in one loop (flagship::processPair).
        if (type == kDiodeLp) flagship::processPair(diode[0], diode[1], L, R, n);
        else if (type == kSallenKeyLp) flagship::processPair(sallen[0], sallen[1], L, R, n);
        else if (type == kPhaser) flagship::processPair(phaser[0], phaser[1], L, R, n);
        for (int c = 0; c < 2 && type > kSvfLp && type != kDiodeLp && type != kSallenKeyLp && type != kPhaser; ++c) {
            float* x = c ? R : L;
            switch (type) {
                case kSvfHp: each(x, n, [&](double v) noexcept { return svf[c].process(v).high; }); break;
                case kSvfBp: each(x, n, [&](double v) noexcept { return svf[c].process(v).band; }); break;
                case kSvfNotch: each(x, n, [&](double v) noexcept { return svf[c].process(v).notch; }); break;
                case kComb:
                    if (comb[c]) each(x, n, [&](double v) noexcept { return comb[c]->process(v); });
                    break;
                case kFormant: each(x, n, [&](double v) noexcept { return formant[c].process(v); }); break;
                case kCombNeg:
                    if (comb[c]) each(x, n, [&](double v) noexcept { return comb[c]->process(v); });
                    break;
                case kVowel: each(x, n, [&](double v) noexcept { return 0.4 * v + 1.2 * formant[c].process(v); }); break;
                default: break;
            }
        }
        end(L, R, n, dryL, dryR);
    }

    // Several voices' filters side by side (speed A2, 2026-11-12): a ladder or an SVF low-pass is a long chain of
    // dependent operations per sample, so a CPU running one voice's waits; K pairs' chains in one loop overlap.
    // Stereo: voice k's L[k], R[k] through *f[k] (process()), K voices. Mono: L[k] through *f[k]'s left side
    // (processMono()), 2K voices, two to a pair. Every filter is on and of one type, a ladder or the SVF low-pass
    // (sideBySide()). Each sample's arithmetic is the one-voice path's: the same within the tolerance tests, and
    // bit-identical on the builds checked (-ffp-contract=fast may fuse the two paths differently, about 1 ulp).
    template <int K>
    static void stereoSideBySide(VoiceFilter* const* f, float* const* L, float* const* R, uint32_t n) noexcept {
        float dryL[K][kControlFrames], dryR[K][kControlFrames];
        for (int k = 0; k < K; ++k) f[k]->begin(L[k], R[k], n, dryL[k], dryR[k]);
        if (f[0]->type <= kLadderBp) {
            lib::MultiLadder* lf[2 * K];
            for (int k = 0; k < K; ++k) lf[2 * k] = &f[k]->ladder[0], lf[2 * k + 1] = &f[k]->ladder[1];
            ladderPairs<K>(f[0]->type, lf, L, R, n);
        } else {
            lib::Svf* sf[2 * K];
            for (int k = 0; k < K; ++k) sf[2 * k] = &f[k]->svf[0], sf[2 * k + 1] = &f[k]->svf[1];
            lib::Svf::lowpassPairs<K>(sf, L, R, n);
        }
        for (int k = 0; k < K; ++k) f[k]->end(L[k], R[k], n, dryL[k], dryR[k]);
    }
    template <int K>
    static void monoSideBySide(VoiceFilter* const* f, float* const* L, uint32_t n) noexcept {
        float dry[2 * K][kControlFrames];
        float* left[K];
        float* right[K];
        for (int k = 0; k < 2 * K; ++k) f[k]->beginMono(L[k], n, dry[k]);
        for (int k = 0; k < K; ++k) left[k] = L[2 * k], right[k] = L[2 * k + 1];
        if (f[0]->type <= kLadderBp) {
            lib::MultiLadder* lf[2 * K];
            for (int k = 0; k < 2 * K; ++k) lf[k] = &f[k]->ladder[0];
            ladderPairs<K>(f[0]->type, lf, left, right, n);
        } else {
            lib::Svf* sf[2 * K];
            for (int k = 0; k < 2 * K; ++k) sf[k] = &f[k]->svf[0];
            lib::Svf::lowpassPairs<K>(sf, left, right, n);
        }
        for (int k = 0; k < 2 * K; ++k) f[k]->endMono(L[k], n, dry[k]);
    }
    // Whether two voices' filters can run side by side.
    static bool sideBySide(const VoiceFilter& a, const VoiceFilter& b) noexcept {
        return a.on && b.on && a.type == b.type && (a.type <= kLadderBp || a.type == kSvfLp);
    }

private:
    template <int K>
    static void ladderPairs(int type, lib::MultiLadder* const* lf, float* const* left, float* const* right,
                            uint32_t n) noexcept {
        if (type == kLadderLp) lib::MultiLadder::processPairs<lib::LadderMode::LowPass, K>(lf, left, right, n);
        else if (type == kLadderHp) lib::MultiLadder::processPairs<lib::LadderMode::HighPass, K>(lf, left, right, n);
        else lib::MultiLadder::processPairs<lib::LadderMode::BandPass, K>(lf, left, right, n);
    }
    // process()'s steps before and after the filter itself: back to stereo after a mono run, the dry copy for
    // the mix, the drive and the denormal flush; then the dry/wet mix.
    void begin(float* L, float* R, uint32_t n, float* dryL, float* dryR) noexcept {
        if (monoUsed) {  // back to stereo: the right side continues from the left's state, which both had
            monoUsed = false;
            ladder[1] = ladder[0];
            svf[1] = svf[0];
        }
        if (!(mix >= 1.0f)) std::copy(L, L + n, dryL), std::copy(R, R + n, dryR);
        if (drive) {  // each side in float, four samples at a time (Saturator::processApproxFloat, #197)
            saturator.processApproxFloat(L, n);
            saturator.processApproxFloat(R, n);
        }
        if (type <= kLadderBp) ladder[0].flushDenormals(), ladder[1].flushDenormals();
    }
    void end(float* L, float* R, uint32_t n, const float* dryL, const float* dryR) noexcept {
        if (!(mix >= 1.0f))
            for (uint32_t i = 0; i < n; ++i) {
                L[i] = dryL[i] + (L[i] - dryL[i]) * mix;
                R[i] = dryR[i] + (R[i] - dryR[i]) * mix;
            }
    }
    void beginMono(float* L, uint32_t n, float* dry) noexcept {
        monoUsed = true;
        if (!(mix >= 1.0f)) std::copy(L, L + n, dry);
        if (drive) driveMono(L, n);
        if (type <= kLadderBp) ladder[0].flushDenormals();
    }
    void endMono(float* L, uint32_t n, const float* dry) noexcept {
        if (!(mix >= 1.0f))
            for (uint32_t i = 0; i < n; ++i) L[i] = dry[i] + (L[i] - dry[i]) * mix;
    }
};
