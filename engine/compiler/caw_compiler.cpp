// The on-device compiler library: Clang's driver plans the build, cc1 and LLD run in this process.
#include "caw_compiler.h"

#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "clang/Basic/Diagnostic.h"
#include "clang/Basic/DiagnosticIDs.h"
#include "clang/Basic/DiagnosticOptions.h"
#include "clang/Basic/Stack.h"
#include "clang/CodeGen/ObjectFilePCHContainerWriter.h"
#include "clang/Driver/Compilation.h"
#include "clang/Driver/Driver.h"
#include "clang/Driver/Job.h"
#include "clang/Driver/Tool.h"
#include "clang/Frontend/CompilerInstance.h"
#include "clang/Frontend/CompilerInvocation.h"
#include "clang/Frontend/TextDiagnosticPrinter.h"
#include "clang/FrontendTool/Utils.h"
#include "clang/Serialization/ObjectFilePCHContainerReader.h"
#include "lld/Common/Driver.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/IntrusiveRefCntPtr.h"
#include "llvm/Config/llvm-config.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/VirtualFileSystem.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/TargetParser/Host.h"

LLD_HAS_DRIVER(elf)

namespace {

// One compile job: what clang's cc1_main does, with diagnostics written to `out`.
bool runCc1(const llvm::opt::ArgStringList& args, const char* argv0, llvm::raw_ostream& out) {
    auto pch = std::make_shared<clang::PCHContainerOperations>();
    pch->registerWriter(std::make_unique<clang::ObjectFilePCHContainerWriter>());
    pch->registerReader(std::make_unique<clang::ObjectFilePCHContainerReader>());

    clang::DiagnosticOptions parseOpts;
    clang::TextDiagnosticPrinter* parsePrinter = new clang::TextDiagnosticPrinter(out, parseOpts);
    clang::DiagnosticsEngine parseDiags(clang::DiagnosticIDs::create(), parseOpts, parsePrinter);
    auto invocation = std::make_shared<clang::CompilerInvocation>();
    const bool parsed = clang::CompilerInvocation::CreateFromArgs(*invocation, args, parseDiags, argv0);
    if (!parsed) return false;

    clang::CompilerInstance clang(std::move(invocation), std::move(pch));
    clang.createVirtualFileSystem(llvm::vfs::getRealFileSystem());
    clang.createDiagnostics(new clang::TextDiagnosticPrinter(out, clang.getDiagnosticOpts()), true);
    if (!clang.hasDiagnostics()) return false;
    return clang::ExecuteCompilerInvocation(&clang);
}

// One link job: ld.lld's arguments, run through LLD's ELF driver here.
bool runLld(const llvm::opt::ArgStringList& args, llvm::raw_ostream& out) {
    std::vector<const char*> argv;
    argv.reserve(args.size() + 1);
    argv.push_back("ld.lld");
    for (const char* a : args) argv.push_back(a);
    const lld::Result result = lld::lldMain(argv, out, out, {{lld::Gnu, &lld::elf::link}});
    return result.retCode == 0;
}

char* copyText(const std::string& text) {
    char* p = static_cast<char*>(std::malloc(text.size() + 1));
    if (p) std::memcpy(p, text.c_str(), text.size() + 1);
    return p;
}

}  // namespace

extern "C" int caw_compiler_run(int argc, const char* const* argv, char** output) {
    if (output) *output = nullptr;
    std::string text;
    llvm::raw_string_ostream out(text);
    int code = 1;
    if (argc >= 1 && argv && argv[0]) {
        // Clang recurses deeply; with this it moves deep work onto a thread with 8 MB of stack when needed.
        clang::noteBottomOfStack();
        llvm::InitializeAllTargets();
        llvm::InitializeAllTargetMCs();
        llvm::InitializeAllAsmPrinters();
        llvm::InitializeAllAsmParsers();

        clang::DiagnosticOptions opts;
        clang::DiagnosticsEngine diags(clang::DiagnosticIDs::create(), opts,
                                       new clang::TextDiagnosticPrinter(out, opts));
        // The default triple is the build's own: on the phone, aarch64-linux-android.
        clang::driver::Driver driver(argv[0], llvm::sys::getDefaultTargetTriple(), diags, "C.A.W compiler");
        driver.setCheckInputsExist(true);
        std::vector<const char*> args(argv, argv + argc);
        std::unique_ptr<clang::driver::Compilation> compilation(driver.BuildCompilation(args));
        if (compilation && !diags.hasErrorOccurred() && !compilation->containsError()) {
            code = 0;
            for (const clang::driver::Command& job : compilation->getJobs()) {
                const llvm::opt::ArgStringList& jobArgs = job.getArguments();
                bool ok = false;
                if (!jobArgs.empty() && std::strcmp(jobArgs[0], "-cc1") == 0) {
                    // As clang's own driver does (ExecuteCC1Tool): the arguments from "-cc1" on.
                    llvm::cl::ResetAllOptionOccurrences();
                    ok = runCc1(jobArgs, argv[0], out);
                } else if (job.getCreator().isLinkJob()) {
                    ok = runLld(jobArgs, out);
                } else {
                    out << "error: the C.A.W compiler cannot run the '" << job.getCreator().getName()
                        << "' step in-process\n";
                }
                if (!ok) {
                    code = 1;
                    break;
                }
            }
            // Temporary objects the driver made (it keeps them on failure only when asked to).
            compilation->CleanupFileList(compilation->getTempFiles());
        }
    }
    out.flush();
    if (output) *output = copyText(text);
    return code;
}

extern "C" void caw_compiler_free(char* text) { std::free(text); }

extern "C" const char* caw_compiler_version(void) { return LLVM_VERSION_STRING; }
