// The pre-load scan's analysis: which format, then imports, libraries and exports by capability, system-call
// instructions, writable code, packers, entropy, strings, load-time code and the embedded declarations.
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <string_view>
#include <tuple>
#include <utility>

#include "declarations.h"
#include "parsed.h"
#include "scan.h"

namespace caw::scan {

namespace {

constexpr const char* kIds[kCapabilityCount] = {"internet",      "read_files",   "write_files",   "start_programs",
                                                "load_code",     "make_code",    "android_system", "background_threads",
                                                "encryption",    "input_spying", "packed"};
constexpr const char* kTitles[kCapabilityCount] = {"Internet",
                                                   "Reading files",
                                                   "Writing files",
                                                   "Starting programs",
                                                   "Loading more code later",
                                                   "Making new code while running",
                                                   "Phone system features (Android)",
                                                   "Background threads",
                                                   "Encryption",
                                                   "Keyboard, clipboard, screen",
                                                   "Scrambled or packed code"};

using C = Capability;

// The weight a finding has for a CLAP/VST3 plug-in: files and threads are everyday there.
Severity baseSeverity(Capability c) {
    return c == C::ReadFiles || c == C::WriteFiles || c == C::BackgroundThreads ? Severity::Notice : Severity::Warning;
}

struct Rule {
    const char* name;
    Capability capability;
    Strength strength;
    bool quiet;  // a notice whatever the capability (ambiguous, and the C++ runtime itself uses it)
};
constexpr Strength H = Strength::Hint, S = Strength::Certain;

// Imported functions by exact name. On PE an A/W (ANSI/wide) suffix is also tried without it.
constexpr Rule kImports[] = {
    // Internet
    {"socket", C::Internet, S, false}, {"connect", C::Internet, S, false}, {"bind", C::Internet, S, false},
    {"listen", C::Internet, S, false}, {"accept", C::Internet, S, false}, {"accept4", C::Internet, S, false},
    {"getaddrinfo", C::Internet, S, false}, {"gethostbyname", C::Internet, S, false},
    {"gethostbyname_r", C::Internet, S, false}, {"gethostbyname2", C::Internet, S, false},
    {"gethostbyaddr", C::Internet, S, false}, {"send", C::Internet, S, false}, {"sendto", C::Internet, S, false},
    {"sendmsg", C::Internet, S, false}, {"recv", C::Internet, S, false}, {"recvfrom", C::Internet, S, false},
    {"recvmsg", C::Internet, S, false}, {"curl_easy_init", C::Internet, S, false},
    {"curl_easy_perform", C::Internet, S, false}, {"SSL_connect", C::Internet, S, false},
    {"WSAStartup", C::Internet, S, false}, {"WSASocket", C::Internet, S, false}, {"WSAConnect", C::Internet, S, false},
    {"GetAddrInfo", C::Internet, S, false}, {"GetAddrInfoEx", C::Internet, S, false},
    {"InternetOpen", C::Internet, S, false}, {"InternetOpenUrl", C::Internet, S, false},
    {"InternetConnect", C::Internet, S, false}, {"HttpOpenRequest", C::Internet, S, false},
    {"HttpSendRequest", C::Internet, S, false}, {"WinHttpOpen", C::Internet, S, false},
    {"WinHttpConnect", C::Internet, S, false}, {"WinHttpSendRequest", C::Internet, S, false},
    {"URLDownloadToFile", C::Internet, S, false}, {"URLDownloadToCacheFile", C::Internet, S, false},
    {"URLOpenStream", C::Internet, S, false},
    // Starting programs, and reaching into other processes (debugging)
    {"execve", C::StartPrograms, S, false}, {"execv", C::StartPrograms, S, false}, {"execvp", C::StartPrograms, S, false},
    {"execvpe", C::StartPrograms, S, false}, {"execl", C::StartPrograms, S, false}, {"execlp", C::StartPrograms, S, false},
    {"execle", C::StartPrograms, S, false}, {"fexecve", C::StartPrograms, S, false}, {"fork", C::StartPrograms, S, false},
    {"vfork", C::StartPrograms, S, false}, {"system", C::StartPrograms, S, false}, {"popen", C::StartPrograms, S, false},
    {"posix_spawn", C::StartPrograms, S, false}, {"posix_spawnp", C::StartPrograms, S, false},
    {"ptrace", C::StartPrograms, S, false}, {"process_vm_readv", C::StartPrograms, S, false},
    {"process_vm_writev", C::StartPrograms, S, false}, {"CreateProcess", C::StartPrograms, S, false},
    {"CreateProcessAsUser", C::StartPrograms, S, false}, {"CreateProcessWithLogonW", C::StartPrograms, S, false},
    {"CreateProcessWithTokenW", C::StartPrograms, S, false}, {"ShellExecute", C::StartPrograms, S, false},
    {"ShellExecuteEx", C::StartPrograms, S, false}, {"WinExec", C::StartPrograms, S, false},
    {"_wsystem", C::StartPrograms, S, false}, {"_popen", C::StartPrograms, S, false}, {"_wpopen", C::StartPrograms, S, false},
    {"_execv", C::StartPrograms, S, false}, {"_execve", C::StartPrograms, S, false}, {"_execvp", C::StartPrograms, S, false},
    {"_wexecv", C::StartPrograms, S, false}, {"_spawnv", C::StartPrograms, S, false}, {"_spawnvp", C::StartPrograms, S, false},
    {"_wspawnv", C::StartPrograms, S, false}, {"WriteProcessMemory", C::StartPrograms, S, false},
    {"ReadProcessMemory", C::StartPrograms, S, false}, {"CreateRemoteThread", C::StartPrograms, S, false},
    {"CreateRemoteThreadEx", C::StartPrograms, S, false}, {"VirtualAllocEx", C::StartPrograms, S, false},
    {"VirtualProtectEx", C::StartPrograms, S, false}, {"DebugActiveProcess", C::StartPrograms, S, false},
    {"NtCreateProcess", C::StartPrograms, S, false}, {"NtCreateUserProcess", C::StartPrograms, S, false},
    {"OpenProcess", C::StartPrograms, H, false},
    // Loading more code later
    {"dlopen", C::LoadCode, S, false}, {"dlmopen", C::LoadCode, S, false}, {"dlsym", C::LoadCode, S, false},
    {"dlvsym", C::LoadCode, S, false}, {"android_dlopen_ext", C::LoadCode, S, false},
    {"__loader_dlopen", C::LoadCode, S, false}, {"__loader_android_dlopen_ext", C::LoadCode, S, false},
    {"LoadLibrary", C::LoadCode, S, false}, {"LoadLibraryEx", C::LoadCode, S, false},
    {"LoadPackagedLibrary", C::LoadCode, S, false}, {"LdrLoadDll", C::LoadCode, S, false},
    {"GetProcAddress", C::LoadCode, S, false}, {"LdrGetProcedureAddress", C::LoadCode, S, false},
    // Making memory executable
    {"mprotect", C::MakeCode, H, false}, {"pkey_mprotect", C::MakeCode, S, false}, {"memfd_create", C::MakeCode, H, false},
    {"VirtualProtect", C::MakeCode, H, false}, {"VirtualAlloc", C::MakeCode, H, false},
    {"VirtualAlloc2", C::MakeCode, H, false}, {"NtProtectVirtualMemory", C::MakeCode, S, false},
    {"NtAllocateVirtualMemory", C::MakeCode, H, false},
    // Phone system features (Android)
    {"JNI_CreateJavaVM", C::AndroidSystem, S, false}, {"JNI_GetCreatedJavaVMs", C::AndroidSystem, S, false},
    {"AAssetManager_fromJava", C::AndroidSystem, S, false}, {"ASensorManager_getInstance", C::AndroidSystem, S, false},
    {"ASensorManager_getInstanceForPackage", C::AndroidSystem, S, false},
    {"ACameraManager_create", C::AndroidSystem, S, false}, {"AAudio_createStreamBuilder", C::AndroidSystem, S, false},
    {"slCreateEngine", C::AndroidSystem, S, false},
    // Background threads
    {"pthread_create", C::BackgroundThreads, S, false}, {"thrd_create", C::BackgroundThreads, S, false},
    {"CreateThread", C::BackgroundThreads, S, false}, {"_beginthread", C::BackgroundThreads, S, false},
    {"_beginthreadex", C::BackgroundThreads, S, false}, {"_Thrd_create", C::BackgroundThreads, S, false},
    {"_Thrd_start", C::BackgroundThreads, S, false}, {"CreateThreadpoolWork", C::BackgroundThreads, S, false},
    {"SubmitThreadpoolWork", C::BackgroundThreads, S, false}, {"TrySubmitThreadpoolCallback", C::BackgroundThreads, S, false},
    {"CreateThreadpoolTimer", C::BackgroundThreads, S, false}, {"QueueUserWorkItem", C::BackgroundThreads, S, false},
    {"CreateTimerQueueTimer", C::BackgroundThreads, S, false},
    // Keyboard, clipboard, screen (and the Windows registry, with them in the plan's list)
    {"SetWindowsHookEx", C::InputSpying, S, false}, {"GetAsyncKeyState", C::InputSpying, S, false},
    {"GetKeyboardState", C::InputSpying, S, false}, {"RegisterRawInputDevices", C::InputSpying, S, false},
    {"OpenClipboard", C::InputSpying, S, false}, {"GetClipboardData", C::InputSpying, S, false},
    {"SetClipboardData", C::InputSpying, S, false}, {"XGrabKeyboard", C::InputSpying, S, false},
    {"XGrabKey", C::InputSpying, S, false}, {"XQueryKeymap", C::InputSpying, S, false},
    {"RegOpenKeyEx", C::InputSpying, S, false}, {"RegCreateKeyEx", C::InputSpying, S, false},
    {"RegSetValueEx", C::InputSpying, S, false}, {"RegQueryValueEx", C::InputSpying, S, false},
    {"RegDeleteKey", C::InputSpying, S, false}, {"RegDeleteValue", C::InputSpying, S, false},
    {"RegEnumKeyEx", C::InputSpying, S, false}, {"RegGetValue", C::InputSpying, S, false},
    // Encryption (prefix rules below cover the libraries' families)
    {"CryptEncrypt", C::Encryption, S, false}, {"CryptDecrypt", C::Encryption, S, false},
    {"CryptAcquireContext", C::Encryption, S, false}, {"CryptImportKey", C::Encryption, S, false},
    {"CryptGenKey", C::Encryption, S, false}, {"CryptProtectData", C::Encryption, S, false},
    {"BCryptEncrypt", C::Encryption, S, false}, {"BCryptDecrypt", C::Encryption, S, false},
    {"BCryptOpenAlgorithmProvider", C::Encryption, S, false}, {"BCryptGenerateSymmetricKey", C::Encryption, S, false},
    {"NCryptEncrypt", C::Encryption, S, false}, {"NCryptDecrypt", C::Encryption, S, false},
    // Reading files
    {"fopen", C::ReadFiles, S, false}, {"fopen64", C::ReadFiles, S, false}, {"freopen", C::ReadFiles, S, false},
    {"freopen64", C::ReadFiles, S, false}, {"opendir", C::ReadFiles, S, false}, {"fdopendir", C::ReadFiles, S, false},
    {"_wfopen", C::ReadFiles, S, false}, {"fopen_s", C::ReadFiles, S, false}, {"_wfopen_s", C::ReadFiles, S, false},
    {"_open", C::ReadFiles, S, false}, {"_wopen", C::ReadFiles, S, false}, {"_wsopen_s", C::ReadFiles, S, false},
    {"_sopen_s", C::ReadFiles, S, false}, {"CreateFile", C::ReadFiles, S, false}, {"CreateFile2", C::ReadFiles, S, false},
    {"ReadFile", C::ReadFiles, S, false}, {"FindFirstFile", C::ReadFiles, S, false},
    {"FindFirstFileEx", C::ReadFiles, S, false}, {"OpenFile", C::ReadFiles, S, false},
    // The C++ runtime opens /dev/urandom (std::random_device) through these when linked statically, so they
    // are hints, shown as notices: a component that uses them only through fopen or a stream is still caught.
    {"open", C::ReadFiles, H, true}, {"open64", C::ReadFiles, H, true}, {"openat", C::ReadFiles, H, true},
    {"openat64", C::ReadFiles, H, true}, {"__open_2", C::ReadFiles, H, true}, {"__openat_2", C::ReadFiles, H, true},
    // Writing files
    {"unlink", C::WriteFiles, S, false}, {"unlinkat", C::WriteFiles, S, false}, {"rename", C::WriteFiles, S, false},
    {"renameat", C::WriteFiles, S, false}, {"renameat2", C::WriteFiles, S, false}, {"remove", C::WriteFiles, S, false},
    {"rmdir", C::WriteFiles, S, false}, {"mkdir", C::WriteFiles, S, false}, {"mkdirat", C::WriteFiles, S, false},
    {"truncate", C::WriteFiles, S, false}, {"ftruncate", C::WriteFiles, S, false}, {"creat", C::WriteFiles, S, false},
    {"link", C::WriteFiles, S, false}, {"symlink", C::WriteFiles, S, false}, {"WriteFile", C::WriteFiles, S, false},
    {"DeleteFile", C::WriteFiles, S, false}, {"MoveFile", C::WriteFiles, S, false}, {"MoveFileEx", C::WriteFiles, S, false},
    {"CopyFile", C::WriteFiles, S, false}, {"CopyFileEx", C::WriteFiles, S, false},
    {"RemoveDirectory", C::WriteFiles, S, false}, {"CreateDirectory", C::WriteFiles, S, false},
    {"SetFileAttributes", C::WriteFiles, S, false}, {"_wremove", C::WriteFiles, S, false},
    {"_unlink", C::WriteFiles, S, false}, {"_wunlink", C::WriteFiles, S, false}, {"_wrename", C::WriteFiles, S, false},
    {"_mkdir", C::WriteFiles, S, false}, {"_wmkdir", C::WriteFiles, S, false},
    // syscall(): any system call by number (connect, execve, ...) past the import table. A statically linked
    // C++ runtime may use it for futexes; it still has to be declared (as packed).
    {"syscall", C::Packed, S, false},
    // Threads, loaders and files below libc's usual names.
    {"clone", C::BackgroundThreads, S, false}, {"clone3", C::BackgroundThreads, S, false},
    {"_r_debug", C::LoadCode, S, false}, {"_dl_debug_state", C::LoadCode, S, false},
    // The unwinder (libunwind, libgcc) walks the loaded libraries through this on every exception.
    {"dl_iterate_phdr", C::LoadCode, H, true},
    // ntdll (Zw* names are folded to Nt*): files, sockets (AFD through NtDeviceIoControlFile), threads, code.
    {"NtCreateFile", C::ReadFiles, S, false}, {"NtOpenFile", C::ReadFiles, S, false},
    {"NtReadFile", C::ReadFiles, S, false}, {"NtQueryDirectoryFile", C::ReadFiles, S, false},
    {"NtWriteFile", C::WriteFiles, S, false}, {"NtDeleteFile", C::WriteFiles, S, false},
    {"NtSetInformationFile", C::WriteFiles, S, false}, {"NtDeviceIoControlFile", C::Internet, S, false},
    {"NtCreateThread", C::BackgroundThreads, S, false}, {"NtCreateThreadEx", C::BackgroundThreads, S, false},
    {"RtlCreateUserThread", C::BackgroundThreads, S, false}, {"NtCreateSection", C::MakeCode, H, false},
    {"NtMapViewOfSection", C::MakeCode, H, false}, {"NtWriteVirtualMemory", C::StartPrograms, S, false},
    {"NtReadVirtualMemory", C::StartPrograms, S, false}, {"NtOpenProcess", C::StartPrograms, S, false},
    {"LdrGetDllHandle", C::LoadCode, S, false},
};

// Name prefixes (encryption libraries' families).
constexpr Rule kPrefixes[] = {
    {"EVP_Encrypt", C::Encryption, S, false}, {"EVP_Decrypt", C::Encryption, S, false},
    {"EVP_Cipher", C::Encryption, S, false},  {"EVP_aes_", C::Encryption, S, false},
    {"EVP_chacha20", C::Encryption, S, false}, {"AES_set_encrypt_key", C::Encryption, S, false},
    {"AES_set_decrypt_key", C::Encryption, S, false}, {"AES_encrypt", C::Encryption, S, false},
    {"AES_decrypt", C::Encryption, S, false}, {"AES_cbc_encrypt", C::Encryption, S, false},
    {"mbedtls_aes_", C::Encryption, S, false}, {"mbedtls_cipher_", C::Encryption, S, false},
    {"gcry_cipher_", C::Encryption, S, false}, {"crypto_secretbox", C::Encryption, S, false},
    {"crypto_aead_", C::Encryption, S, false}, {"crypto_box", C::Encryption, S, false},
    {"crypto_stream_", C::Encryption, S, false}, {"__std_fs_", C::ReadFiles, S, false},
};

// Needed libraries (ELF sonames by prefix, PE DLLs by name, both lowercase).
constexpr Rule kLibraries[] = {
    {"libcurl", C::Internet, S, false},       {"libssl", C::Internet, S, false},
    {"libmbedtls", C::Internet, S, false},    {"libcrypto", C::Encryption, S, false},
    {"libmbedcrypto", C::Encryption, S, false}, {"libsodium", C::Encryption, S, false},
    {"libgcrypt", C::Encryption, S, false},   {"libnativehelper", C::AndroidSystem, S, false},
    {"libcamera2ndk", C::AndroidSystem, S, false}, {"libaaudio", C::AndroidSystem, S, false},
    {"libopensles", C::AndroidSystem, S, false}, {"libjnigraphics", C::AndroidSystem, S, false},
    {"ws2_32.dll", C::Internet, S, false},    {"wsock32.dll", C::Internet, S, false},
    {"winhttp.dll", C::Internet, S, false},   {"wininet.dll", C::Internet, S, false},
    {"urlmon.dll", C::Internet, S, false},    {"dnsapi.dll", C::Internet, S, false},
    {"ncrypt.dll", C::Encryption, S, false},
};

constexpr const char* kPackerSections[] = {
    "upx0", "upx1", "upx2", "upx!", ".upx0", ".upx1", ".aspack", ".adata", "aspack", ".petite", ".themida",
    "themida", ".vmp0", ".vmp1", ".vmp2", ".enigma1", ".enigma2", ".mpress1", ".mpress2", "mpress1", "mpress2",
    ".nsp0", ".nsp1", ".nsp2", "pec2", "pec2to", "pebundle", ".packed", ".perplex", ".winlice", ".boom", ".ccg"};

std::string lower(std::string_view s) {
    std::string o(s);
    for (char& c : o) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return o;
}

// Printable ASCII only (a binary's strings are untrusted bytes, and the JSON must stay valid UTF-8).
std::string cleanEvidence(std::string_view s) {
    std::string o;
    for (char ch : s.substr(0, 160)) {
        const unsigned char c = static_cast<unsigned char>(ch);
        o.push_back(c >= 0x20 && c < 0x7F ? ch : '?');
    }
    return o;
}

std::string hex(uint64_t v) {
    static const char kHex[] = "0123456789abcdef";
    std::string s;
    do {
        s.insert(s.begin(), kHex[v & 15]);
        v >>= 4;
    } while (v);
    return "0x" + s;
}

class Findings {
public:
    Findings(const Limits& l, std::vector<Finding>& out) : L_(l), out_(out) {}
    void add(Capability c, FindingKind k, std::string_view evidence, Strength s, Severity sev) {
        std::string e = cleanEvidence(evidence);
        if (!seen_.insert({static_cast<int>(c), static_cast<int>(k), e}).second) return;
        // The first finding of each capability and kind is always kept (at most 11 x 11), so no number of
        // findings of one kind can push out the evidence of another; later ones are capped.
        uint32_t& n = perKind_[static_cast<int>(c) * 16 + static_cast<int>(k)];
        if (n++ > 0 && (out_.size() >= L_.maxFindings || n > L_.maxFindingsPerKind)) return;
        out_.push_back({c, k, std::move(e), s, sev});
    }
    void rule(const Rule& r, FindingKind k, std::string_view evidence) {
        add(r.capability, k, evidence, r.strength, r.quiet ? Severity::Notice : baseSeverity(r.capability));
    }

private:
    const Limits& L_;
    std::vector<Finding>& out_;
    std::set<std::tuple<int, int, std::string>> seen_;
    std::map<int, uint32_t> perKind_;
};

const Rule* findImport(std::string_view name, bool pe) {
    std::string folded;
    if (pe && name.substr(0, 2) == "Zw") {
        folded = "Nt" + std::string(name.substr(2));
        name = folded;
    }
    for (const Rule& r : kImports)
        if (name == r.name) return &r;
    if (pe && name.size() > 1 && (name.back() == 'A' || name.back() == 'W')) {
        const std::string_view base = name.substr(0, name.size() - 1);
        for (const Rule& r : kImports)
            if (base == r.name) return &r;
    }
    for (const Rule& r : kPrefixes)
        if (name.substr(0, std::strlen(r.name)) == r.name) return &r;
    return nullptr;
}

constexpr Rule kThread{"", C::BackgroundThreads, S, false}, kRead{"", C::ReadFiles, S, false},
    kWrite{"", C::WriteFiles, S, false};

// C++ standard library entry points by their mangled names (libstdc++ and libc++ use the Itanium ABI;
// MSVC's runtime is covered by its C names: _Thrd_*, __std_fs_*).
const Rule* findMangled(std::string_view name) {
    if (name.substr(0, 2) != "_Z") return nullptr;
    auto has = [&](const char* s) { return name.find(s) != std::string_view::npos; };
    if (has("_M_start_thread")) return &kThread;
    if (has("basic_filebuf") && has("4open")) return &kRead;
    if (const size_t fs = name.find("10filesystem"); fs != std::string_view::npos) {
        // Members of std::filesystem::path only work on text; everything else in the namespace touches files.
        const std::string_view rest = name.substr(fs + 12);
        if (rest.substr(0, 13) == "7__cxx114path" || rest.substr(0, 5) == "4path") return nullptr;
        for (const char* w : {"6remove", "10remove_all", "6rename", "16create_directory", "18create_directories",
                              "9copy_file", "11resize_file", "14create_symlink", "15create_hard_link", "11permissions",
                              "23create_directory_symlink"})
            if (has(w)) return &kWrite;
        if (has("15last_write_time") && has("chrono")) return &kWrite;  // the setter
        return &kRead;
    }
    return nullptr;
}

// Libraries a component may need: the system's C and C++ runtimes and libraries that come with the operating
// system (never ones a downloaded component could bring along). ELF sonames exactly; PE DLLs by name, plus the
// API-set prefixes. Anything else, and any RPATH/RUNPATH, is a dependency the scan has not seen.
constexpr const char* kSystemElf[] = {
    "libc.so", "libc.so.6", "libm.so", "libm.so.6", "libdl.so", "libdl.so.2", "libpthread.so.0", "librt.so.1",
    "libstdc++.so.6", "libgcc_s.so.1", "libc++_shared.so", "libc++.so.1", "libc++abi.so.1", "libatomic.so.1",
    "libmvec.so.1", "ld-linux-x86-64.so.2", "ld-linux-aarch64.so.1", "liblog.so", "libandroid.so",
    "libaaudio.so", "libOpenSLES.so", "libmediandk.so", "libnativewindow.so", "libz.so"};
constexpr const char* kSystemPe[] = {
    "kernel32.dll", "kernelbase.dll", "ntdll.dll", "user32.dll", "gdi32.dll", "advapi32.dll", "ole32.dll",
    "oleaut32.dll", "shell32.dll", "shlwapi.dll", "comdlg32.dll", "comctl32.dll", "winmm.dll", "avrt.dll",
    "powrprof.dll", "version.dll", "imm32.dll", "uxtheme.dll", "dwmapi.dll", "setupapi.dll", "cfgmgr32.dll",
    "psapi.dll", "dbghelp.dll", "userenv.dll", "secur32.dll", "crypt32.dll", "bcrypt.dll", "ncrypt.dll",
    "rpcrt4.dll", "ws2_32.dll", "wsock32.dll", "mswsock.dll", "winhttp.dll", "wininet.dll", "urlmon.dll",
    "dnsapi.dll", "iphlpapi.dll", "opengl32.dll", "dxgi.dll", "d3d11.dll", "d3d12.dll", "mmdevapi.dll",
    "ksuser.dll", "msvcrt.dll", "ucrtbase.dll", "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll",
    "msvcp140_1.dll", "msvcp140_2.dll", "msvcp140_atomic_wait.dll", "concrt140.dll", "vcomp140.dll"};

bool systemLibrary(const std::string& name, bool pe) {
    if (!pe) {
        for (const char* s : kSystemElf)
            if (name == s) return true;
        return false;
    }
    const std::string l = lower(name);
    if (l.rfind("api-ms-win-", 0) == 0 || l.rfind("ext-ms-win-", 0) == 0) return true;
    for (const char* s : kSystemPe)
        if (l == s) return true;
    return false;
}

// DLLs whose every function is the internet: an import from them by ordinal is internet too.
bool internetDll(const std::string& l) {
    return l == "ws2_32.dll" || l == "wsock32.dll" || l == "wininet.dll" || l == "winhttp.dll" || l == "urlmon.dll" ||
           l == "dnsapi.dll";
}

bool fileOpen(const std::string& n) {
    return n == "fopen" || n == "fopen64" || n == "freopen" || n == "freopen64" || n == "_wfopen" ||
           n == "fopen_s" || n == "_wfopen_s" || n == "_open" || n == "_wopen" || n == "_wsopen_s" || n == "_sopen_s" ||
           (n.substr(0, 2) == "_Z" && n.find("basic_filebuf") != std::string::npos && n.find("4open") != std::string::npos);
}
bool fileWrite(const std::string& n) {
    return n == "fwrite" || n == "fputs" || n == "fputc" || n == "fprintf" || n == "vfprintf" || n == "fputws" ||
           n == "fwprintf" || n == "_write" || n == "fflush" ||
           (n.substr(0, 2) == "_Z" && (n.find("basic_ofstream") != std::string::npos ||
                                       n.find("basic_fstream") != std::string::npos || n.find("_ZNSo") == 0 ||
                                       n.find("basic_ostream") != std::string::npos));
}

void classifyImports(const Parsed& p, Findings& f) {
    const bool pe = p.format == Format::Pe32Plus;
    std::string opened, written;
    for (const Import& im : p.imports) {
        if (opened.empty() && fileOpen(im.name)) opened = im.name;
        if (written.empty() && fileWrite(im.name)) written = im.name;
        if (im.name.substr(0, 2) == "_Z" &&
            (im.name.find("basic_ofstream") != std::string::npos || im.name.find("basic_fstream") != std::string::npos))
            f.rule(kWrite, FindingKind::Import, im.name);
    }
    // A file opened and something written: the open's mode can't be seen, so it may be a write.
    if (!opened.empty() && !written.empty()) f.rule(kWrite, FindingKind::Import, opened + " + " + written);
    for (const std::string& path : p.searchPaths)
        f.add(C::LoadCode, FindingKind::Dependency, "library search path " + path, S, Severity::Warning);
    for (const std::string& library : p.libraries)
        if (!systemLibrary(library, pe))
            f.add(C::LoadCode, FindingKind::Dependency, "needs " + library + ", which is not a system library", S,
                  Severity::Warning);
    for (const Import& im : p.imports) {
        const std::string evidence = pe ? im.library + "!" + (im.name.empty() ? "#ordinal" : im.name) : im.name;
        if (im.name.empty()) {
            // By ordinal: the name is hidden. From an internet DLL it is the internet; from another it hides which
            // function it is.
            if (internetDll(im.library)) f.add(C::Internet, FindingKind::Import, evidence, S, Severity::Warning);
            else f.add(C::Packed, FindingKind::Import, im.library + " by ordinal (the function is hidden)", Strength::Hint,
                       Severity::Warning);
            continue;
        }
        if (pe && (im.name == "__std_fs_remove" || im.name == "__std_fs_rename" ||
                   im.name.rfind("__std_fs_create_directory", 0) == 0 || im.name.rfind("__std_fs_copy_file", 0) == 0)) {
            f.rule(kWrite, FindingKind::Import, evidence);
            continue;
        }
        if (const Rule* r = findImport(im.name, pe)) f.rule(*r, FindingKind::Import, evidence);
        else if (const Rule* m = findMangled(im.name)) f.rule(*m, FindingKind::Import, evidence);
    }
    for (const std::string& library : p.libraries) {
        const std::string l = lower(library);
        for (const Rule& r : kLibraries)
            if (pe ? l == r.name : l.rfind(r.name, 0) == 0) f.rule(r, FindingKind::Library, library);
    }
    for (const std::string& e : p.exports)
        f.add(C::AndroidSystem, FindingKind::Export, e, S, Severity::Warning);
}

void scanSyscalls(const ByteReader& r, const Parsed& p, Findings& f) {
    if (p.arch == "aarch64" && p.format == Format::Elf64) {
        // svc, the system call: fixed-width instructions, so an aligned match in what the loader maps executable
        // (the executable segments rounded out to 64 KiB) is code.
        uint64_t first = 0, count = 0;
        for (const FileRange& s : p.execSegments) {
            for (uint64_t at = (s.offset + 3) & ~uint64_t(3); at + 4 <= s.offset + s.size; at += 4) {
                uint32_t v = 0;
                r.u32(at, v);
                // SVC #imm16 is 0xD4000001 | imm16 << 5 (Arm A64 encoding, from memory; not re-read from Arm's manual):
                // any immediate, since the kernel ignores it.
                if ((v & 0xFFE0001Fu) == 0xD4000001u && count++ == 0) first = at;
            }
        }
        if (count)
            f.add(C::Packed, FindingKind::Syscall,
                  "svc at file offset " + hex(first) + " (" + std::to_string(count) + " in all)", S, Severity::Warning);
    } else if (p.arch == "x86_64") {
        // syscall (0F 05) and int 0x80 (CD 80) in what the loader maps executable. Variable-length code, so a lone
        // byte match is a hint (large honest libraries hold a few by chance); one after a mov of a system call
        // number into eax/rax (B8 imm32, 48 C7 C0 imm32) starting 5 to 12 bytes before is how a system call is made,
        // and is certain (measured 2026-11-18: glibc has hundreds, libstdc++, libcaw, caw_tests and every starter
        // none).
        uint64_t first = 0, count = 0, strongFirst = 0, strong = 0;
        for (const FileRange& s : p.execSegments) {
            const uint8_t* b = r.data() + s.offset;
            for (uint64_t i = 1; i < s.size; ++i) {
                if (!((b[i - 1] == 0x0F && b[i] == 0x05) || (b[i - 1] == 0xCD && b[i] == 0x80))) continue;
                const uint64_t at = s.offset + i - 1;
                if (count++ == 0) first = at;
                bool mov = false;
                for (uint64_t back = 5; back <= 12 && back <= i - 1 && !mov; ++back) {
                    const uint8_t* m = b + (i - 1) - back;
                    mov = m[0] == 0xB8 || (back >= 7 && m[0] == 0x48 && m[1] == 0xC7 && m[2] == 0xC0);
                }
                if (mov && strong++ == 0) strongFirst = at;
            }
        }
        if (strong)
            f.add(C::Packed, FindingKind::Syscall,
                  "system call after a call number at file offset " + hex(strongFirst) + " (" +
                      std::to_string(strong) + " in all)", S, Severity::Warning);
        else if (count)
            f.add(C::Packed, FindingKind::Syscall,
                  "system call bytes at file offset " + hex(first) + " (" + std::to_string(count) + " in all)",
                  Strength::Hint, Severity::Notice);
    }
}

double entropy(const ByteReader& r, const std::vector<const FileRange*>& ranges, uint64_t& total) {
    uint64_t counts[256] = {};
    total = 0;
    for (const FileRange* s : ranges) {
        const uint8_t* b = r.data() + s->offset;
        for (uint64_t i = 0; i < s->size; ++i) ++counts[b[i]];
        total += s->size;
    }
    if (total == 0) return 0;
    double h = 0;
    for (uint64_t c : counts)
        if (c) {
            const double q = double(c) / double(total);
            h -= q * std::log2(q);
        }
    return h;
}

std::string bits(double h) {
    char buf[32];
    std::snprintf(buf, sizeof buf, "%.2f", h);
    return buf;
}

void scanSections(const ByteReader& r, const Parsed& p, Findings& f) {
    for (const std::string& name : p.writableExecutable)
        f.add(C::Packed, FindingKind::Section, "writable and executable: " + (name.empty() ? "(unnamed)" : name), S,
              Severity::Warning);
    if (p.textRelocations)
        f.add(C::Packed, FindingKind::Section, "text relocations (the loader writes into its code)", Strength::Hint,
              Severity::Warning);
    for (const std::string& name : p.sectionNames) {
        const std::string l = lower(name);
        for (const char* packer : kPackerSections)
            if (l == packer) f.add(C::Packed, FindingKind::Section, "packer section " + name, S, Severity::Warning);
    }
    std::vector<const FileRange*> code;
    for (const FileRange& s : p.execCode) code.push_back(&s);
    uint64_t total = 0;
    const double h = entropy(r, code, total);
    if (total >= 4096 && h > 7.2)
        f.add(C::Packed, FindingKind::Entropy, "executable code at " + bits(h) + " bits per byte", Strength::Hint,
              Severity::Warning);
    for (const FileRange& s : p.dataSections) {
        if (s.size < (64u << 10)) continue;
        const double d = entropy(r, {&s}, total);
        if (d > 7.9)
            f.add(C::Packed, FindingKind::Entropy,
                  "data " + (s.name.empty() ? std::string("(unnamed)") : s.name) + " at " + bits(d) + " bits per byte",
                  Strength::Hint, Severity::Notice);
    }
}

bool isIpv4(std::string_view s, size_t at, size_t& length) {
    int parts = 0;
    size_t i = at;
    while (parts < 4) {
        size_t digits = 0;
        int value = 0;
        while (i < s.size() && s[i] >= '0' && s[i] <= '9' && digits < 4) value = value * 10 + (s[i++] - '0'), ++digits;
        if (digits == 0 || digits > 3 || value > 255) return false;
        if (parts == 0 && value == 0) return false;
        if (++parts < 4) {
            if (i >= s.size() || s[i] != '.') return false;
            ++i;
        }
    }
    if (i < s.size() && ((s[i] >= '0' && s[i] <= '9') || s[i] == '.')) return false;
    length = i - at;
    return true;
}

void checkString(std::string_view s, Findings& f) {
    const std::string l = lower(s);
    auto upTo = [&](size_t at) {
        size_t end = at;
        while (end < s.size() && s[end] != ' ' && s[end] != '"' && s[end] != '\'' && s[end] != '<' && s[end] != '>')
            ++end;
        return s.substr(at, std::min<size_t>(end - at, 120));
    };
    for (const char* scheme : {"https://", "http://", "ftp://", "wss://", "ws://"}) {
        const size_t at = l.find(scheme);
        if (at != std::string::npos && (at == 0 || !std::isalpha(static_cast<unsigned char>(l[at - 1]))))
            f.add(C::Internet, FindingKind::String, upTo(at), Strength::Hint, Severity::Notice);
    }
    if (const size_t at = l.find(".onion"); at != std::string::npos) {
        size_t start = at;
        while (start > 0 && ((l[start - 1] >= 'a' && l[start - 1] <= 'z') || (l[start - 1] >= '2' && l[start - 1] <= '7')))
            --start;
        if (at - start >= 16) f.add(C::Internet, FindingKind::String, s.substr(start, at + 6 - start), Strength::Hint,
                                    Severity::Warning);
    }
    for (const char* shell : {"/system/bin/sh", "/system/xbin/su", "/bin/sh", "/bin/bash", "cmd.exe", "powershell"})
        if (l.find(shell) != std::string::npos)
            f.add(C::StartPrograms, FindingKind::String, shell, Strength::Hint, Severity::Warning);
    for (const char* wallet : {"wallet.dat", "electrum", "metamask", "nkbihfbeogaeaoehlefnkodbefgpgknn", "login data",
                               "logins.json", "key4.db", "cookies.sqlite", "chrome/user data", "chrome\\user data",
                               "firefox/profiles", "firefox\\profiles", "/.bitcoin", "\\bitcoin\\", "ethereum/keystore",
                               "ethereum\\keystore", "exodus\\exodus.wallet"})
        if (l.find(wallet) != std::string::npos)
            f.add(C::ReadFiles, FindingKind::String, "wallet or browser profile: " + std::string(wallet), Strength::Hint,
                  Severity::Warning);
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] < '0' || s[i] > '9' || (i > 0 && ((s[i - 1] >= '0' && s[i - 1] <= '9') || s[i - 1] == '.'))) continue;
        size_t length = 0;
        if (isIpv4(s, i, length)) {
            f.add(C::Internet, FindingKind::String, "address " + std::string(s.substr(i, length)), Strength::Hint,
                  Severity::Notice);
            i += length;
        }
    }
}

