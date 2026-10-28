// Tiny test framework: TEST(name) registers a case, CHECK macros record failures with file and line.
#pragma once

#include <cmath>
#include <cstdio>
#include <functional>
#include <sstream>
#include <string>
#include <vector>

namespace cawtest {

struct Case {
    const char* name;
    std::function<void()> fn;
};

std::vector<Case>& cases();
void fail(const char* file, int line, const std::string& msg);
extern bool updateGolden;

struct Reg {
    Reg(const char* n, std::function<void()> f) { cases().push_back({n, std::move(f)}); }
};

template <class A, class B>
std::string show(const A& a, const B& b) {
    std::ostringstream s;
    s.precision(17);
    s << a << " vs " << b;
    return s.str();
}

}  // namespace cawtest

#define CAW_CAT2(a, b) a##b
#define CAW_CAT(a, b) CAW_CAT2(a, b)
#define TEST(name)                                                        \
    static void CAW_CAT(test_, name)();                                   \
    static cawtest::Reg CAW_CAT(reg_, name)(#name, CAW_CAT(test_, name)); \
    static void CAW_CAT(test_, name)()

#define CHECK(c) \
    do { if (!(c)) cawtest::fail(__FILE__, __LINE__, "CHECK(" #c ")"); } while (0)
#define CHECK_EQ(a, b)                                                                               \
    do {                                                                                             \
        const auto va_ = (a);                                                                        \
        const auto vb_ = (b);                                                                        \
        if (!(va_ == vb_)) cawtest::fail(__FILE__, __LINE__, #a " == " #b ": " + cawtest::show(va_, vb_)); \
    } while (0)
#define CHECK_NEAR(a, b, eps)                                                                        \
    do {                                                                                             \
        const double va_ = (a);                                                                      \
        const double vb_ = (b);                                                                      \
        if (!(std::fabs(va_ - vb_) <= (eps)))                                                        \
            cawtest::fail(__FILE__, __LINE__, #a " ~= " #b ": " + cawtest::show(va_, vb_));          \
    } while (0)
