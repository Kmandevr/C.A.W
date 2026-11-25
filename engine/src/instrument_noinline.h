// The modelled instruments' out-of-line marker (CAW_TIMBER_NOINLINE), what is left of Timber's 1.1.2 simulation parts.
#pragma once

// The bowed string's and the winds' per-sample loops are kept out of line, so the compiler's choices for the code
// around them (the engine builds with -fassociative-math) do not change with them.
#if defined(_MSC_VER)
#define CAW_TIMBER_NOINLINE __declspec(noinline)
#else
#define CAW_TIMBER_NOINLINE __attribute__((noinline))
#endif