// Printable runs of at least 6 characters, as ASCII and as UTF-16LE, within the string byte budget.
void scanStrings(const ByteReader& r, const Limits& L, Findings& f) {
    const uint64_t n = std::min<uint64_t>(r.size(), L.maxStringScanBytes);
    const uint8_t* b = r.data();
    constexpr size_t kMinRun = 6, kMaxRun = 1024;
    auto printable = [](uint8_t c) { return c >= 0x20 && c < 0x7F; };
    std::string run;
    auto flush = [&] {
        if (run.size() >= kMinRun) checkString(run, f);
        run.clear();
    };
    for (uint64_t i = 0; i < n; ++i) {
        if (printable(b[i])) {
            run.push_back(char(b[i]));
            if (run.size() >= kMaxRun) flush();
        } else {
            flush();
        }
    }
    flush();
    for (uint64_t start = 0; start < 2; ++start) {
        for (uint64_t i = start; i + 1 < n; i += 2) {
            if (printable(b[i]) && b[i + 1] == 0) {
                run.push_back(char(b[i]));
                if (run.size() >= kMaxRun) flush();
            } else {
                flush();
            }
        }
        flush();
    }
    // UPX marks what it packs, sections or not.
    for (uint64_t i = 0; i + 4 <= std::min<uint64_t>(n, 1u << 20); ++i)
        if (b[i] == 'U' && b[i + 1] == 'P' && b[i + 2] == 'X' && b[i + 3] == '!') {
            f.add(C::Packed, FindingKind::String, "UPX! marker at file offset " + hex(i), Strength::Hint,
                  Severity::Warning);
            break;
        }
}

