#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <jni.h>
#include <cwchar>
#include <string>

// The bin folder of the JVM this library is loaded into (the folder above bin\server\jvm.dll), or empty.
static std::wstring JvmBinDirectory() {
    HMODULE jvm = GetModuleHandleW(L"jvm.dll");
    if (jvm == nullptr) return {};
    wchar_t path[32768];
    DWORD length = GetModuleFileNameW(jvm, path, static_cast<DWORD>(std::size(path)));
    if (length == 0 || length >= std::size(path)) return {};
    std::wstring directory(path, length);
    auto last = directory.find_last_of(L"\\/");
    if (last == std::wstring::npos) return {};
    directory.resize(last); // .../bin/server
    last = directory.find_last_of(L"\\/");
    if (last == std::wstring::npos || directory.substr(last + 1) != L"server") return {};
    directory.resize(last); // .../bin
    return directory;
}

// Loads a library from the running JVM's own bin folder. It stays loaded for the life of the JVM. Do not alter
// the process-wide DLL search path or load a DLL from our own Java distribution.
static HMODULE LoadFromJvm(const wchar_t* name) {
    HMODULE loaded = GetModuleHandleW(name);
    if (loaded != nullptr) return loaded;
    std::wstring directory = JvmBinDirectory();
    if (directory.empty()) return nullptr;
    return LoadLibraryExW((directory + L"\\" + name).c_str(), nullptr,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
}

// A standard JVMTI agent, not remote-thread injection. Some embedded JVM launchers
// do not load jli.dll or place the JRE bin directory on the DLL search path.
// Load only that dependency from the already-running JVM's own installation.
extern "C" JNIEXPORT jint JNICALL Agent_OnAttach(JavaVM*, char*, void*) {
    return LoadFromJvm(L"jli.dll") != nullptr ? JNI_OK : JNI_ERR;
}

// The startup loader's native method (StartupLoader.load, below), called on the game's main thread as the
// game starts. It does in-process what an attach does: the JRE's own instrument library loads the agent jar named
// in the options ("<jar>=<agent options>") and calls its agentmain with an Instrumentation. Returns that library's
// result (0 when the agent loaded), or a negative number when the library could not be reached.
static jint Attach(JNIEnv* env, jstring options) {
    if (options == nullptr) return -1;
    if (LoadFromJvm(L"jli.dll") == nullptr) return -2;
    HMODULE instrument = LoadFromJvm(L"instrument.dll");
    if (instrument == nullptr) return -3;
    using AgentOnAttach = jint(JNICALL*)(JavaVM*, char*, void*);
    auto attach = reinterpret_cast<AgentOnAttach>(GetProcAddress(instrument, "Agent_OnAttach"));
    if (attach == nullptr) return -4;
    JavaVM* vm = nullptr;
    if (env->GetJavaVM(&vm) != JNI_OK) return -5;
    const char* text = env->GetStringUTFChars(options, nullptr);
    if (text == nullptr) return -6;
    std::string copy(text);
    env->ReleaseStringUTFChars(options, text);
    return attach(vm, copy.data(), nullptr);
}

// The loader is the one in pztools/pztools-launch.jar (docs/design/startup-loader.md), whether the launcher file's class path
// lists the jar or the frozen shim in the game's folder loaded it: pztools.launch.StartupLoader, in whichever class loader
// defined it, calls this.
extern "C" JNIEXPORT jint JNICALL Java_pztools_launch_StartupLoader_load(JNIEnv* env, jclass, jstring options) {
    return Attach(env, options);
}
