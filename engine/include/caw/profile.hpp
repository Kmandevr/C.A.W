// CAW_PROFILE_SCOPE("name"): times a named section of a component's process() for the plug-in benchmark (#197).
#pragma once

#include <atomic>
#include <cstdint>

#include "../caw_component.h"

// Each library keeps its own copy of the host's table pointer (hidden, so two libraries never share one).
#if defined(__GNUC__) || defined(__clang__)
#define CAW_PROFILE_HIDDEN __attribute__((visibility("hidden")))
#else
#define CAW_PROFILE_HIDDEN
#endif

namespace caw::profile_detail {

inline constexpr int32_t kOff = 0;
// The host's profile extension (CAW_HOST_EXTENSION_PROFILE), once a host that has one created an instance.
CAW_PROFILE_HIDDEN inline std::atomic<const CawProfileExtension*> host{nullptr};
// What `on()` reads: the host's flag, or a zero of our own (so the check is always one load of a valid flag).
CAW_PROFILE_HIDDEN inline std::atomic<const int32_t*> active{&kOff};

inline bool on() noexcept {
    const int32_t* flag = active.load(std::memory_order_relaxed);
#if defined(__GNUC__) || defined(__clang__)
    return __atomic_load_n(flag, __ATOMIC_RELAXED) != 0;
#else
    return *static_cast<const volatile int32_t*>(flag) != 0;
#endif
}

// The C++ SDK's create (caw/component.hpp) calls this with the host it is given: a host offering the profile
// extension is remembered. A component written against the C interface alone asks for it the same way.
inline void attach(const CawHost* h) noexcept {
    if (!h || h->struct_size < sizeof(CawHost) || !h->get_extension) return;
    const auto* x = static_cast<const CawProfileExtension*>(h->get_extension(h, CAW_HOST_EXTENSION_PROFILE));
    if (!x || x->struct_size < sizeof(CawProfileExtension) || !x->active || !x->begin || !x->end || !x->now_ns) return;
    host.store(x, std::memory_order_release);
    active.store(x->active, std::memory_order_release);
}

}  // namespace caw::profile_detail

namespace caw {

// One section's time while it lives (see CAW_PROFILE_SCOPE). Outside a benchmark: a load and a predictable branch
// on entry, a predictable branch on exit; nothing allocates, locks or blocks either way.
class ProfileSection {
public:
    explicit ProfileSection(const char* name) noexcept {
        if (profile_detail::on()) [[unlikely]] start(name);
    }
    ~ProfileSection() {
        if (host_) [[unlikely]] host_->end(host_->host_data, section_, t0_);
    }
    ProfileSection(const ProfileSection&) = delete;
    ProfileSection& operator=(const ProfileSection&) = delete;

private:
    void start(const char* name) noexcept {
        const CawProfileExtension* h = profile_detail::host.load(std::memory_order_acquire);
        if (!h) return;
        section_ = h->begin(h->host_data, name);
        if (section_ == CAW_PROFILE_NO_SECTION) return;
        host_ = h;
        t0_ = h->now_ns();
    }
    const CawProfileExtension* host_ = nullptr;
    uint32_t section_ = CAW_PROFILE_NO_SECTION;
    uint64_t t0_ = 0;
};

}  // namespace caw

#define CAW_PROFILE_CONCAT2(a, b) a##b
#define CAW_PROFILE_CONCAT(a, b) CAW_PROFILE_CONCAT2(a, b)
// Times the rest of the enclosing block as section `name` (a string literal; at most 32 names, 47 characters
// shown) in the plug-in benchmark's "sections". Use it inside process():
//
//     void process(const caw::StereoProcessBlock& b) noexcept override {
//         CAW_PROFILE_SCOPE("filter");
//         ...
//     }
#define CAW_PROFILE_SCOPE(name) const ::caw::ProfileSection CAW_PROFILE_CONCAT(caw_profile_scope_, __LINE__)(name)
