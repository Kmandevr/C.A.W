// The bytecode interpreter: runs each op over a whole block of samples.
#include "vm.h"

#include <algorithm>
#include <cstring>

#include "builtins.h"
#include "ops.h"

namespace caw {

Instance::Instance(std::shared_ptr<const Program> p)
    : prog_(std::move(p)),
      regs_(static_cast<size_t>(prog_->numRegs) * kBlock, 0.0),
      state_(static_cast<size_t>(prog_->stateSize), 0.0),
      out_(kBlock, 0.0),
      params_(new std::atomic<uint64_t>[prog_->params.size() + 1]) {
    for (size_t i = 0; i < prog_->params.size(); ++i) setParam(static_cast<int>(i), prog_->params[i].def);
    for (const Op& op : prog_->constOps) std::fill_n(&regs_[static_cast<size_t>(op.dst) * kBlock], kBlock, op.k);
    reset();
}

void Instance::reset() noexcept {
    std::fill(state_.begin(), state_.end(), 0.0);
    for (const StateInit& s : prog_->stateInit) state_[s.offset] = s.value;
}

void Instance::copyStateFrom(const Instance& other) noexcept {
    if (other.prog_ == prog_) std::copy(other.state_.begin(), other.state_.end(), state_.begin());
}

const double* Instance::process(const BlockCtx& ctx) noexcept {
    const int n = ctx.n;
    double* regs = regs_.data();
    auto reg = [regs](uint16_t r) { return regs + static_cast<size_t>(r) * kBlock; };
    for (const Op& op : prog_->ops) {
        double* d = reg(op.dst);
        switch (op.code) {
            case OpCode::Const:
                break;
            case OpCode::Var: {
                const double* src = ctx.vars[op.sub];
                if (src) std::copy_n(src, n, d);
                else std::fill_n(d, n, 0.0);
                break;
            }
            case OpCode::Import: {
                const double* src = ctx.imports ? ctx.imports[op.index] : nullptr;
                if (src) std::copy_n(src + ctx.importOffset, n, d);
                else std::fill_n(d, n, 0.0);
                break;
            }
            case OpCode::Param:
                std::fill_n(d, n, param(static_cast<int>(op.index)));
                break;
            case OpCode::Bin: {
                const double* a = reg(op.a);
                const double* b = reg(op.b);
                const BinOp bop = static_cast<BinOp>(op.sub);
                for (int i = 0; i < n; ++i) d[i] = evalBin(bop, a[i], b[i]);
                break;
            }
            case OpCode::Un: {
                const double* a = reg(op.a);
                const UnOp uop = static_cast<UnOp>(op.sub);
                for (int i = 0; i < n; ++i) d[i] = evalUn(uop, a[i]);
                break;
            }
            case OpCode::Select: {
                const double* c = reg(op.a);
                const double* a = reg(op.b);
                const double* b = reg(op.c);
                for (int i = 0; i < n; ++i) d[i] = truthy(c[i]) ? a[i] : b[i];
                break;
            }
            case OpCode::Call: {
                CallArgs args{};
                for (int i = 0; i < op.sub; ++i) args.a[i] = reg(op.args[i]);
                args.out = d;
                args.n = n;
                args.state = builtin(static_cast<int>(op.index)).stateSize > 0 ? state_.data() + op.state : nullptr;
                args.ctx = &ctx;
                builtin(static_cast<int>(op.index)).run(args);
                break;
            }
        }
    }
    const double* v = reg(static_cast<uint16_t>(prog_->outReg));
    double* o = out_.data();
    if (prog_->mode == OutputMode::Byte) {
        for (int i = 0; i < n; ++i) o[i] = static_cast<double>(toInt32(v[i]) & 255) / 127.5 - 1.0;
    } else {
        for (int i = 0; i < n; ++i) {
            const double x = finiteOr0(v[i]);
            o[i] = x < -1.0 ? -1.0 : (x > 1.0 ? 1.0 : x);
        }
    }
    return o;
}

}  // namespace caw
