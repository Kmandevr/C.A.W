// The meaning of every operator, shared by the VM and the compiler's constant folding so both give the same bits.
#pragma once

#include "detmath.h"
#include "program.h"

namespace caw {

inline double evalBin(BinOp op, double a, double b) {
    switch (op) {
        case BinOp::Add: return a + b;
        case BinOp::Sub: return a - b;
        case BinOp::Mul: return a * b;
        case BinOp::Div: return jsDiv(a, b);
        case BinOp::Mod: return jsMod(a, b);
        case BinOp::Pow: return detPow(a, b);
        case BinOp::And: return toInt32(a) & toInt32(b);
        case BinOp::Or: return toInt32(a) | toInt32(b);
        case BinOp::Xor: return toInt32(a) ^ toInt32(b);
        case BinOp::Shl: return static_cast<int32_t>(toUint32(a) << (toUint32(b) & 31));
        case BinOp::Shr: return toInt32(a) >> (toUint32(b) & 31);
        case BinOp::Ushr: return static_cast<double>(toUint32(a) >> (toUint32(b) & 31));
        case BinOp::Eq: return a == b ? 1.0 : 0.0;
        case BinOp::Ne: return a != b ? 1.0 : 0.0;
        case BinOp::Lt: return a < b ? 1.0 : 0.0;
        case BinOp::Le: return a <= b ? 1.0 : 0.0;
        case BinOp::Gt: return a > b ? 1.0 : 0.0;
        case BinOp::Ge: return a >= b ? 1.0 : 0.0;
        case BinOp::LogAnd: return truthy(a) ? b : a;
        case BinOp::LogOr: return truthy(a) ? a : b;
    }
    return 0.0;
}

inline double evalUn(UnOp op, double a) {
    switch (op) {
        case UnOp::Neg: return -a;
        case UnOp::Plus: return a;
        case UnOp::Not: return truthy(a) ? 0.0 : 1.0;
        case UnOp::BitNot: return ~toInt32(a);
    }
    return 0.0;
}

}  // namespace caw
