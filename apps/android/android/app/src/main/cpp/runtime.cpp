#include <jni.h>
#include <node.h>
#include <unistd.h>
#include <sys/socket.h>
#include <atomic>
#include <cstdlib>
#include <cstdio>
#include <string>
#include <vector>

namespace {
std::atomic<bool> started{false};
std::string utf8(JNIEnv* env, jstring value) {
  const char* chars = env->GetStringUTFChars(value, nullptr);
  std::string result(chars);
  env->ReleaseStringUTFChars(value, chars);
  return result;
}
}

extern "C" JNIEXPORT jintArray JNICALL
Java_com_minnnng_dsh_1android_NativeRuntime_socketPair(JNIEnv* env, jobject) {
  int descriptors[2];
  if (socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, descriptors) != 0) return nullptr;
  jintArray result = env->NewIntArray(2);
  env->SetIntArrayRegion(result, 0, 2, descriptors);
  return result;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_minnnng_dsh_1android_NativeRuntime_start(
    JNIEnv* env, jobject, jstring runtime, jstring home, jstring cache,
    jstring libraries, jint descriptor) {
  if (started.exchange(true)) return 70;
  const std::string runtime_path = utf8(env, runtime);
  const std::string home_path = utf8(env, home);
  const std::string cache_path = utf8(env, cache);
  const std::string libraries_path = utf8(env, libraries);
  setenv("HOME", home_path.c_str(), 1);
  setenv("DSH_HOME", home_path.c_str(), 1);
  setenv("TMPDIR", cache_path.c_str(), 1);
  setenv("DSH_ANDROID_NATIVE_LIBRARY_DIR", libraries_path.c_str(), 1);
  setenv("NODE_COMPILE_CACHE", (cache_path + "/node-compile").c_str(), 1);
  setenv("NODE_COMPILE_CACHE_PORTABLE", "1", 1);
  const std::string workspace = home_path + "/workspace";
  if (chdir(workspace.c_str()) != 0) return 71;
  if (freopen((home_path + "/runtime-stderr.log").c_str(), "w", stderr) == nullptr) return 73;
  if (dup2(descriptor, STDIN_FILENO) < 0 || dup2(descriptor, STDOUT_FILENO) < 0) return 72;
  close(descriptor);
  std::vector<std::string> arguments{"node", "--max-old-space-size=384", runtime_path + "/bootstrap.mjs"};
  size_t size = 0;
  for (const auto& argument : arguments) size += argument.size() + 1;
  std::vector<char> storage(size);
  std::vector<char*> argv;
  size_t offset = 0;
  for (const auto& argument : arguments) {
    argv.push_back(storage.data() + offset);
    argument.copy(storage.data() + offset, argument.size());
    offset += argument.size() + 1;
  }
  return node::Start(static_cast<int>(argv.size()), argv.data());
}
