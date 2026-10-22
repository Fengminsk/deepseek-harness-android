cmake_minimum_required(VERSION 3.22.1)
project(dsh_android LANGUAGES C CXX)
get_filename_component(REPOSITORY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../.." ABSOLUTE)
set(NODE_ROOT "${REPOSITORY_ROOT}/.cache/android/nodejs-mobile-24.22.0-0")
if(NOT EXISTS "${NODE_ROOT}/include/node/node.h")
  message(FATAL_ERROR "Run apps/android/tool/prepare-native.ps1 before building")
endif()
add_library(node SHARED IMPORTED)
set_target_properties(node PROPERTIES IMPORTED_LOCATION "${NODE_ROOT}/bin/${ANDROID_ABI}/libnode.so")

# Package an executable in Android's extracted native library directory. The .so
# name is required by APK native packaging; add_executable still supplies the
# proper CRT entry point and ELF interpreter, unlike a shared library with main.
add_executable(pocket_node_cli node_cli.cpp)
set_target_properties(pocket_node_cli PROPERTIES
  PREFIX "lib"
  SUFFIX ".so"
  POSITION_INDEPENDENT_CODE TRUE
)
target_include_directories(pocket_node_cli PRIVATE "${NODE_ROOT}/include/node")
target_link_libraries(pocket_node_cli PRIVATE node)
# Android's toolchain omits CMake's normal RPATH flags. A linker response file
# also preserves the literal $ORIGIN across Windows Ninja/cmd and Unix shells.
set(NODE_CLI_LINKER_OPTIONS "${CMAKE_CURRENT_BINARY_DIR}/pocket_node_cli.rsp")
file(GENERATE OUTPUT "${NODE_CLI_LINKER_OPTIONS}" CONTENT "-rpath\n$ORIGIN\n")
set_property(TARGET pocket_node_cli APPEND PROPERTY LINK_DEPENDS "${NODE_CLI_LINKER_OPTIONS}")
target_link_options(pocket_node_cli PRIVATE
  "-pie"
  "-Wl,-z,max-page-size=16384"
  "-Wl,@${NODE_CLI_LINKER_OPTIONS}"
)

# A separate short-lived executable owns each PTY. Fork happens here before
# any Node or Android service threads exist, then the shell is exec'd at once.
add_executable(pocket_terminal_helper terminal_helper.cpp)
set_target_properties(pocket_terminal_helper PROPERTIES PREFIX "lib" SUFFIX ".so"
  POSITION_INDEPENDENT_CODE TRUE)
target_link_options(pocket_terminal_helper PRIVATE "-pie" "-Wl,-z,max-page-size=16384")

# One-shot shell commands use a distinct supervisor so PTY sessions and
# command execution retain their own I/O and exit-status contracts.
add_executable(pocket_shell_supervisor shell_supervisor.c)
set_target_properties(pocket_shell_supervisor PROPERTIES PREFIX "lib" SUFFIX ".so"
  POSITION_INDEPENDENT_CODE TRUE)
target_link_options(pocket_shell_supervisor PRIVATE "-pie" "-Wl,-z,max-page-size=16384")

add_library(dsh_runtime SHARED runtime.cpp)
target_include_directories(dsh_runtime PRIVATE "${NODE_ROOT}/include/node")
target_link_libraries(dsh_runtime node log)
target_link_options(dsh_runtime PRIVATE "-Wl,-z,max-page-size=16384")
add_library(dsh_system SHARED "${REPOSITORY_ROOT}/native/system/packages/entry/src/flock.c")
target_include_directories(dsh_system PRIVATE "${NODE_ROOT}/include/node")
target_compile_definitions(dsh_system PRIVATE NAPI_VERSION=8)
target_link_libraries(dsh_system node)
target_link_options(dsh_system PRIVATE "-Wl,-z,max-page-size=16384")
add_library(pocket_file_publish SHARED file_publish.cpp)
target_include_directories(pocket_file_publish PRIVATE "${NODE_ROOT}/include/node")
target_compile_definitions(pocket_file_publish PRIVATE NAPI_VERSION=8 NODE_GYP_MODULE_NAME=pocket_file_publish)
target_compile_options(pocket_file_publish PRIVATE -std=c++17)
target_link_libraries(pocket_file_publish node)
target_link_options(pocket_file_publish PRIVATE "-Wl,-z,max-page-size=16384")

# Build the same N-API backend selected by the upstream desktop dependency.
set(BUILTIN_ROOT "${REPOSITORY_ROOT}/.cache/references/require-builtin/packages/native")
set(NAPI_ROOT "${REPOSITORY_ROOT}/.cache/android/node-addon-api-8.9.0")
if(NOT EXISTS "${BUILTIN_ROOT}/src/node_api_addon.cc" OR NOT EXISTS "${NAPI_ROOT}/napi.h")
  message(FATAL_ERROR "Prepare the pinned require-builtin source and stage the runtime first")
endif()
file(GLOB_RECURSE BUILTIN_SOURCES CONFIGURE_DEPENDS "${BUILTIN_ROOT}/src/*.cc")
list(FILTER BUILTIN_SOURCES EXCLUDE REGEX "runtime_compat_nodeabi\\.cc$")
add_library(pocket_require_builtin SHARED ${BUILTIN_SOURCES})
target_include_directories(pocket_require_builtin PRIVATE "${NODE_ROOT}/include/node" "${NAPI_ROOT}")
target_compile_definitions(pocket_require_builtin PRIVATE NAPI_VERSION=9 NODE_ADDON_API_DISABLE_CPP_EXCEPTIONS NARB_BACKEND=1 NARB_PRODUCT=1 NODE_GYP_MODULE_NAME=require_builtin)
target_compile_options(pocket_require_builtin PRIVATE -std=c++17 -fno-exceptions -fvisibility=hidden)
target_link_libraries(pocket_require_builtin node dl)
target_link_options(pocket_require_builtin PRIVATE "-Wl,-z,max-page-size=16384")
