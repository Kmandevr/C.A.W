// Timber's load-time alias (removed in 1.1.3): an old org.caw.timber entry becomes Starling, Nightingale, Curlew, Woodpecker, Bittern or Kestrel, its knobs mapped once.
#pragma once

#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace caw::timber {

using Params = std::vector<std::pair<std::string, double>>;

// The id old projects name. Nothing registers it: it exists only as this alias.
inline constexpr std::string_view kTimberId = "org.caw.timber";

// Timber's models, in its old `variant` order.
enum class Model : int { Piano, EPiano, Organ, Plucked, Bowed, Mallets, Winds };

// Where an old entry goes: the instrument, its `variant` there and the preset its values start from.
struct Destination {
    std::string_view id;
    int variant;
    std::string_view preset;
};

// The model an old entry's values play (its `variant`, as Timber read it: absent, NaN or negative is the piano, past
// the last the last).
Model timberModel(const Params& params) noexcept;

// Where the old entry goes (the mapping table, timber_migrate.cpp: one place to change it).
Destination timberDestination(const Params& params) noexcept;

// Turns an org.caw.timber entry into its new instrument's: `id` and `params` replaced (the destination preset's
// values, then the old knobs mapped by meaning onto the new ones, every value finite and in its range), `preset`, if
// given, the preset's name. False, nothing changed, for any other id.
bool migrateTimber(std::string& id, Params& params, std::string* preset = nullptr);

// The new instrument's parameter an automation lane on old knob `param` moves, for an entry with `oldParams` (the
// model decides), when it means the same in the same units; empty when it doesn't (the lane is dropped).
std::string migratedTimberParameter(const Params& oldParams, std::string_view param);

// Every knob id Timber's models had (for the lanes' list in caw_migrate_instrument).
std::span<const std::string_view> timberKnobs() noexcept;

}  // namespace caw::timber
