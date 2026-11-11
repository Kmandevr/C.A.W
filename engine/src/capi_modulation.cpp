// The C API's project modulation calls (API 19, #161): modulator knobs and bypass, link amounts, and the live outputs a UI draws.
#include "caw.h"
#include "capi_internal.h"

int32_t caw_engine_set_modulator_param(CawEngine* e, const char* modulator_id, const char* param, double value) try {
    return e && e->engine && modulator_id && param && e->engine->setModulatorParam(modulator_id, param, value) ? 1 : 0;
} catch (...) {
    return 0;
}

int32_t caw_engine_set_modulator_bypass(CawEngine* e, const char* modulator_id, int32_t bypass) try {
    return e && e->engine && modulator_id && e->engine->setModulatorBypass(modulator_id, bypass != 0) ? 1 : 0;
} catch (...) {
    return 0;
}

int32_t caw_engine_set_modulation_amount(CawEngine* e, uint32_t link_id, double amount) try {
    return e && e->engine && e->engine->setModulationAmount(link_id, amount) ? 1 : 0;
} catch (...) {
    return 0;
}

int32_t caw_engine_modulator_outputs(CawEngine* e, const char* modulator_id, float* out, int32_t max) try {
    if (!e || !e->engine || !modulator_id) return -1;
    if (!out || max <= 0) return 0;
    return e->engine->modulatorOutputs(modulator_id, out, max);
} catch (...) {
    return 0;
}

int32_t caw_engine_modulation_offset(CawEngine* e, uint32_t link_id, float* out) try {
    float v = 0.0f;
    if (!e || !e->engine || !out || !e->engine->modulationOffset(link_id, v)) return 0;
    *out = v;
    return 1;
} catch (...) {
    return 0;
}
