cmake_minimum_required(VERSION 3.22)
project(dsh_proot_candidate C ASM)

# Deliberately separate from app/src/main/cpp: this is a reviewed build
# candidate, not an APK payload or an execution permission.
if(NOT ANDROID OR NOT ANDROID_ABI STREQUAL "arm64-v8a")
  message(FATAL_ERROR "The candidate is limited to Android arm64-v8a")
endif()
foreach(name PROOT_SOURCE TALLOC_SOURCE SHMEM_SOURCE)
  if(NOT IS_DIRECTORY "${${name}}")
    message(FATAL_ERROR "${name} must point to a verified extracted source tree")
  endif()
endforeach()

set(PROOT_SRC "${PROOT_SOURCE}/src")
file(GLOB_RECURSE PROOT_C CONFIGURE_DEPENDS "${PROOT_SRC}/*.c")
list(FILTER PROOT_C EXCLUDE REGEX "/loader/")
list(FILTER PROOT_C EXCLUDE REGEX "/\\.check_")
list(FILTER PROOT_C EXCLUDE REGEX "/loader-info\\.c$")
# Upstream omits <string.h> in this translation unit; Clang 19 rejects its
# implicit strcmp/memset declarations. Keep the source archive unchanged.
set_source_files_properties("${PROOT_SRC}/extension/ashmem_memfd/ashmem_memfd.c"
  PROPERTIES COMPILE_OPTIONS "-include;string.h")

file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/build.h"
  "#ifndef BUILD_H\n#define BUILD_H\n#define VERSION \"5.1.107.96\"\n#define HAVE_PROCESS_VM 1\n#define HAVE_SECCOMP_FILTER 1\n#endif\n")

add_library(talloc_candidate STATIC "${TALLOC_SOURCE}/talloc.c")
target_include_directories(talloc_candidate PRIVATE "${TALLOC_SOURCE}"
  "${TALLOC_SOURCE}/lib/replace" "${CMAKE_CURRENT_BINARY_DIR}")
target_compile_definitions(talloc_candidate PRIVATE
  TALLOC_BUILD_VERSION_MAJOR=2 TALLOC_BUILD_VERSION_MINOR=4
  TALLOC_BUILD_VERSION_RELEASE=3 NO_CONFIG_H __STDC_WANT_LIB_EXT1__=1
  HAVE_STDBOOL_H HAVE_BOOL HAVE_INTPTR_T HAVE_UINTPTR_T HAVE_PTRDIFF_T
  HAVE_USLEEP HAVE_DLFCN_H HAVE_STRING_H HAVE_LIMITS_H HAVE_C99_VSNPRINTF HAVE_VSNPRINTF
  HAVE_MEMMOVE HAVE_STRNLEN)

# The source-locked Android shared-memory implementation is linked for candidate
# compilation only. Its keyed mode is disabled unless a future trusted launcher
# supplies an isolated-UID-owned 0700 directory and explicitly opts in.
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/include/sys")
configure_file("${SHMEM_SOURCE}/shm.h"
  "${CMAKE_CURRENT_BINARY_DIR}/include/sys/shm.h" COPYONLY)
add_library(android_shmem_candidate STATIC "${SHMEM_SOURCE}/shmem.c")
target_include_directories(android_shmem_candidate PRIVATE "${SHMEM_SOURCE}")
target_compile_options(android_shmem_candidate PRIVATE -Wall -Wextra)

# Name is only a candidate for nativeLibraryDir installation. It is never
# extracted into app home for execution (Android 10+ W^X).
add_executable(proot_candidate ${PROOT_C} "${CMAKE_CURRENT_SOURCE_DIR}/dsh-trace-events.c")
set_target_properties(proot_candidate PROPERTIES OUTPUT_NAME "libdsh_proot_candidate.so")
target_include_directories(proot_candidate PRIVATE "${PROOT_SRC}" "${TALLOC_SOURCE}"
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_BINARY_DIR}")
target_include_directories(proot_candidate BEFORE PRIVATE
  "${CMAKE_CURRENT_BINARY_DIR}/include")
target_compile_definitions(proot_candidate PRIVATE _FILE_OFFSET_BITS=64 _GNU_SOURCE
  WITH_LIBANDROID_SHMEM=1 PROOT_UNBUNDLE_LOADER="/invalid-until-nativeLibraryDir-resolved")
target_compile_options(proot_candidate PRIVATE -Wall -Wextra)
target_link_options(proot_candidate PRIVATE -Wl,-z,noexecstack)
target_link_libraries(proot_candidate PRIVATE talloc_candidate android_shmem_candidate android log)

add_executable(proot_loader_candidate "${PROOT_SRC}/loader/loader.c"
  "${PROOT_SRC}/loader/assembly.S")
set_target_properties(proot_loader_candidate PROPERTIES OUTPUT_NAME "libdsh_proot_loader_candidate.so")
target_include_directories(proot_loader_candidate PRIVATE "${PROOT_SRC}")
target_compile_options(proot_loader_candidate PRIVATE -fPIC -ffreestanding)
target_link_options(proot_loader_candidate PRIVATE -static -nostdlib
  # LLD on Windows cannot materialize the sparse ELF made by -Ttext at 128 GiB.
  # --image-base preserves the fixed virtual address with compact file offsets.
  -Wl,--image-base=0x2000000000,-z,noexecstack)

find_program(POWERSHELL_EXE NAMES pwsh powershell REQUIRED)
get_filename_component(NDK_BIN "${CMAKE_C_COMPILER}" DIRECTORY)
set(LOADER_INFO "${CMAKE_CURRENT_BINARY_DIR}/loader-info.c")
add_custom_command(OUTPUT "${LOADER_INFO}"
  COMMAND "${POWERSHELL_EXE}" -NoProfile -File
    "${CMAKE_CURRENT_SOURCE_DIR}/generate-loader-info.ps1"
    -ReadelfPath "${NDK_BIN}/llvm-readelf.exe"
    -LoaderPath "$<TARGET_FILE:proot_loader_candidate>"
    -OutputPath "${LOADER_INFO}"
  DEPENDS proot_loader_candidate "${CMAKE_CURRENT_SOURCE_DIR}/generate-loader-info.ps1"
  VERBATIM)
target_sources(proot_candidate PRIVATE "${LOADER_INFO}")
