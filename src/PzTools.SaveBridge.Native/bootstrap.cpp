#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <jni.h>
#include <cwchar>
#include <string>

// A standard JVMTI agent, not remote-thread injection. Some embedded JVM launchers
// do not load jli.dll or place the JRE bin directory on the DLL search path.
// Load only that dependency from the already-running JVM's own installation.
extern "C" JNIEXPORT jint JNICALL Agent_OnAttach(JavaVM*, char*, void*) {
    if (GetModuleHandleW(L"jli.dll") != nullptr) return JNI_OK;
    HMODULE jvm = GetModuleHandleW(L"jvm.dll");
    if (jvm == nullptr) return JNI_ERR;
    wchar_t path[32768];
    DWORD length = GetModuleFileNameW(jvm, path, static_cast<DWORD>(std::size(path)));
    if (length == 0 || length >= std::size(path)) return JNI_ERR;
    std::wstring directory(path, length);
    auto last = directory.find_last_of(L"\\/");
    if (last == std::wstring::npos) return JNI_ERR;
    directory.resize(last); // .../bin/server
    last = directory.find_last_of(L"\\/");
    if (last == std::wstring::npos || directory.substr(last + 1) != L"server") return JNI_ERR;
    directory.resize(last); // .../bin
    directory += L"\\jli.dll";
    // The dependency remains loaded for the life of the JVM. Do not alter the
    // process-wide DLL search path or load a DLL from our own Java distribution.
    HMODULE launcher = LoadLibraryExW(directory.c_str(), nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    return launcher != nullptr ? JNI_OK : JNI_ERR;
}
