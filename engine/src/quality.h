// The engine's sound quality (Eco, Normal, High), as the built-in components read it while they play.
#pragma once

#include <atomic>

namespace caw {

// CAW_QUALITY_ECO, _NORMAL and _HIGH (caw.h).
enum Quality : int { kQualityEco = 0, kQualityNormal = 1, kQualityHigh = 2 };

namespace quality_detail {
inline thread_local const std::atomic<int>* building = nullptr;
inline const std::atomic<int> normal{kQualityNormal};
}  // namespace quality_detail

// The Engine sets its quality setting for the components it builds on this thread (the control thread, around a
// project update) so a built-in's activate() can keep a pointer to it and read it while playing. The Engine
// outlives every chain it builds.
class BuildingQuality {
public:
    explicit BuildingQuality(const std::atomic<int>* q) noexcept : was_(quality_detail::building) { quality_detail::building = q; }
    ~BuildingQuality() { quality_detail::building = was_; }
    BuildingQuality(const BuildingQuality&) = delete;
    BuildingQuality& operator=(const BuildingQuality&) = delete;

private:
    const std::atomic<int>* was_;
};

// For a built-in's activate(): the quality of the Engine building it (Normal outside one: a test, a sample pack,
// the component tester, an export's own engine).
inline const std::atomic<int>* buildingQuality() noexcept {
    return quality_detail::building ? quality_detail::building : &quality_detail::normal;
}
// Real-time safe: one relaxed load.
inline int qualityNow(const std::atomic<int>* q) noexcept {
    const int v = q ? q->load(std::memory_order_relaxed) : kQualityNormal;
    return v < kQualityEco ? kQualityEco : (v > kQualityHigh ? kQualityHigh : v);
}

}  // namespace caw
