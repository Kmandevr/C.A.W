// DrumsProcessor's starting a voice and updating its coefficients (hand-written; included by builtin_drums.cpp, not compiled alone).
    // ---------- Starting and updating a voice ----------

    void start(DrumVoice& v, const PadSettings& s, double smpOffset = 0.0) noexcept {
        v.invSr = 1.0 / sr_;
        coefficients(v, s, true);
        if (v.body) {
            v.bodyEnv.trigger();
            v.pitchEnv.start();
            v.phase = s.phase;
            v.phase2 = s.phase;
            v.pSeg = 0;
            v.pPos = 0;
        }
        if (v.sub) {
            v.subEnv.trigger();
            v.subPhase = 0.0;
        }
        if (v.click) {
            v.clickEnv.set(0.0001, 0.0, s.clickLength, 0.0, sr_);
            v.clickEnv.trigger();
        }
        if (v.noise) {
            v.clapCount = 0;
            v.clapPeriod = std::max<uint32_t>(1, static_cast<uint32_t>(s.spacing * sr_));
            v.clapBursts = s.noiseMode == kNoiseClap ? static_cast<uint32_t>(s.bursts) : 0;
            v.burstCoef = fall(3.0 * s.spacing, sr_);
            if (s.noiseMode == kNoiseClap) v.burst = 0.0;
            else v.noiseEnv.trigger();
        }
        if (v.metal) {
            for (double& p : v.mPhase) p = 0.0;
            v.metalEnv.trigger();
        }
        if (v.res) {
            v.modal.clear();
            v.exciteAt = 0;
            // A softer mallet (or a softer hit: velocity to tone) strikes longer, so it excites fewer high modes.
            const double width = (0.0005 + (1.0 - s.bright) * 0.002) * exp2d(-0.5 * v.var.toneOct);
            v.exciteLength = s.exciter == kExciteNoise ? static_cast<uint32_t>(0.008 * sr_)
                                                       : std::max<uint32_t>(2, static_cast<uint32_t>(width * sr_));
            v.exciteLeft = s.exciter == kExciteLayers ? 0 : v.exciteLength;
            v.ringing = true;
        }
        if (v.smp && v.sample) {
            const double len = static_cast<double>(v.sample->data.size());
            double a = s.start * (len - 1.0), z = s.end * (len - 1.0);
            if (z < a) std::swap(a, z);
            v.smpFirst = a;
            v.smpLast = z;
            v.reverse = s.reverse;
            v.smpPos = s.reverse ? z : a;
            if (smpOffset > 0.0) v.smpPos = s.reverse ? std::max(a, z - smpOffset) : std::min(z, a + smpOffset);
            v.smpPlaying = z > a;
            v.smpEnv.set(s.smpAttack, 0.0, s.smpDecay, 0.0, sr_);
            if (s.smpHold > 0.0 || s.smpCurve != 0.0) v.smpEnv.set(s.smpAttack, s.smpHold, s.smpDecay, s.smpCurve, sr_);
            v.smpEnv.trigger();
            if (s.smpPitch > 0.0) {
                v.smpPEnv.set(0.0, 0.0, s.smpPTime, 0.0, sr_);
                v.smpPEnv.start();
            }
        }
        if (v.fm) {
            v.fmEnv.trigger();
            v.fmIEnv.start();
            v.fmPEnv.start();
            v.fmPhaseC = v.fmPhaseM = v.fmPrev = 0.0;
        }
        if (v.phys && v.physLine) {
            const uint32_t clear = std::min<uint32_t>(v.physMax, static_cast<uint32_t>(v.physDelay) + 4);
            for (uint32_t i = 0; i < clear; ++i) v.physLine[i] = 0.0f;
            v.physW = 0;
            v.physLp = v.physAp = v.physApIn = 0.0;
            v.physExciteLength = s.physExciter == kPhysNoise ? static_cast<uint32_t>(0.01 * sr_)
                                                            : std::max<uint32_t>(2, static_cast<uint32_t>(v.physDelay));
            v.physExciteLeft = v.physExciteLength;
            v.physPeak = 1.0;
        } else {
            v.phys = false;
        }
        if (v.tex) {
            v.texEnv.trigger();
            v.texGrain = 0.0;
        }
        v.fltEnvLevel = 1.0;
    }

    // The voice's coefficients from its pad's settings, its variation, glide and pressure (each control).
    void coefficients(DrumVoice& v, const PadSettings& s, bool first) noexcept {
        const double sr = sr_;
        const bool eco = v.quality == kQualityEco;
        if (!first) v.glideSt += (v.glideTarget - v.glideSt) * (1.0 - lib::fastExp(-3.0 * kControlFrames / (s.glide * sr)));
        double st = s.tune + v.var.pitch + v.glideSt;
        double toneOct = v.var.toneOct;
        // Pressure (polyphonic aftertouch) as a modulation source: one amount per destination.
        const double p = v.pressure;
        st += s.pressPitch * p;
        toneOct += 4.0 * s.pressTone * p;
        if (s.pressChoke && p > 0.5) fade(v);
        const double damp = s.pressDamp * p;
        v.dampCoef = damp > 0.0 ? fall(0.03 / damp, sr) : 1.0;
        const double mul = exp2d(st / 12.0);
        const double decayMul = v.var.decayMul;
        if (first) {
            v.body = s.bodyOn;
            v.sub = s.subOn;
            v.click = s.clickOn;
            v.noise = s.noiseOn;
            v.metal = s.metalOn;
            v.res = s.resOn;
            v.smp = s.smpOn;
            v.fm = s.fmOn;
            v.phys = s.physOn;
            v.tex = s.texOn;
        }
        if (v.body) {
            v.wave = s.wave;
            v.fEnd = s.freq * mul;
            v.fStart = v.fEnd * exp2d(s.pitchSt * v.var.punch / 12.0);
            v.points = s.points;
            if (s.points) {  // segment k runs from point k-1 (point 0: the pitch envelope's depth) to point k
                double from = s.pitchSt;
                for (int k = 0; k < 4; ++k) {
                    v.pLen[k] = std::max<uint32_t>(1, static_cast<uint32_t>(s.pt[k] * sr));
                    v.pFrom[k] = from * v.var.punch;
                    v.pTo[k] = s.pp[k] * v.var.punch;
                    v.pK[k] = 1.0 + 7.0 * std::fabs(s.pc[k]);
                    v.pSign[k] = s.pc[k] > 0.0 ? 1.0 : (s.pc[k] < 0.0 ? -1.0 : 0.0);
                    from = s.pp[k];
                }
            } else {
                v.pitchEnv.set(0.0, 0.0, s.ptime, s.pcurve, sr);
            }
            v.bodyEnv.set(s.attack, s.hold, s.decay * decayMul, s.dcurve, sr);
            v.p2ratio = s.p2ratio;
            v.p2level = s.p2level;
            v.shapeAmt = s.shape > 0.0 ? 1.0 + 9.0 * s.shape : 0.0;
            v.shapeNorm = s.shapeNorm;
            v.fold = s.fold > 0.0 ? 1.0 + 5.0 * s.fold : 0.0;
            v.bodyLevel = s.bodyLevel;
        }
        if (v.sub) {
            v.subDt = s.freq * mul * s.subMul * v.invSr;
            v.subWave = s.subWave;
            v.subFollow = v.body ? s.subFollow : 0.0;
            v.subEnv.set(s.subAttack, s.subHold, s.subDecay * decayMul, s.subCurve, sr);
            v.subDrive = s.subDrive > 0.0 ? 1.0 + 9.0 * s.subDrive : 0.0;
            v.subNorm = v.subDrive > 0.0 ? 1.0 / lib::tanhApprox(v.subDrive) : 1.0;
            v.subFilter = s.subLp < 1999.0;
            if (v.subFilter) v.subLpf.set(s.subLp, sr);
            v.subClean = s.subClean;
            v.subLevel = s.subLevel;
        }
        if (v.click) {
            v.clickType = s.clickType;
            // Velocity to tone moves the click too: a harder beater or stick is brighter.
            const double tone = clampd(s.clickTone * exp2d(0.5 * toneOct), 50, 0.45 * sr);
            v.clickTone = tone * mul;
            v.clickLevel = s.clickLevel * v.var.click;
            if (s.clickType == kClickNoise) v.clickHp.set(tone, sr);
            else if (s.clickType == kClickImpulse) v.clickHp.set(tone, sr);
            else if (s.clickType == kClickPop) v.clickBp.set(tone, 3.0, sr);
        }
        if (v.noise) {
            v.noiseMode = s.noiseMode;
            v.color = s.color;
            v.noiseFilter = s.noiseFilter;
            v.noiseLevel = s.noiseLevel;
            if (s.noiseMode == kNoiseClap) v.tailEnv.set(s.noiseAttack, 0.0, s.noiseDecay * decayMul, s.noiseCurve, sr);
            else v.noiseEnv.set(s.noiseAttack, 0.0, s.noiseDecay * decayMul, s.noiseCurve, sr);
            const double env = s.noiseMode == kNoiseClap ? std::max(v.burst, v.tailEnv.level) : v.noiseEnv.level;
            const double f = clampd(s.noiseFreq * exp2d(s.sweep * env + toneOct), 20, 0.45 * sr);
            if (s.noiseFilter != kFilterOff) v.noiseSvf.set(f, s.noiseQ, sr);
            if (first) {
                const double corners[3] = {80.0, 800.0, 6000.0};
                for (int k = 0; k < 3; ++k) v.pinkK[k] = 1.0 - lib::fastExp(-kTwoPi * corners[k] / sr);
                v.brownK = 1.0 - lib::fastExp(-kTwoPi * 40.0 / sr);
                v.wireK = 1.0 - lib::fastExp(-1.0 / (0.004 * sr));
                v.shellDt = 190.0 / sr;
                v.shellCoef = fall(0.35, sr);
            }
            v.crushEvery = std::max<uint32_t>(1, static_cast<uint32_t>(sr / f));
        }
        if (v.metal) {
            v.metalMode = s.metalMode;
            const double base = s.metalFreq * mul;
            const double rate = v.quality == kQualityHigh ? 0.5 : 1.0;  // High runs it at twice the rate
            for (int i = 0; i < 6; ++i) {
                double f = base * s.ratio[i];
                v.mAmp[i] = f < 0.45 * sr ? s.amp[i] : 0.0;
                v.mDt[i] = f * v.invSr * rate;
            }
            v.fmIndex = s.fm / kTwoPi;
            v.metalNoise = s.metalNoise;
            v.band = s.band;
            v.bandGain = 1.0 / s.metalQ;
            v.metalLevel = s.metalLevel;
            v.metalBp.set(clampd(s.metalColor * exp2d(toneOct), 100, 0.45 * sr), s.metalQ, sr);
            v.metalHp.set(clampd(s.metalTone * exp2d(toneOct), 100, 0.45 * sr), s.metalQ, sr);
            v.metalEnv.set(s.metalAttack, 0.0, s.metalDecay * decayMul, s.metalCurve, sr);
        }
        if (v.res) {
            lib::ModalSettings m;
            m.model = static_cast<lib::ModalModel>(s.model);
            m.frequency = s.resFreq * mul;
            m.decay = s.resDecay * decayMul;
            m.damping = s.damp;
            m.brightness = clampd(s.bright + 0.15 * toneOct, 0, 1);
            m.inharmonicity = s.inharm;
            m.position = clampd(s.pos + v.var.pos, 0, 1);
            m.modes = v.quality == kQualityEco ? 8 : (v.quality == kQualityHigh ? 32 : 16);
            if (first || m.model != v.modalSet.model || m.frequency != v.modalSet.frequency || m.decay != v.modalSet.decay ||
                m.damping != v.modalSet.damping || m.brightness != v.modalSet.brightness ||
                m.inharmonicity != v.modalSet.inharmonicity || m.position != v.modalSet.position || m.modes != v.modalSet.modes) {
                v.modal.set(m, sr);
                v.modalSet = m;
            }
            v.exciter = s.exciter;
            v.resInput = s.input;
            v.resLevel = s.resLevel;
        }
        if (v.smp) {
            v.smpStep = exp2d((s.smpTune + st) / 12.0);
            v.smpLevel = s.smpLevel;
            if (s.smpHold > 0.0 || s.smpCurve != 0.0) {
                v.smpEnv.set(s.smpAttack, s.smpHold, s.smpDecay * decayMul, s.smpCurve, sr);
            } else {
                v.smpEnv.coef = fall(s.smpDecay * decayMul, sr);
                v.smpEnv.coefFast = v.smpEnv.coef;
            }
            v.smpDrop = s.smpPitch;
            if (s.smpPitch > 0.0) v.smpPEnv.set(0.0, 0.0, s.smpPTime, 0.0, sr);
        }
        if (v.fm) {
            v.fmF = s.fmFreq * mul;
            v.fmStartMul = exp2d(s.fmPitch * v.var.punch / 12.0);
            v.fmRatio = s.fmRatio;
            // Velocity to tone deepens the modulation: a harder hit is brighter.
            v.fmDepth = s.fmIndex * exp2d(0.5 * toneOct) / kTwoPi;
            v.fmFb = 0.3 * s.fmFb;
            v.fmLevel = s.fmLevel;
            v.fmEnv.set(s.fmAttack, 0.0, s.fmDecay * decayMul, s.fmCurve, sr);
            v.fmIEnv.set(0.0, 0.0, s.fmIDecay * decayMul, 0.0, sr);
            v.fmPEnv.set(0.0, 0.0, s.fmPTime, 0.0, sr);
        }
        if (v.phys) {
            // The loop: a delay of one period (half of one, inverted, for a pipe: odd harmonics), a one-pole loss
            // filter, the stiff string's all-pass; its gain falls 60 dB over the decay.
            const double f = clampd(s.physFreq * mul, 20.0, 0.25 * sr);
            const double period = sr / f * (s.physModel == kPhysPipe ? 0.5 : 1.0);
            v.physDelay = clampd(period - (s.physModel == kPhysStiff ? 1.5 : 0.5), 2.0, static_cast<double>(v.physMax) - 3.0);
            v.physSign = s.physModel == kPhysPipe ? -1.0 : 1.0;
            const double damp = clampd(s.physDamp - 0.25 * toneOct, 0, 1);
            v.physLpK = 1.0 - 0.95 * damp;  // the share of each new sample (1: no loss)
            v.physApK = s.physModel == kPhysStiff ? -0.6 : 0.0;
            v.physGain = lib::fastExp(-kSixtyDb * period / (s.physDecay * decayMul * sr));
            v.physPickDelay = clampd(s.physPick * 0.5 * period, 0.0, v.physDelay);
            v.physModel = s.physModel;
            v.physExciter = s.physExciter;
            v.physInput = s.physExciter == kPhysLayers ? s.physInput : 0.0;
            v.physLevel = s.physLevel;
        }
        if (v.tex) {
            v.texMode = s.texMode;
            const double f = clampd(s.texFreq * exp2d(toneOct), 40, 0.45 * sr);
            v.texLo.set(f, s.texQ, sr);
            v.texHi.set(clampd(f * exp2d(s.texSpread), 40, 0.45 * sr), s.texQ, sr);
            // Bands: the tilt shares the level between the two bands (an SVF's band peaks at q: unity at the centre).
            v.texLoGain = (s.texMode == kTexBands ? 1.0 - 0.5 * (1.0 + s.texTilt) : 1.0) * 2.0 / s.texQ;
            v.texHiGain = 0.5 * (1.0 + s.texTilt) * 2.0 / s.texQ;
            v.texChance = clampd(s.texDensity / sr, 0, 1);
            v.texGrainK = fall(0.002, sr);
            // Sparse grains carry as much energy as dense ones: louder the sparser.
            v.texScale = s.texMode == kTexBands ? 1.0 : std::min(8.0, std::sqrt(1.0 / std::max(v.texChance, 1e-6)) * 0.35);
            v.texEnv.set(s.texAttack, 0.0, s.texDecay * decayMul, s.texCurve, sr);
            v.texLevel = s.texLevel;
        }
        v.ringMix = s.ringMix;
        if (s.ringMix > 0.0) v.ringDt = clampd(s.ringFreq * mul, 20, 0.45 * sr) / sr;
        v.echoSend = s.echoSend;
        v.busSend = s.busSend;
        // Effects.
        v.drive.set(s.driveType, s.driveType != kDriveOff && s.pressDrive > 0.0 ? s.drive * exp2d(3.0 * s.pressDrive * p)
                                                                                 : s.drive);
        v.drivePost = s.drivePost;
        v.driveMix = s.driveMix;
        v.driveLoOn = s.driveType != kDriveOff && s.driveLo > 20.5;
        v.driveHiOn = s.driveType != kDriveOff && s.driveHi < 19999.0;
        if (v.driveLoOn) v.driveLo.set(s.driveLo, sr);
        if (v.driveHiOn) v.driveHi.set(clampd(s.driveHi, 20, 0.45 * sr), 0.70710678118654752, sr);
        v.clipper.set(s.clip == kClipSoft ? kDriveClipSoft : (s.clip == kClipHard ? kDriveHard : kDriveOff), s.clipGain);
        v.flt = s.flt;
        if (first) v.fltEnvCoef = lib::fastExp(-kSixtyDb * kControlFrames / (s.fltDecay * sr));
        const double fc = clampd(s.cutoff * exp2d(s.fltEnv * v.fltEnvLevel + toneOct), 20, 0.45 * sr);
        if (!first) {
            v.fltEnvLevel *= v.fltEnvCoef;
            v.fltEnvCoef = lib::fastExp(-kSixtyDb * kControlFrames / (s.fltDecay * sr));
        }
        if (s.flt == kVfLp6) v.lp6.set(fc, sr);
        else if (s.flt != kVfOff) v.svf.set(fc, s.fltQ, sr);
        v.eq = s.eqLow != 0.0 || s.eqMid != 0.0 || s.eqHigh != 0.0;
        if (v.eq) {
            v.eqLow.set(lib::EqBand::Kind::LowShelf, s.eqLowFreq, s.eqLow, 0.70710678118654752, sr);
            v.eqMid.set(lib::EqBand::Kind::Bell, s.eqFreq, s.eqMid, s.eqQ, sr);
            v.eqHigh.set(lib::EqBand::Kind::HighShelf, std::min(s.eqHighFreq, 0.4 * sr), s.eqHigh, 0.70710678118654752, sr);
        }
        v.shaper = s.trA != 0.0 || s.trS != 0.0;
        v.trA = s.trA;
        v.trS = s.trS;
        if (first) {
            v.fast.setCoefficients(lib::timeCoefficient(0.0005, sr), lib::timeCoefficient(0.015, sr));
            v.slow.setCoefficients(lib::timeCoefficient(0.015, sr), lib::timeCoefficient(0.15, sr));
        }
        if (s.compAttack != v.compA || s.compRelease != v.compR) {
            v.compA = s.compAttack;
            v.compR = s.compRelease;
            v.compEnv.setCoefficients(lib::timeCoefficient(s.compAttack, sr), lib::timeCoefficient(s.compRelease, sr));
        }
        v.comp = s.comp > 0.0;
        v.compThr = -6.0 - 24.0 * s.comp;
        v.compRatio = 1.0 + 9.0 * s.comp;
        v.compMakeup = lib::dbToGain(-0.35 * v.compThr * (1.0 - 1.0 / v.compRatio));
        // Level and pan: a balance with the centre at full level on both sides (a mono drum stays as loud as it was);
        // toward a side, the other falls along a quarter cosine.
        const double g = s.gain * v.var.gain * (s.pressLevel != 0.0 ? exp2d(2.0 * s.pressLevel * p) : 1.0),
                     pan = v.var.pan;
        v.gainMid = g;
        v.roomSend = s.roomSend;
        v.wide = s.width > 0.0;
        v.width = s.width * g;
        if (v.wide) {
            v.widthDelay = std::min<uint32_t>(127, std::max<uint32_t>(1, static_cast<uint32_t>(0.0004 * sr)));
            v.widthHp.set(s.widthHz, 0.5412, sr);  // two 2-pole stages: a 4th-order Butterworth high-pass
            v.widthHp2.set(s.widthHz, 1.3066, sr);
        }
        v.gainL = g * (pan <= 0.0 ? 1.0 : lib::fastSinCycles(0.25 + 0.25 * pan));
        v.gainR = g * (pan >= 0.0 ? 1.0 : lib::fastSinCycles(0.25 - 0.25 * pan));
        (void)eco;
    }
