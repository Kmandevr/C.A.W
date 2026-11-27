// DrumsProcessor's per-sample layers, the echo and the drive stage (hand-written; included by builtin_drums.cpp, not compiled alone).
    // ---------- Per sample ----------

    // The pitch shape's semitones over the settled pitch now (Points mode), then a step on.
    static double shapeSemitones(DrumVoice& v) noexcept {
        if (v.pSeg >= 4) return v.pTo[3];
        const int k = v.pSeg;
        const double u = static_cast<double>(v.pPos) / static_cast<double>(v.pLen[k]);
        double shaped = u;
        if (v.pSign[k] > 0.0) {  // fast first, then slow (an exponential-like drop)
            const double r = 1.0 - u;
            shaped = 1.0 - (r > 1e-9 ? lib::fastExp(v.pK[k] * lib::fastLog(r)) : 0.0);
        } else if (v.pSign[k] < 0.0) {  // slow first, then fast
            shaped = u > 1e-9 ? lib::fastExp(v.pK[k] * lib::fastLog(u)) : 0.0;
        }
        if (++v.pPos >= v.pLen[k]) {
            v.pPos = 0;
            ++v.pSeg;
        }
        return v.pFrom[k] + (v.pTo[k] - v.pFrom[k]) * shaped;
    }

    static double bodySample(DrumVoice& v) noexcept {
        double f;
        if (v.points) {
            f = v.fEnd * exp2d(shapeSemitones(v) * (1.0 / 12.0));
        } else {
            const double pe = v.pitchEnv.next();
            f = v.fEnd + (v.fStart - v.fEnd) * pe;
        }
        v.bodyF = f;
        const double dt = f * v.invSr;
        double y;
        switch (v.wave) {
            case kWaveTriangle: y = lib::triangleWave(v.phase); break;
            case kWaveSaw: y = lib::sawWave(v.phase, dt); break;
            case kWaveSquare: y = lib::squareWave(v.phase, dt); break;
            default: y = lib::fastSinCycles(v.phase); break;
        }
        v.phase += dt;
        v.phase -= std::floor(v.phase);
        if (v.p2level > 0.0) {
            y += v.p2level * lib::fastSinCycles(v.phase2);
            v.phase2 += dt * v.p2ratio;
            v.phase2 -= std::floor(v.phase2);
        }
        if (v.shapeAmt > 0.0) y = lib::tanhApprox(y * v.shapeAmt) * v.shapeNorm;
        if (v.fold > 0.0) y = lib::fastSinCycles(y * v.fold * 0.25);
        return y * v.bodyEnv.next();
    }

    // The sub: a sine, triangle or warm (saturated) sine at the settled pitch's octave, with its own envelope;
    // `sub_follow` lets it ride the body's pitch shape (ratio^follow).
    static double subSample(DrumVoice& v) noexcept {
        const double env = v.subEnv.next();
        if (env == 0.0) return 0.0;
        double dt = v.subDt;
        if (v.subFollow > 0.0 && v.bodyF != v.fEnd) dt *= lib::fastExp(v.subFollow * lib::fastLog(v.bodyF / v.fEnd));
        double y;
        switch (v.subWave) {
            case kSubTriangle: y = lib::triangleWave(v.subPhase); break;
            case kSubWarm: y = lib::tanhApprox(2.0 * lib::fastSinCycles(v.subPhase)) * 1.0373; break;
            default: y = lib::fastSinCycles(v.subPhase); break;
        }
        v.subPhase += dt;
        v.subPhase -= std::floor(v.subPhase);
        if (v.subDrive > 0.0) y = lib::tanhApprox(y * v.subDrive) * v.subNorm;
        if (v.subFilter) y = v.subLpf.low(y);
        return y * env * v.subLevel;
    }

    static double clickSample(DrumVoice& v) noexcept {
        const double env = v.clickEnv.next();
        if (env == 0.0) return 0.0;
        double y;
        switch (v.clickType) {
            case kClickImpulse: y = v.clickHp.low(env); break;
            case kClickBlip:
                y = lib::fastSinCycles(v.clickPhase);
                v.clickPhase += v.clickTone * v.invSr;
                break;
            case kClickTick:
                y = v.clickPhase - std::floor(v.clickPhase) < 0.5 ? 1.0 : -1.0;
                v.clickPhase += v.clickTone * v.invSr;
                break;
            case kClickChirp:
                y = lib::fastSinCycles(v.clickPhase);
                v.clickPhase += v.clickTone * (1.0 + 3.0 * env) * v.invSr;
                break;
            case kClickPop: y = v.clickBp.bandpass(v.rng.next()) * 2.0; break;
            default: y = v.clickHp.high(v.rng.next()); break;
        }
        v.clickPhase -= std::floor(v.clickPhase);
        return y * env * v.clickLevel;
    }

    static double noiseSource(DrumVoice& v) noexcept {
        const double w = v.rng.next();
        switch (v.color) {
            case kPink: {
                // Approximately -3 dB an octave: white plus three one-poles a decade apart, each louder as it is lower.
                v.pink[0] += (w - v.pink[0]) * v.pinkK[0];
                v.pink[1] += (w - v.pink[1]) * v.pinkK[1];
                v.pink[2] += (w - v.pink[2]) * v.pinkK[2];
                return (0.25 * w + 2.2 * v.pink[0] + 1.0 * v.pink[1] + 0.55 * v.pink[2]) * 0.9;
            }
            case kBrown:
                v.brown += (w - v.brown) * v.brownK;
                return v.brown * 6.0;
            case kCrushed:
                if (v.crushLeft == 0) {
                    v.crushHeld = w;
                    v.crushLeft = v.crushEvery;
                }
                --v.crushLeft;
                return v.crushHeld;
            default: return w;
        }
    }

    static double noiseSample(DrumVoice& v, double bodyRaw) noexcept {
        double env;
        if (v.noiseMode == kNoiseClap) {
            if (v.clapCount < v.clapBursts * v.clapPeriod) {
                if (v.clapCount % v.clapPeriod == 0) v.burst = 1.0;
                env = v.burst;
                v.burst *= v.burstCoef;
                if (++v.clapCount == v.clapBursts * v.clapPeriod) v.tailEnv.trigger();
            } else {
                env = v.tailEnv.next();
            }
        } else {
            env = v.noiseEnv.next();
            if (v.noiseMode == kNoiseSnappy) {
                // The snares: the wires buzz while the shell moves them. With the body off, a shell of their own
                // (190 Hz, falling 60 dB in 0.35 s) moves them, so Snappy is heard on a noise-only pad too.
                double shell = bodyRaw;
                if (!v.body) {
                    shell = lib::fastSinCycles(v.shellPhase) * v.shellLevel;
                    v.shellPhase += v.shellDt;
                    v.shellPhase -= std::floor(v.shellPhase);
                    v.shellLevel *= v.shellCoef;
                }
                const double a = shell < 0.0 ? -shell : shell;
                v.wire += (a - v.wire) * v.wireK;
                const double w = v.wire * 3.0;
                env *= 0.35 + 0.65 * (w > 1.0 ? 1.0 : w);
            }
        }
        if (env == 0.0) return 0.0;
        const double x = noiseSource(v);
        double y;
        switch (v.noiseFilter) {
            case kFilterLp: y = v.noiseSvf.lowpass(x); break;
            case kFilterBp: y = v.noiseSvf.bandpass(x); break;
            case kFilterHp: y = v.noiseSvf.highpass(x); break;
            default: y = x; break;
        }
        return y * env * v.noiseLevel;
    }

    static double metalOsc(DrumVoice& v) noexcept {
        double y = 0.0;
        switch (v.metalMode) {
            case kMetalFmPairs:
                for (int i = 0; i < 6; i += 2) {
                    y += v.mAmp[i] * 2.0 * lib::fastSinCycles(v.mPhase[i] + v.fmIndex * lib::fastSinCycles(v.mPhase[i + 1]));
                }
                break;
            case kMetalRing:
                for (int i = 0; i < 6; i += 2) {
                    const double a = v.mPhase[i] < 0.5 ? 1.0 : -1.0, b = v.mPhase[i + 1] < 0.5 ? 1.0 : -1.0;
                    y += (v.mAmp[i] + v.mAmp[i + 1]) * a * b;
                }
                break;
            default:
                if (v.quality == kQualityEco) {
                    for (int i = 0; i < 6; ++i) y += v.mAmp[i] * (v.mPhase[i] < 0.5 ? 1.0 : -1.0);
                } else {
                    for (int i = 0; i < 6; ++i) y += v.mAmp[i] * lib::squareWave(v.mPhase[i], v.mDt[i]);
                }
                break;
        }
        for (int i = 0; i < 6; ++i) {
            v.mPhase[i] += v.mDt[i];
            if (v.mPhase[i] >= 1.0) v.mPhase[i] -= 1.0;
        }
        return y;
    }

    static double metalSample(DrumVoice& v) noexcept {
        const double env = v.metalEnv.next();
        if (env == 0.0) return 0.0;
        double m;
        if (v.quality == kQualityHigh) {
            double two[2] = {metalOsc(v), metalOsc(v)};
            m = v.metalOs.down(two);
        } else {
            m = metalOsc(v);
        }
        double x = m * (1.0 - v.metalNoise) + v.rng.next() * v.metalNoise;
        if (v.band > 0.0) x += (v.metalBp.bandpass(x) * v.bandGain - x) * v.band;  // unity at the band's centre
        return v.metalHp.highpass(x) * env * v.metalLevel;
    }

    static double sampleSample(DrumVoice& v) noexcept {
        if (!v.smpPlaying || !v.sample) return 0.0;
        const float* d = v.sample->data.data();
        const double pos = v.smpPos;
        const size_t i = static_cast<size_t>(pos);
        const double f = pos - static_cast<double>(i);
        const size_t last = v.sample->data.size() - 1;
        const double a = d[i], b = d[i < last ? i + 1 : last];
        const double y = (a + (b - a) * f) * v.smpEnv.next();
        // The pitch drop (1.1.0): the step starts `smp_pitch` semitones higher and falls back over its time.
        const double step = v.smpDrop > 0.0 ? v.smpStep * exp2d(v.smpDrop * v.smpPEnv.next() * (1.0 / 12.0)) : v.smpStep;
        if (v.reverse) {
            v.smpPos -= step;
            if (v.smpPos <= v.smpFirst) v.smpPlaying = false;
        } else {
            v.smpPos += step;
            if (v.smpPos >= v.smpLast) v.smpPlaying = false;
        }
        if (!v.smpEnv.active()) v.smpPlaying = false;
        return y * v.smpLevel;
    }

    // FM (1.1.0): a sine carrier phase-modulated by a sine at `ratio` (with feedback), its depth falling on its own
    // envelope, its pitch dropping from `fm_pitch` above as the body's does.
    static double fmSample(DrumVoice& v) noexcept {
        const double env = v.fmEnv.next();
        if (env == 0.0) return 0.0;
        const double f = v.fmF * (1.0 + (v.fmStartMul - 1.0) * v.fmPEnv.next());
        const double dt = f * v.invSr;
        const double m = lib::fastSinCycles(v.fmPhaseM + v.fmFb * v.fmPrev);
        v.fmPrev = m;
        const double y = lib::fastSinCycles(v.fmPhaseC + v.fmDepth * v.fmIEnv.next() * m);
        v.fmPhaseC += dt;
        v.fmPhaseC -= std::floor(v.fmPhaseC);
        v.fmPhaseM += dt * v.fmRatio;
        v.fmPhaseM -= std::floor(v.fmPhaseM);
        return y * env * v.fmLevel;
    }

    // Physical (1.1.0): a Karplus-Strong waveguide. The exciter (a pluck: a falling noise burst one period long; a
    // noise burst of 10 ms; or the other layers) is fed into a delay line of one period whose output, through a
    // one-pole loss filter (and an all-pass for the stiff string), goes back in at the decay's gain. The output is
    // read at the pick position too and the two subtracted (a comb: where it is plucked).
    static double physSample(DrumVoice& v, double layers) noexcept {
        double e = 0.0;
        if (v.physExciteLeft) {
            const double k = static_cast<double>(v.physExciteLeft--) / static_cast<double>(v.physExciteLength);
            if (v.physExciter == kPhysPluck) e = v.rng.next() * k;
            else if (v.physExciter == kPhysNoise) e = v.rng.next() * 0.5 * k;
        }
        e += v.physInput * layers;
        const uint32_t mask = v.physMax;  // the line wraps at physMax
        auto tap = [&](double d) noexcept {
            double r = static_cast<double>(v.physW) - d;
            while (r < 0.0) r += mask;
            const uint32_t i = static_cast<uint32_t>(r);
            const double f = r - i;
            const uint32_t j = i + 1 < mask ? i + 1 : 0;
            return v.physLine[i] + (v.physLine[j] - v.physLine[i]) * f;
        };
        const double y = tap(v.physDelay);
        v.physLp += (y - v.physLp) * v.physLpK;
        double fb = v.physLp;
        if (v.physApK != 0.0) {  // a first-order all-pass: the stiff string's dispersion
            const double out = v.physApK * fb + v.physApIn - v.physApK * v.physAp;
            v.physApIn = fb;
            v.physAp = out;
            fb = out;
        }
        v.physLine[v.physW] = static_cast<float>(e + v.physSign * v.physGain * fb);
        if (++v.physW >= mask) v.physW = 0;
        const double out = v.physPickDelay > 0.5 ? y - tap(v.physPickDelay) * 0.5 : y;
        const double a = out < 0.0 ? -out : out;
        if (a > v.physPeak) v.physPeak = a;
        return out * v.physLevel;
    }

    // Texture (1.1.0): shaped noise. Bands: white noise through two resonant band-passes `spread` octaves apart,
    // the tilt sharing the level. Dust: sparse impulses (`density` a second) through the lower band. Crackle: sparse
    // 2 ms grains of noise of random loudness through it.
    static double texSample(DrumVoice& v) noexcept {
        const double env = v.texEnv.next();
        if (env == 0.0) return 0.0;
        const double w = v.rng.next();
        double y;
        switch (v.texMode) {
            case kTexDust: {
                const double u = 0.5 * (v.rng.next() + 1.0);
                const double x = u < v.texChance ? (w < 0.0 ? -1.0 : 1.0) : 0.0;
                y = v.texLo.bandpass(x) * v.texLoGain * v.texScale;
                break;
            }
            case kTexCrackle: {
                const double u = 0.5 * (v.rng.next() + 1.0);
                if (u < v.texChance) v.texGrain = 1.0, v.texGrainAmp = w * w;
                v.texGrain *= v.texGrainK;
                y = v.texLo.bandpass(v.rng.next() * v.texGrain * v.texGrainAmp) * v.texLoGain * v.texScale;
                break;
            }
            default: y = v.texLo.bandpass(w) * v.texLoGain + v.texHi.bandpass(w) * v.texHiGain; break;
        }
        return y * env * v.texLevel;
    }

    CAW_DRUMS_INLINE double voiceSample(DrumVoice& v) noexcept {
        double bodyRaw = 0.0, layers = 0.0;
        if (v.body) {
            bodyRaw = bodySample(v);
            layers += bodyRaw * v.bodyLevel;
        }
        if (v.click) layers += clickSample(v);
        if (v.noise) layers += noiseSample(v, bodyRaw);
        if (v.metal) layers += metalSample(v);
        if (v.smp) layers += sampleSample(v);
        if (v.fm) layers += fmSample(v);
        if (v.tex) layers += texSample(v);
        double subY = 0.0;
        if (v.sub) {
            subY = subSample(v);
            if (!v.subClean) layers += subY, subY = 0.0;
        }
        double y = layers;
        if (v.res) {
            double excite = 0.0;
            if (v.exciteLeft) {
                const uint32_t k = v.exciteLength - v.exciteLeft--;
                if (v.exciter == kExciteMallet) {
                    const double n = static_cast<double>(v.exciteLength);
                    excite += (1.0 - lib::fastSinCycles(static_cast<double>(k) / n + 0.25)) / n;  // unit area
                } else {
                    excite += v.rng.next() * 0.02 * (1.0 - static_cast<double>(k) / v.exciteLength);
                }
            }
            y += v.modal.process(excite, v.resInput * layers) * v.resLevel;
        }
        if (v.phys) y += physSample(v, layers);
        // Effects.
        const int os = v.quality == kQualityEco ? 1 : (v.quality == kQualityHigh ? 4 : 2);
        if (!v.drivePost) y = driveStage(v, y, os);
        switch (v.flt) {
            case kVfLp6: y = v.lp6.low(y); break;
            case kVfLp12: y = v.svf.lowpass(y); break;
            case kVfHp: y = v.svf.highpass(y); break;
            case kVfBp: y = v.svf.bandpass(y); break;
            default: break;
        }
        if (v.drivePost) y = driveStage(v, y, os);
        if (v.ringMix > 0.0) {  // the ring modulator (1.1.0)
            y += (y * lib::fastSinCycles(v.ringPhase) - y) * v.ringMix;
            v.ringPhase += v.ringDt;
            v.ringPhase -= std::floor(v.ringPhase);
        }
        if (v.eq) y = v.eqHigh.process(v.eqMid.process(v.eqLow.process(y)));
        if (v.shaper) {
            const double a = y < 0.0 ? -y : y;
            const double f = v.fast.process(a), s = v.slow.process(a);
            double d = (f - s) / (s + 1e-6);
            d = d > 1.0 ? 1.0 : (d < -1.0 ? -1.0 : d);
            y *= lib::dbToGain(d > 0.0 ? 9.0 * v.trA * d : -9.0 * v.trS * d);  // up to 9 dB either way
        }
        if (v.comp) {
            const double a = y < 0.0 ? -y : y;
            const double level = lib::gainToDb(v.compEnv.process(a));
            v.gr = lib::compressorGainDb(level, v.compThr, v.compRatio, 6.0);
            y *= lib::dbToGain(v.gr) * v.compMakeup;
        }
        if (v.clipper.type != kDriveOff) {  // the clipper: last in the chain, the ceiling at full scale
            // A clean sub joins the clipper's input (it clips the whole kick, as a mix engineer's clipper would); the
            // width's high-pass keeps it mono all the same.
            y = ceiling(v.clipper.process(y + subY, os));
            subY = 0.0;
        }
        double fade = 1.0;
        if (v.fading) {
            v.fadeGain *= v.fadeCoef;
            fade *= v.fadeGain;
        }
        if (v.releasing) {
            v.relGain *= v.relCoef;
            fade *= v.relGain;
        }
        if (v.dampCoef < 1.0) v.dampGain *= v.dampCoef;
        fade *= v.dampGain;
        v.subOut = subY * fade;
        y *= fade;
        if (v.wide) {  // the side: the voice 0.4 ms later, its low end taken out, so the sum to mono cancels it
            const float delayed = v.widthBuf[(v.widthAt - v.widthDelay) & 127u];
            v.widthBuf[v.widthAt & 127u] = static_cast<float>(y);
            ++v.widthAt;
            v.side = v.widthHp2.highpass(v.widthHp.highpass(delayed)) * v.width;  // 24 dB an octave
        }
        return y;
    }

    // ---------- The echo (1.1.0) ----------

    void clearEcho() noexcept {
        std::fill(echoL_.begin(), echoL_.end(), 0.0f);
        std::fill(echoR_.begin(), echoR_.end(), 0.0f);
        echoLpL_ = echoLpR_ = 0.0;
        echoW_ = 0;
        echoQuiet_ = 0;
        echoOn_ = false;
    }
    void echo(double in, double& outL, double& outR) noexcept {
        const uint32_t size = static_cast<uint32_t>(echoL_.size());
        echoDelay_ += clampd(echoTarget_ - echoDelay_, -0.5, 0.5);  // a time change glides (a tape's pitch bend)
        double r = static_cast<double>(echoW_) - echoDelay_;
        if (r < 0.0) r += size;
        const uint32_t i = static_cast<uint32_t>(r);
        const double f = r - i;
        const uint32_t j = i + 1 < size ? i + 1 : 0;
        const double dl = echoL_[i] + (echoL_[j] - echoL_[i]) * f, dr = echoR_[i] + (echoR_[j] - echoR_[i]) * f;
        echoLpL_ += (dl - echoLpL_) * echoK_;
        echoLpR_ += (dr - echoLpR_) * echoK_;
        const double s = echoSpread_, keep = 1.0 - s;
        echoL_[echoW_] = static_cast<float>(in + echoFb_ * (keep * echoLpL_ + s * echoLpR_));
        echoR_[echoW_] = static_cast<float>(in * keep + echoFb_ * (keep * echoLpR_ + s * echoLpL_));
        if (++echoW_ >= size) echoW_ = 0;
        outL = echoLpL_;  // every repeat through the tone, the first too
        outR = echoLpR_;
    }

    // The clippers' last word: the oversampled curve's ripple (a few per cent) never passes full scale.
    static double ceiling(double x) noexcept { return x > 1.0 ? 1.0 : (x < -1.0 ? -1.0 : x); }

    // Drive with its high-pass before, low-pass after, and dry/wet mix.
    static double driveStage(DrumVoice& v, double x, int os) noexcept {
        if (v.drive.type == kDriveOff) return x;
        double w = v.driveLoOn ? v.driveLo.high(x) : x;
        w = v.drive.process(w, os);
        if (v.driveHiOn) w = v.driveHi.lowpass(w);
        return v.driveMix >= 1.0 ? w : x + (w - x) * v.driveMix;
    }
