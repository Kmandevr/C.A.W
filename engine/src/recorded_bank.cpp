// The recorded-parts cache: decodes an embedded FLAC bank (miniaudio's decoder, decode_audio.h) on first use and keeps it only while an instrument holds it.
#include "recorded_bank.h"

#include <mutex>
#include <new>

#include "../platform/decode_audio.h"

namespace caw::assets {
extern const unsigned char starling_piano_flac[];
extern const std::size_t starling_piano_flac_size;
extern const unsigned char woodpecker_mallets_flac[];
extern const std::size_t woodpecker_mallets_flac_size;
extern const unsigned char starling_guitar_flac[];
extern const std::size_t starling_guitar_flac_size;
extern const unsigned char starling_harp_flac[];
extern const std::size_t starling_harp_flac_size;
extern const unsigned char rook_kit_flac[];
extern const std::size_t rook_kit_flac_size;
extern const unsigned char bittern_speech_flac[];
extern const std::size_t bittern_speech_flac_size;
}  // namespace caw::assets

namespace caw::recorded {
namespace {

struct Source {
    const unsigned char* data;
    size_t size;
};

Source source(BankId id) noexcept {
    switch (id) {
        case BankId::StarlingPiano: return {assets::starling_piano_flac, assets::starling_piano_flac_size};
        case BankId::Woodpecker: return {assets::woodpecker_mallets_flac, assets::woodpecker_mallets_flac_size};
        case BankId::StarlingGuitar: return {assets::starling_guitar_flac, assets::starling_guitar_flac_size};
        case BankId::StarlingHarp: return {assets::starling_harp_flac, assets::starling_harp_flac_size};
        case BankId::RookKit: return {assets::rook_kit_flac, assets::rook_kit_flac_size};
        case BankId::Bittern: return {assets::bittern_speech_flac, assets::bittern_speech_flac_size};
        default: return {nullptr, 0};
    }
}

std::mutex gLock;
std::weak_ptr<const Bank> gBanks[static_cast<size_t>(BankId::kCount)];

std::shared_ptr<const Bank> decode(Source s) noexcept {
    if (!s.data || s.size == 0) return nullptr;
    CawDecodedAudio a{};
    char error[128];
    // Built-in data, so the limits only guard against a broken build: 10 minutes, 256 MiB.
    if (!caw_decode_audio(s.data, s.size, 600.0, 256ull << 20, &a, error, sizeof error)) return nullptr;
    auto bank = std::shared_ptr<Bank>(new (std::nothrow) Bank());
    if (bank) {
        bank->pcm.reset(new (std::nothrow) float[a.frames ? a.frames : 1]);
        if (bank->pcm) {
            for (uint64_t i = 0; i < a.frames; ++i) bank->pcm[i] = a.interleaved[i * a.channels];  // mono: the first channel
            bank->frames = a.frames;
            bank->rate = a.sample_rate;
        } else {
            bank.reset();
        }
    }
    caw_decode_free(&a);
    return bank;
}

}  // namespace

std::shared_ptr<const Bank> acquire(BankId id) noexcept {
    const auto k = static_cast<size_t>(id);
    if (k >= static_cast<size_t>(BankId::kCount)) return nullptr;
    const std::lock_guard<std::mutex> lock(gLock);
    if (auto held = gBanks[k].lock()) return held;
    auto bank = decode(source(id));
    gBanks[k] = bank;
    return bank;
}

size_t residentBytes() noexcept {
    const std::lock_guard<std::mutex> lock(gLock);
    size_t n = 0;
    for (const auto& w : gBanks)
        if (auto b = w.lock()) n += static_cast<size_t>(b->frames) * sizeof(float);
    return n;
}

}  // namespace caw::recorded
