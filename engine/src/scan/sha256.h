// SHA-256 (FIPS 180-4) of a byte span, for the pre-load scan's verdict cache and the files the app shows.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string>

namespace caw::scan {

// Incremental: update() any number of times, then digest() once.
class Sha256 {
public:
    Sha256() noexcept;
    void update(const uint8_t* data, size_t size) noexcept;
    std::array<uint8_t, 32> digest() noexcept;

private:
    void block(const uint8_t* p) noexcept;
    uint32_t h_[8];
    uint8_t buffer_[64];
    size_t used_ = 0;
    uint64_t total_ = 0;
};

// The digest as 64 lowercase hex digits.
std::string sha256Hex(std::span<const uint8_t> bytes);
std::string toHex(const std::array<uint8_t, 32>& digest);

}  // namespace caw::scan
