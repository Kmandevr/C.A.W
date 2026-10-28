// A running copy of a Program: its registers, state and parameter values, processed one block at a time.
#pragma once

#include <algorithm>
#include <atomic>
#include <bit>
#include <cstdint>
#include <memory>
#include <vector>

#include "program.h"

namespace caw {

class Instance {
public:
    explicit Instance(std::shared_ptr<const Program> p);

    const Program& program() const { return *prog_; }
    const std::shared_ptr<const Program>& programPtr() const { return prog_; }

    // Back to the state right after creation (audio-thread safe: no allocation).
    void reset() noexcept;
    // Swaps state with another instance of the same program (audio-thread safe, no copying).
    void swapState(Instance& other) noexcept;

    // Runs the program over ctx.n samples; returns the output register (mapped by the module's output mode).
    const double* process(const BlockCtx& ctx) noexcept;
    // A register's latest block (exports are read from here).
    const double* reg(int r) const noexcept { return regs_.data() + static_cast<size_t>(r) * kBlock; }
    // The output expression's value before the output mode maps it (tests and tools).
    const double* rawOutput() const noexcept { return regs_.data() + static_cast<size_t>(prog_->outReg) * kBlock; }

    // Copies `count` numbers of another instance's state into this one (audio-thread safe: no allocation).
    void copyStateRange(const Instance& from, uint32_t fromOffset, uint32_t toOffset, uint32_t count) noexcept {
        if (fromOffset + count <= from.state_.size() && toOffset + count <= state_.size())
            std::copy_n(from.state_.data() + fromOffset, count, state_.data() + toOffset);
    }

    // Parameter values may be set from any thread.
    void setParam(int i, double v) noexcept { params_[i].store(std::bit_cast<uint64_t>(v), std::memory_order_relaxed); }
    double param(int i) const noexcept { return std::bit_cast<double>(params_[i].load(std::memory_order_relaxed)); }

private:
    std::shared_ptr<const Program> prog_;
    std::vector<double> regs_;  // numRegs * kBlock
    std::vector<double> state_;
    std::vector<double> out_;
    std::unique_ptr<std::atomic<uint64_t>[]> params_;
};

}  // namespace caw
