// Drums' PadSettings: a pad's settings worked out from its knobs and macros (readPad) (hand-written; included by builtin_drums.cpp, not compiled alone).
// ---------- A pad's settings, worked out from its knobs and macros ----------

struct PadSettings {
    double gain = 1, pan = 0, tune = 0, root = 60, glide = 0.08, release = 0.1;
    int type = kTypePerc, poly = 2, choke = 0, out = 0;
    bool track = false, mono = false, gate = false;
    // pressure (polyphonic aftertouch) amounts
    double pressDamp = 0, pressTone = 0, pressPitch = 0, pressLevel = 0, pressDrive = 0;
    bool pressChoke = false;
    // body
    bool bodyOn = false;
    int wave = 0;
    double shape = 0, shapeNorm = 1, fold = 0, freq = 55, pitchSt = 24, ptime = 0.05, pcurve = 0, attack = 0.0005,
           hold = 0, decay = 0.4, dcurve = 0, p2ratio = 1.5, p2level = 0, phase = 0, bodyLevel = 1;
    // pitch shape (breakpoints)
    bool points = false;
    double pt[4] = {}, pp[4] = {}, pc[4] = {};
    // sub
    bool subOn = false, subClean = true;
    int subWave = 0;
    double subMul = 0.5, subFollow = 0, subAttack = 0.005, subHold = 0, subDecay = 0.6, subCurve = 0, subDrive = 0,
           subLp = 2000, subLevel = 0.5;
    // click
    bool clickOn = false;
    int clickType = 0;
    double clickLevel = 0.5, clickTone = 2000, clickLength = 0.008;
    // noise
    bool noiseOn = false;
    int noiseMode = 0, color = 0, noiseFilter = kFilterHp, bursts = 3;
    double noiseFreq = 2000, noiseQ = 0.707, sweep = 0, noiseAttack = 0.001, noiseDecay = 0.2, noiseCurve = 0,
           spacing = 0.01, noiseLevel = 1;
    // metal
    bool metalOn = false;
    int metalMode = 0, metalSet = 0;
    double metalFreq = 410.6, ratio[6] = {}, amp[6] = {}, fm = 2, metalTone = 7000, metalColor = 8000, band = 0,
           metalQ = 1.2, metalAttack = 0.0005, metalDecay = 0.05, metalCurve = 0, metalNoise = 0.5, metalLevel = 1;
    // resonator
    bool resOn = false;
    int model = 0, exciter = kExciteMallet;
    double resFreq = 150, resDecay = 0.6, damp = 0.4, bright = 0.5, inharm = 0, pos = 0.3, input = 0.2, resLevel = 1;
    // sample
    bool smpOn = false, reverse = false;
    double start = 0, end = 1, smpTune = 0, smpAttack = 0.0001, smpDecay = 30, smpLevel = 1;
    // effects
    int driveType = 0, flt = 0;
    bool drivePost = false;
    double drive = 2, driveLo = 20, driveHi = 20000, driveMix = 1, cutoff = 12000, fltQ = 0.707, fltEnv = 0,
           fltDecay = 0.2, eqLow = 0, eqLowFreq = 120, eqMid = 0, eqFreq = 1000, eqQ = 1, eqHigh = 0, eqHighFreq = 6000,
           trA = 0, trS = 0, comp = 0, compAttack = 0.002, compRelease = 0.06, clipGain = 1, width = 0, widthHz = 200,
           roomSend = 1;
    int clip = 0;
    // variation
    double velLevel = 1, velPitch = 0, velDecay = 0, velTone = 0.3, velClick = 0.5, velPunch = 0, rndPitch = 0,
           rndDecay = 0, rndTone = 0, rndPan = 0, rndLevel = 0, rndPos = 0;
    // fm, phys, tex (1.1.0)
    bool fmOn = false, physOn = false, texOn = false;
    double fmFreq = 200, fmRatio = 1.41, fmIndex = 3, fmIDecay = 0.08, fmFb = 0, fmPitch = 0, fmPTime = 0.03,
           fmAttack = 0.0005, fmDecay = 0.3, fmCurve = 0, fmLevel = 1;
    int physModel = 0, physExciter = 0, texMode = 0;
    double physFreq = 110, physDecay = 1, physDamp = 0.4, physPick = 0.2, physInput = 0.3, physLevel = 1;
    double texFreq = 3000, texSpread = 1.5, texQ = 1, texTilt = 0, texDensity = 1500, texAttack = 0.001, texDecay = 0.25,
           texCurve = 0, texLevel = 1;
    // the sample's pitch drop, hold, curve and start (1.1.0)
    double smpPitch = 0, smpPTime = 0.05, smpHold = 0, smpCurve = 0, smpVelStart = 0, smpRndStart = 0;
    // pad effects and sends (1.1.0)
    double ringMix = 0, ringFreq = 440, echoSend = 0, busSend = 1;
    // groove (1.1.0)
    double swing = 0, humanize = 0, accent = 0, flam = 0, flamTime = 0.02, grooveAmt = 1;
    int swingGrid = 0, accentOn = 0, groove = 0;
    bool groovy = false;  // any of them on: a hit may move, repeat or be accented
    // 1.1.2: an Acoustic pad's piece and articulation; a Layers pad's acoustic layer (0: none, else piece + 1)
    int engine = kEngineLayers, acouPiece = 0, acouArtic = kArtHit, acouLayer = 0;
    bool layers = false;  // any layer on
    bool used = false;  // any layer on (or a piece to strike) and the pad not silent
    double raw[kPadParams] = {};  // the knobs these were worked out from
    bool valid = false;
    bool perFrame = false;          // some knob moved within the block it was read in (a ramp, a lane)
    uint64_t block = ~0ull;         // the block it was read in
};

