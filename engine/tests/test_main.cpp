// Runs every registered test; `caw_tests --update-golden` rewrites engine/tests/golden.txt.
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

int main(int argc, char** argv) {
    const char* only = nullptr;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--update-golden") == 0) cawtest::updateGolden = true;
        else only = argv[i];
    }
    int run = 0;
    for (const auto& c : cawtest::cases()) {
        if (only && std::strstr(c.name, only) == nullptr) continue;
        cawtest::current = c.name;
        const int before = cawtest::failures;
        c.fn();
        ++run;
        if (cawtest::failures == before) std::printf("ok   %s\n", c.name);
    }
    std::printf("%d tests, %d failures\n", run, cawtest::failures);
    return cawtest::failures == 0 && run > 0 ? 0 : 1;
}