void readDeclarations(const ByteReader& r, const Parsed& p, const Limits& L, Report& report, Findings& f) {
    if (p.declarationSections.empty()) return;
    auto invalid = [&](const std::string& why) {
        report.declarationState = Report::DeclarationState::Invalid;
        report.declarations.clear();
        f.add(C::Packed, FindingKind::Declarations, why, S, Severity::Warning);
    };
    if (p.declarationSections.size() > 1) return invalid("more than one capability declaration section");
    const FileRange& s = p.declarationSections.front();
    if (s.size > L.maxDeclarationBytes) return invalid("the declaration section is larger than 16 KiB");
    std::string error;
    const std::string_view bytes(reinterpret_cast<const char*>(r.data() + s.offset), s.size);
    if (!parseDeclarationSection(bytes, L.maxDeclarationBytes, L.maxDeclarations, report.declarations, error))
        return invalid(error);
    report.declarationState = Report::DeclarationState::Valid;
    report.declarationsCanonical = canonicalDeclarations(report.declarations);
}

}  // namespace

const char* capabilityId(Capability c) noexcept {
    const size_t i = static_cast<size_t>(c);
    return i < kCapabilityCount ? kIds[i] : "unknown";
}
const char* capabilityTitle(Capability c) noexcept {
    const size_t i = static_cast<size_t>(c);
    return i < kCapabilityCount ? kTitles[i] : "Unknown";
}
bool capabilityFromId(std::string_view id, Capability& out) noexcept {
    for (size_t i = 0; i < kCapabilityCount; ++i)
        if (id == kIds[i]) {
            out = static_cast<Capability>(i);
            return true;
        }
    return false;
}
const char* findingKindId(FindingKind k) noexcept {
    switch (k) {
        case FindingKind::Import: return "import";
        case FindingKind::Library: return "library";
        case FindingKind::Export: return "export";
        case FindingKind::Syscall: return "syscall";
        case FindingKind::Section: return "section";
        case FindingKind::Entropy: return "entropy";
        case FindingKind::String: return "string";
        case FindingKind::LoadTime: return "load_time";
        case FindingKind::Malformed: return "malformed";
        case FindingKind::Unsupported: return "unsupported";
        case FindingKind::Declarations: return "declarations";
        case FindingKind::Dependency: return "dependency";
    }
    return "unknown";
}