// Reads pad `pad`'s knobs at frame `at` and applies its macros (docs/engine.md, "Drums", Character macros).
// `block` counts the instrument's blocks: knobs that hold one value for the block are read once in it.
void readPad(const ProcessBlock& b, uint32_t pad, uint32_t at, PadSettings& s, uint64_t block = ~0ull) noexcept {
    // The knobs first; when none moved since the last read, the settings stand (most controls of a hit).
    if (block != ~0ull && s.block == block && !s.perFrame && s.valid) return;
    s.block = block;
    const Voice& def = defaultVoice(pad);
    double raw[kPadParams];
    const uint32_t first = padParam(pad, 0);
    if (b.parameters && first + kPadParams <= b.parameterCount) {
        bool perFrame = false;
        for (uint32_t p = 0; p < kPadParams; ++p) {
            const ParameterValue& pv = b.parameters[first + p];
            raw[p] = pv.samples ? pv.samples[at] : pv.value;
            perFrame = perFrame || pv.samples;
        }
        s.perFrame = perFrame;
    } else {
        for (uint32_t p = 0; p < kPadParams; ++p) raw[p] = def[p];
    }
    if (s.valid && std::memcmp(raw, s.raw, sizeof raw) == 0) return;
    std::memcpy(s.raw, raw, sizeof raw);
    s.valid = true;
    auto v = [&](uint32_t p) noexcept { return raw[p]; };
    auto on = [&](uint32_t p) noexcept { return v(p) >= 0.5; };
    const double punch = clampd(v(kPunch), -1, 1), tone = clampd(v(kTone), -1, 1), snap = clampd(v(kSnap), -1, 1),
                 length = clampd(v(kLength), -1, 1), dirt = clampd(v(kDirt), -1, 1), pitch = clampd(v(kPitch), -1, 1);
    const double lengthMul = exp2d(2.0 * length);
    s.gain = dbGain(v(kLevel));
    s.pan = clampd(v(kPan), -1, 1);
    s.tune = clampd(v(kTune), -48, 48) + 12.0 * pitch;
    s.track = on(kTrack);
    s.root = clampd(v(kRoot), 0, 127);
    s.mono = on(kMono);
    s.glide = clampd(v(kGlide), 0.001, 2);
    s.gate = clampi(v(kTrig), 0, 1) == kGate;
    s.release = clampd(v(kRelease), 0.001, 5);
    s.poly = clampi(v(kPoly), 1, 4);
    s.choke = clampi(v(kChoke), 0, 8);
    s.out = clampi(v(kOut), 0, static_cast<int>(kOutputs) - 1);
    s.pressDamp = clampd(v(kPressDamp), 0, 1);
    s.pressChoke = on(kPressChoke);
    s.pressTone = clampd(v(kPressTone), -1, 1);
    s.pressPitch = clampd(v(kPressPitch), -12, 12);
    s.pressLevel = clampd(v(kPressLevel), -1, 1);
    s.pressDrive = clampd(v(kPressDrive), 0, 1);
    s.type = clampi(v(kType), 0, kTypeCount - 1);

    s.bodyOn = on(kBodyOn);
    if (s.bodyOn) {
        s.wave = clampi(v(kBodyWave), 0, kWaveSquare);
        s.shape = clampd(v(kBodyShape), 0, 1);
        s.shapeNorm = s.shape > 0 ? 1.0 / lib::tanhApprox(1.0 + 9.0 * s.shape) : 1.0;
        s.fold = clampd(v(kBodyFold), 0, 1);
        s.freq = clampd(v(kBodyFreq), 20, 2000);
        s.pitchSt = clampd(v(kBodyPitch) + 12.0 * punch, 0, 96);
        s.ptime = clampd(v(kBodyPTime) * exp2d(-0.7 * punch), 0.001, 2);
        s.pcurve = clampd(v(kBodyPCurve), -1, 1);
        s.attack = clampd(v(kBodyAttack), 0.0001, 0.5);
        s.hold = clampd(v(kBodyHold) * exp2d(length), 0, 2);
        s.decay = clampd(v(kBodyDecay) * lengthMul, 0.005, 40);
        s.dcurve = clampd(v(kBodyDCurve), -1, 1);
        s.p2ratio = clampd(v(kBodyP2Ratio), 0.5, 8);
        s.p2level = clampd(v(kBodyP2Level), 0, 1);
        s.phase = clampd(v(kBodyPhase), 0, 1);
        s.bodyLevel = dbGain(v(kBodyLevel));
        s.points = clampi(v(kPenvMode), 0, 1) == kPenvPoints;
        if (s.points) {
            const double timeMul = exp2d(-0.7 * punch);
            for (int k = 0; k < 4; ++k) {
                s.pt[k] = clampd(v(kPenvT1 + 3 * k) * timeMul, 0.0005, 2);
                s.pp[k] = clampd(v(kPenvP1 + 3 * k), -24, 96);
                s.pc[k] = clampd(v(kPenvC1 + 3 * k), -1, 1);
            }
        }
    }
    if (!s.bodyOn) s.freq = clampd(v(kBodyFreq), 20, 2000);  // the sub's pitch
    s.subOn = on(kSubOn);
    if (s.subOn) {
        s.subWave = clampi(v(kSubWave), 0, kSubWarm);
        s.subMul = exp2d(-clampi(v(kSubOct), 0, 2) + clampd(v(kSubFine), -12, 12) / 12.0);
        s.subFollow = clampd(v(kSubFollow), 0, 1);
        s.subAttack = clampd(v(kSubAttack), 0.0001, 0.5);
        s.subHold = clampd(v(kSubHold) * exp2d(length), 0, 2);
        s.subDecay = clampd(v(kSubDecay) * lengthMul, 0.005, 40);
        s.subCurve = clampd(v(kSubDCurve), -1, 1);
        s.subDrive = clampd(v(kSubDrive), 0, 1);
        s.subLp = clampd(v(kSubLp), 40, 2000);
        s.subClean = clampi(v(kSubRoute), 0, 1) == kSubClean;
        s.subLevel = dbGain(v(kSubLevel));
    }
    s.clickOn = on(kClickOn);
    if (s.clickOn) {
        s.clickType = clampi(v(kClickType), 0, kClickPop);
        s.clickLevel = clampd(v(kClickLevel) * exp2d(1.5 * punch + snap), 0, 4);
        s.clickTone = clampd(v(kClickTone) * exp2d(1.5 * tone), 50, 20000);
        s.clickLength = clampd(v(kClickLength), 0.0005, 0.1);
    }
    s.noiseOn = on(kNoiseOn);
    if (s.noiseOn) {
        s.noiseMode = clampi(v(kNoiseMode), 0, kNoiseClap);
        s.color = clampi(v(kNoiseColor), 0, kCrushed);
        s.noiseFilter = clampi(v(kNoiseFilter), 0, kFilterHp);
        s.noiseFreq = clampd(v(kNoiseFreq) * exp2d(1.5 * tone), 20, 20000);
        s.noiseQ = lib::resonanceQ(clampd(v(kNoiseRes), 0, 1));
        s.sweep = clampd(v(kNoiseSweep), -6, 6);
        s.noiseAttack = clampd(v(kNoiseAttack), 0.0001, 1);
        s.noiseDecay = clampd(v(kNoiseDecay) * lengthMul, 0.003, 40);
        s.noiseCurve = clampd(v(kNoiseDCurve), -1, 1);
        s.bursts = clampi(v(kNoiseBursts), 1, 8);
        s.spacing = clampd(v(kNoiseSpacing), 0.002, 0.05);
        s.noiseLevel = dbGain(v(kNoiseLevel)) * exp2d(0.8 * snap);
    }
    s.metalOn = on(kMetalOn);
    if (s.metalOn) {
        s.metalMode = clampi(v(kMetalMode), 0, kMetalRing);
        s.metalSet = clampi(v(kMetalSet), 0, kSetCount - 1);
        s.metalFreq = clampd(v(kMetalFreq), 50, 2000);
        const double stretch = 1.0 + 0.5 * clampd(v(kMetalSpread), -1, 1);
        const MetalSet& set = kMetalSets[s.metalSet];
        double sum = 0.0;
        for (int i = 0; i < 6; ++i) {
            s.ratio[i] = detPow(set.ratio[i], stretch);
            s.amp[i] = set.amp[i];
            sum += set.amp[i];
        }
        for (double& a : s.amp) a /= sum;
        s.fm = clampd(v(kMetalFm), 0, 10);
        s.metalTone = clampd(v(kMetalTone) * exp2d(tone), 100, 20000);
        s.metalColor = clampd(v(kMetalColor) * exp2d(tone), 100, 20000);
        s.band = clampd(v(kMetalBand), 0, 1);
        s.metalQ = lib::resonanceQ(clampd(v(kMetalRes), 0, 1));
        s.metalAttack = clampd(v(kMetalAttack), 0.0001, 0.5);
        const double open = clampd(v(kMetalOpen), 0, 1);
        s.metalDecay = clampd(v(kMetalDecay) * (1.0 + 15.0 * open * open) * lengthMul, 0.003, 60);
        s.metalCurve = clampd(v(kMetalDCurve), -1, 1);
        s.metalNoise = clampd(v(kMetalNoise), 0, 1);
        s.metalLevel = dbGain(v(kMetalLevel));
    }
    s.resOn = on(kResOn);
    if (s.resOn) {
        s.model = clampi(v(kResModel), 0, lib::kModalModelCount - 1);
        s.resFreq = clampd(v(kResFreq), 20, 8000);
        s.resDecay = clampd(v(kResDecay) * lengthMul, 0.01, 60);
        s.damp = clampd(v(kResDamp), 0, 1);
        s.bright = clampd(v(kResBright) + 0.35 * tone, 0, 1);
        s.inharm = clampd(v(kResInharm), -1, 1);
        s.pos = clampd(v(kResPos), 0, 1);
        s.exciter = clampi(v(kResExciter), 0, kExciteNoise);
        s.input = clampd(v(kResInput), 0, 1);
        s.resLevel = dbGain(v(kResLevel));
    }
    s.smpOn = on(kSmpOn);
    if (s.smpOn) {
        s.start = clampd(v(kSmpStart), 0, 1);
        s.end = clampd(v(kSmpEnd), 0, 1);
        s.smpTune = clampd(v(kSmpTune), -48, 48);
        s.reverse = on(kSmpReverse);
        s.smpAttack = clampd(v(kSmpAttack), 0.0001, 1);
        s.smpDecay = clampd(v(kSmpDecay) * lengthMul, 0.01, 60);
        s.smpLevel = dbGain(v(kSmpLevel));
    }
    s.driveType = clampi(v(kDriveType), 0, kDriveAsym);
    s.drive = clampd(v(kDrive), 1, 20);
    if (dirt > 0.0) {
        if (s.driveType == kDriveOff) {
            s.driveType = kDriveSoft;
            s.drive = 1.0 + 6.0 * dirt;
        } else {
            s.drive = clampd(s.drive * exp2d(2.0 * dirt), 1, 20);
        }
    } else if (dirt < 0.0) {
        s.drive = clampd(1.0 + (s.drive - 1.0) * (1.0 + dirt), 1, 20);
    }
    s.drivePost = on(kDrivePos);
    s.driveLo = clampd(v(kDriveLo), 20, 2000);
    s.driveHi = clampd(v(kDriveHi), 500, 20000);
    s.driveMix = clampd(v(kDriveMix), 0, 1);
    s.flt = clampi(v(kFlt), 0, kVfBp);
    s.cutoff = clampd(v(kCutoff) * exp2d(2.0 * tone), 20, 20000);
    s.fltQ = lib::resonanceQ(clampd(v(kFltRes), 0, 1));
    s.fltEnv = clampd(v(kFltEnv), -6, 6);
    s.fltDecay = clampd(v(kFltDecay) * exp2d(length), 0.005, 10);
    s.eqLow = clampd(v(kEqLow), -18, 18);
    s.eqLowFreq = clampd(v(kEqLowFreq), 30, 600);
    s.eqMid = clampd(v(kEqMid), -18, 18);
    s.eqFreq = clampd(v(kEqFreq), 80, 12000);
    s.eqQ = clampd(v(kEqQ), 0.3, 8);
    s.eqHigh = clampd(v(kEqHigh) + 6.0 * tone, -24, 24);
    s.eqHighFreq = clampd(v(kEqHighFreq), 1000, 16000);
    s.trA = clampd(v(kTrAttack) + 0.5 * punch + 0.4 * snap, -1, 1);
    s.trS = clampd(v(kTrSustain), -1, 1);
    s.comp = clampd(v(kComp) + (dirt > 0.0 ? 0.3 * dirt : 0.0), 0, 1);
    s.compAttack = clampd(v(kCompAttack), 0.1, 100) * 0.001;
    s.compRelease = clampd(v(kCompRelease), 10, 1000) * 0.001;
    s.clip = clampi(v(kClip), 0, kClipHard);
    s.clipGain = lib::dbToGain(clampd(v(kClipGain), 0, 24));
    s.width = clampd(v(kWidth), 0, 1);
    s.widthHz = clampd(v(kWidthHz), 40, 1000);
    s.roomSend = clampd(v(kRoomSend), 0, 1);
    s.velLevel = clampd(v(kVelLevel), 0, 1);
    s.velPitch = clampd(v(kVelPitch), 0, 24);
    s.velDecay = clampd(v(kVelDecay), -1, 1);
    s.velTone = clampd(v(kVelTone), -1, 1);
    s.velClick = clampd(v(kVelClick), 0, 1);
    s.velPunch = clampd(v(kVelPunch), 0, 1);
    s.rndPos = clampd(v(kRndPos), 0, 1);
    s.rndPitch = clampd(v(kRndPitch), 0, 100);
    s.rndDecay = clampd(v(kRndDecay), 0, 1);
    s.rndTone = clampd(v(kRndTone), 0, 1);
    s.rndPan = clampd(v(kRndPan), 0, 1);
    s.rndLevel = clampd(v(kRndLevel), 0, 1);
    s.fmOn = on(kFmOn);
    if (s.fmOn) {
        s.fmFreq = clampd(v(kFmFreq), 20, 4000);
        s.fmRatio = clampd(v(kFmRatio), 0.25, 16);
        s.fmIndex = clampd(v(kFmIndex) * exp2d(0.5 * tone), 0, 30);
        s.fmIDecay = clampd(v(kFmIDecay) * lengthMul, 0.002, 8);
        s.fmFb = clampd(v(kFmFeedback), 0, 1);
        s.fmPitch = clampd(v(kFmPitch) + 12.0 * punch, 0, 60);
        s.fmPTime = clampd(v(kFmPTime) * exp2d(-0.7 * punch), 0.001, 1);
        s.fmAttack = clampd(v(kFmAttack), 0.0001, 0.5);
        s.fmDecay = clampd(v(kFmDecay) * lengthMul, 0.005, 40);
        s.fmCurve = clampd(v(kFmDCurve), -1, 1);
        s.fmLevel = dbGain(v(kFmLevel));
    }
    s.physOn = on(kPhysOn);
    if (s.physOn) {
        s.physModel = clampi(v(kPhysModel), 0, kPhysStiff);
        s.physFreq = clampd(v(kPhysFreq), 30, 2000);
        s.physDecay = clampd(v(kPhysDecay) * lengthMul, 0.02, 40);
        s.physDamp = clampd(v(kPhysDamp) - 0.35 * tone, 0, 1);
        s.physPick = clampd(v(kPhysPick), 0, 1);
        s.physExciter = clampi(v(kPhysExciter), 0, kPhysLayers);
        s.physInput = clampd(v(kPhysInput), 0, 1);
        s.physLevel = dbGain(v(kPhysLevel));
    }
    s.texOn = on(kTexOn);
    if (s.texOn) {
        s.texMode = clampi(v(kTexMode), 0, kTexCrackle);
        s.texFreq = clampd(v(kTexFreq) * exp2d(1.5 * tone), 40, 16000);
        s.texSpread = clampd(v(kTexSpread), 0, 4);
        s.texQ = lib::resonanceQ(clampd(v(kTexRes), 0, 1));
        s.texTilt = clampd(v(kTexTilt), -1, 1);
        s.texDensity = clampd(v(kTexDensity), 10, 20000);
        s.texAttack = clampd(v(kTexAttack), 0.0001, 1);
        s.texDecay = clampd(v(kTexDecay) * lengthMul, 0.005, 40);
        s.texCurve = clampd(v(kTexDCurve), -1, 1);
        s.texLevel = dbGain(v(kTexLevel)) * exp2d(0.8 * snap);
    }
    if (s.smpOn) {
        s.smpPitch = clampd(v(kSmpPitch) + (v(kSmpPitch) > 0.0 ? 12.0 * punch : 0.0), 0, 60);
        s.smpPTime = clampd(v(kSmpPTime) * exp2d(-0.7 * punch), 0.001, 1);
        s.smpHold = clampd(v(kSmpHold) * exp2d(length), 0, 2);
        s.smpCurve = clampd(v(kSmpDCurve), -1, 1);
        s.smpVelStart = clampd(v(kSmpVelStart), 0, 1);
        s.smpRndStart = clampd(v(kSmpRndStart), 0, 1);
    }
    s.ringMix = clampd(v(kRingMix), 0, 1);
    s.ringFreq = clampd(v(kRingFreq), 20, 8000);
    s.echoSend = clampd(v(kEchoSend), 0, 1);
    s.busSend = clampd(v(kBusSend), 0, 1);
    s.swing = clampd(v(kSwing), 0, 1);
    s.swingGrid = clampi(v(kSwingGrid), 0, kGrid8);
    s.humanize = clampd(v(kHumanize), 0, 1);
    s.accent = clampd(v(kAccent), 0, 1);
    s.accentOn = clampi(v(kAccentOn), 0, kAccentLoud);
    s.flam = clampd(v(kFlam), 0, 1);
    s.flamTime = clampd(v(kFlamTime), 0.005, 0.06);
    s.groove = clampi(v(kGroove), 0, kGrooveCount - 1);
    s.grooveAmt = clampd(v(kGrooveAmt), 0, 1);
    s.groovy = s.swing > 0.0 || s.humanize > 0.0 || s.accent > 0.0 || s.flam > 0.0 || (s.groove != kGrooveOff && s.grooveAmt > 0.0);
    s.layers = s.bodyOn || s.subOn || s.clickOn || s.noiseOn || s.metalOn || s.resOn || s.smpOn || s.fmOn || s.physOn ||
               s.texOn;
    s.engine = clampi(v(kEngine), kEngineLayers, kEngineAcoustic);
    s.acouPiece = clampi(v(kAcouPiece), 0, static_cast<int>(kPieces) - 1);
    s.acouArtic = clampi(v(kAcouArtic), 0, kArtCount - 1);
    s.acouLayer = s.engine == kEngineLayers ? clampi(v(kAcouLayer), 0, static_cast<int>(kPieces)) : 0;
    s.used = (s.engine == kEngineAcoustic || s.layers || s.acouLayer > 0) && s.gain > 0.0;
}
