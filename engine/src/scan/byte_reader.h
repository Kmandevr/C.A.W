// Bounded little-endian reads over a hostile byte span for the pre-load scan: every read is checked.
#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>

namespace caw::scan {

class ByteReader {
public:
    explicit ByteReader(std::span<const uint8_t> bytes) noexcept : b_(bytes) {}
    uint64_t size() const noexcept { return b_.size(); }
    const uint8_t* data() const noexcept { return b_.data(); }

    // Whether [offset, offset + length) lies inside the bytes (no overflow).
    bool has(uint64_t offset, uint64_t length) const noexcept {
        return offset <= b_.size() && length <= b_.size() - offset;
    }
    bool u8(uint64_t at, uint8_t& v) const noexcept {
        if (!has(at, 1)) return false;
        v = b_[at];
        return true;
    }
    bool u16(uint64_t at, uint16_t& v) const noexcept {
        if (!has(at, 2)) return false;
        v = uint16_t(b_[at] | (b_[at + 1] << 8));
        return true;
    }
    bool u32(uint64_t at, uint32_t& v) const noexcept {
        if (!has(at, 4)) return false;
        v = uint32_t(b_[at]) | (uint32_t(b_[at + 1]) << 8) | (uint32_t(b_[at + 2]) << 16) | (uint32_t(b_[at + 3]) << 24);
        return true;
    }
    bool u64(uint64_t at, uint64_t& v) const noexcept {
        uint32_t lo = 0, hi = 0;
        if (!u32(at, lo) || !u32(at + 4, hi)) return false;
        v = uint64_t(lo) | (uint64_t(hi) << 32);
        return true;
    }
    // A NUL-terminated string at `at`, never past `limitEnd` (an offset) or the bytes, cut to maxBytes.
    // False when `at` is outside, or no terminator comes before the end within maxBytes.
    bool cstr(uint64_t at, uint64_t limitEnd, uint32_t maxBytes, std::string& out) const {
        if (limitEnd > b_.size()) limitEnd = b_.size();
        if (at >= limitEnd) return false;
        out.clear();
        for (uint64_t i = at; i < limitEnd; ++i) {
            if (b_[i] == 0) return true;
            if (out.size() >= maxBytes) return true;  // read cut to maxBytes
            out.push_back(char(b_[i]));
        }
        return false;
    }

private:
    std::span<const uint8_t> b_;
};

// Table entries walked across one scan; past the budget the scan stops and reports it malformed.
struct WorkBudget {
    uint64_t left;
    bool spend(uint64_t n = 1) noexcept {
        if (n > left) {
            left = 0;
            return false;
        }
        left -= n;
        return true;
    }
};

}  // namespace caw::scan
