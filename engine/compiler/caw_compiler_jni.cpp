// Android entry point of the compiler library: CompilerService.nativeRun(String[]) in the ":compiler" process.
#include <jni.h>

#include <string>
#include <vector>

#include "caw_compiler.h"

// Returns the exit code as decimal text, a newline, then the diagnostics, as UTF-8 bytes (bytes, not a
// String: JNI strings want modified UTF-8, and source text quoted in diagnostics may not be).
extern "C" JNIEXPORT jbyteArray JNICALL Java_com_kmandevr_caw_CompilerService_nativeRun(JNIEnv* env, jclass,
                                                                                         jobjectArray args) {
    const jsize count = args ? env->GetArrayLength(args) : 0;
    std::vector<std::string> owned;
    owned.reserve(static_cast<size_t>(count));
    for (jsize i = 0; i < count; ++i) {
        auto s = static_cast<jstring>(env->GetObjectArrayElement(args, i));
        const char* chars = s ? env->GetStringUTFChars(s, nullptr) : nullptr;
        owned.emplace_back(chars ? chars : "");
        if (chars) env->ReleaseStringUTFChars(s, chars);
        if (s) env->DeleteLocalRef(s);
    }
    std::vector<const char*> argv;
    for (const std::string& a : owned) argv.push_back(a.c_str());
    char* output = nullptr;
    const int code = caw_compiler_run(static_cast<int>(argv.size()), argv.data(), &output);
    std::string text = std::to_string(code) + "\n" + (output ? output : "");
    caw_compiler_free(output);
    jbyteArray result = env->NewByteArray(static_cast<jsize>(text.size()));
    if (result) env->SetByteArrayRegion(result, 0, static_cast<jsize>(text.size()), reinterpret_cast<const jbyte*>(text.data()));
    return result;
}