Report scanBinary(std::span<const uint8_t> bytes, const Limits& limits) {
    Report report;
    Findings f(limits, report.findings);
    if (bytes.size() > limits.maxFileBytes) {
        report.malformed = true;
        f.add(C::Packed, FindingKind::Malformed, "the file is larger than the scan reads (256 MiB)", S, Severity::Warning);
        return report;
    }
    const ByteReader r(bytes);
    WorkBudget budget{limits.workBudget};
    Parsed p;
    std::string unsupported;
    const uint8_t* b = bytes.data();
    const size_t n = bytes.size();
    if (n >= 4 && b[0] == 0x7F && b[1] == 'E' && b[2] == 'L' && b[3] == 'F') {
        if (n >= 6 && b[4] == 2 && b[5] == 1) parseElf(r, limits, budget, p);
        else unsupported = "an ELF file that is not 64-bit little-endian";
    } else if (n >= 2 && b[0] == 'M' && b[1] == 'Z') {
        uint32_t pe = 0;
        uint16_t magic = 0;
        if (!r.u32(0x3c, pe) || !r.has(pe, 4) || std::memcmp(b + pe, "PE\0\0", 4) != 0)
            unsupported = "an MZ file without a PE header";
        else if (!r.u16(uint64_t(pe) + 24, magic)) p.format = Format::Pe32Plus, p.malformed = "the PE header is cut short";
        else if (magic == 0x20B) parsePe(r, limits, budget, p);
        else unsupported = magic == 0x10B ? "a 32-bit PE file" : "a PE file of an unknown kind";
    } else {
        unsupported = "not an ELF or PE file";
    }
    report.format = p.format;
    report.arch = p.format == Format::Unknown ? "other" : p.arch;
    if (!unsupported.empty()) {
        f.add(C::Packed, FindingKind::Unsupported, unsupported, S, Severity::Warning);
        return report;
    }
    if (!p.malformed.empty()) {
        report.malformed = true;
        f.add(C::Packed, FindingKind::Malformed, p.malformed, S, Severity::Warning);
    }
    report.imports = p.imports.size();
    report.constructors = p.constructors;
    report.tlsCallbacks = p.tlsCallbacks;
    report.componentEntry = p.componentEntry;
    // A malformed file still gets the byte-level checks on what parsed: they only read checked ranges.
    classifyImports(p, f);
    scanSyscalls(r, p, f);
    scanSections(r, p, f);
    scanStrings(r, limits, f);
    if (p.constructors > 16)
        f.add(C::Packed, FindingKind::LoadTime, std::to_string(p.constructors) + " constructors run when it loads",
              Strength::Hint, Severity::Notice);
    if (p.tlsCallbacks > 0)
        f.add(C::Packed, FindingKind::LoadTime, std::to_string(p.tlsCallbacks) + " TLS callbacks run when it loads",
              S, Severity::Notice);
    readDeclarations(r, p, limits, report, f);
    return report;
}

}  // namespace caw::scan
