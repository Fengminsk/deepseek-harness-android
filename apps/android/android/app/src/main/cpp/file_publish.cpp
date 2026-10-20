#include <node_api.h>
#include <uv.h>
#include <cerrno>
#include <fcntl.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <string>

namespace {
bool read_path(napi_env env, napi_value value, std::string& path) {
  size_t length = 0;
  if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) return false;
  path.resize(length + 1);
  if (napi_get_value_string_utf8(env, value, path.data(), path.size(), &length) != napi_ok) return false;
  path.resize(length);
  return !path.empty() && path.find('\0') == std::string::npos;
}

napi_value rename_exclusive(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok) return nullptr;
  std::string source, target;
  if (argc != 2 || !read_path(env, args[0], source) || !read_path(env, args[1], target)) {
    napi_throw_type_error(env, "EINVAL", "Two non-empty filesystem paths are required.");
    return nullptr;
  }
  // Linux RENAME_NOREPLACE: no existence-check race and no overwriting a target.
  if (syscall(__NR_renameat2, AT_FDCWD, source.c_str(), AT_FDCWD, target.c_str(), 1U) != 0) {
    const int error = errno;
    napi_throw_error(env, uv_err_name(-error), uv_strerror(-error));
    return nullptr;
  }
  napi_value result;
  napi_get_undefined(env, &result);
  return result;
}

napi_value initialize(napi_env env, napi_value exports) {
  napi_value method;
  napi_create_function(env, "renameExclusive", NAPI_AUTO_LENGTH, rename_exclusive, nullptr, &method);
  napi_set_named_property(env, exports, "renameExclusive", method);
  return exports;
}
}

NAPI_MODULE(NODE_GYP_MODULE_NAME, initialize)
