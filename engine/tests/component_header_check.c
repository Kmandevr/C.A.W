/* Compiles caw_component.h as plain C (C99): the component boundary must never need C++. */
#include "caw_component.h"

#include <stddef.h>

typedef char caw_check_entry_symbol[sizeof(CAW_COMPONENT_ENTRY_SYMBOL) > 1 ? 1 : -1];

size_t caw_component_header_check(void) {
    CawProcessBlock block = {0};
    block.struct_size = (uint32_t)sizeof(CawProcessBlock);
    return block.struct_size + sizeof(CawComponentV3) + sizeof(CawComponentDescriptor) + sizeof(CawHost);
}
