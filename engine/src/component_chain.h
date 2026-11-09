// A chain of native stereo components (a track's inserts or the master's), with their parameters.
#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "module_registry.h"
#include "params.h"
#include "project.h"

namespace caw {

// Built and configured on the control thread, then handed to the audio thread, which alone calls
// process(); destroyed on the control thread after the audio thread retires it. The control thread
// may change parameter values while the chain plays (setValue): each value is an atomic the audio
// thread reads once per block and ramps to through the parameter's resolver.
class ComponentChain {
public:
    static constexpr uint32_t kMaxFrames = 64;  // the Engine's block (checked in engine.cpp)

    // Every component must be loaded, have one stereo audio input and one stereo audio output and
    // no other ports, and every named parameter must exist. An empty pointer and `error` otherwise.
    static std::unique_ptr<ComponentChain> build(const ModuleRegistry& registry,
                                                 const std::vector<ComponentSpec>& specs, double sampleRate,
                                                 std::string& error);
    ~ComponentChain();

    // Whether this chain was built from the same components, in the same order, at this rate, so a
    // project update keeps it (and its running state, such as a reverb's tail) and only sets values.
    bool sameComponents(const std::vector<ComponentSpec>& specs, double sampleRate) const noexcept;
    // Control thread. Sets every value the specs name; values they leave out keep what they hold.
    void setValues(const std::vector<ComponentSpec>& specs) noexcept;
    // Control thread. False for an index or parameter id the chain does not have, or a non-finite value.
    bool setValue(std::size_t index, const std::string& parameterId, double value) noexcept;
    std::size_t size() const noexcept { return entries_.size(); }
    // An estimate of the memory the chain holds, for the project-state budget.
    static uint64_t estimateBytes(std::size_t components, std::size_t parameters) noexcept;

    // Audio thread: runs every component over left/right in place (m <= kMaxFrames). A component
    // that fails a block passes its input through; non-finite output becomes 0.
    void process(float* left, float* right, uint32_t m, double sampleRate) noexcept;

private:
    struct Entry {
        std::string id;
        std::unique_ptr<ModuleProcessor> processor;
        std::vector<ParameterResolver> resolvers;
        std::unique_ptr<std::atomic<uint64_t>[]> held;  // control-thread values, as double bits
        std::vector<uint64_t> seen;                     // audio thread: the bits last applied
        std::vector<std::array<double, kMaxFrames>> samples;
        std::vector<ParameterValue> values;
    };
    ComponentChain() = default;
    int parameterIndex(const Entry& e, const std::string& id) const noexcept;

    std::vector<Entry> entries_;
    double sampleRate_ = 0;
    std::array<float, kMaxFrames> stageL_{}, stageR_{};
};

}  // namespace caw
