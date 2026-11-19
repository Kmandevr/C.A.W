// Library warming where the engine has no segment walk (macOS, other systems): nothing is touched.
#include "library_warm.h"

namespace caw {

LibraryWarmStats warmLibrary(const void*, std::size_t) noexcept { return {}; }

}  // namespace caw
