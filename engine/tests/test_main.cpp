// Runs every registered test; `caw_tests --update-golden` rewrites engine/tests/golden.txt.
#include <cstdlib>
#include <cstring>

#include "test.h"

namespace cawtest {

std::vector<Case>& cases() {
    static std::vector<Case> c;
    return c;
}

bool updateGolden = false;
static int failures = 0;
static const char* current = "";

void fail(const char* file, int line, const std::string& msg) {
    ++failures;
    std::printf("FAIL %s (%s:%d): %s\n", current, file, line, msg.c_str());
}

}  // namespace cawtest

namespace {

// Stable across processes and platforms; each test case belongs to exactly one shard.
unsigned int shardFor(const char* name, unsigned int count) {
    unsigned int hash = 2166136261u;
    for (const unsigned char* p = reinterpret_cast<const unsigned char*>(name); *p; ++p) {
        hash ^= *p;
        hash *= 16777619u;
    }
    return hash % count;
}

}  // namespace

int main(int argc, char** argv) {
    const char* only = nullptr;
    unsigned int shardIndex = 0;
    unsigned int shardCount = 1;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--update-golden") == 0) {
            cawtest::updateGolden = true;
        } else if (std::strcmp(argv[i], "--shard-index") == 0 && i + 1 < argc) {
            shardIndex = static_cast<unsigned int>(std::strtoul(argv[++i], nullptr, 10));
        } else if (std::strcmp(argv[i], "--shard-count") == 0 && i + 1 < argc) {
            shardCount = static_cast<unsigned int>(std::strtoul(argv[++i], nullptr, 10));
        } else {
            only = argv[i];
        }
    }
    if (shardCount == 0 || shardIndex >= shardCount || (cawtest::updateGolden && shardCount != 1)) {
        std::fprintf(stderr, "invalid test shard configuration (golden updates must run unsharded)\n");
        return 2;
    }

    int run = 0;
    for (const auto& c : cawtest::cases()) {
        if (only && std::strstr(c.name, only) == nullptr) continue;
        if (shardCount > 1 && shardFor(c.name, shardCount) != shardIndex) continue;
        cawtest::current = c.name;
        const int before = cawtest::failures;
        c.fn();
        ++run;
        if (cawtest::failures == before) std::printf("ok   %s\n", c.name);
    }
    std::printf("%d tests, %d failures (shard %u/%u)\n", run, cawtest::failures, shardIndex + 1, shardCount);
    return cawtest::failures == 0 && run > 0 ? 0 : 1;
}
