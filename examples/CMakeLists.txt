# Builds the C and C++ examples against the static library.
#
#   cmake -S examples -B build/examples -DCMAKE_BUILD_TYPE=Release
#   cmake --build build/examples --config Release
#
# Cargo builds the library first (license-worker-client-capi, release, static).
# -DLW_KEYRING=ON builds it with the keyring feature.
# On macOS, -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" builds a universal library
# (both Rust targets, joined with lipo); the deployment target is passed to cargo.
cmake_minimum_required(VERSION 3.16)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0" CACHE STRING "Oldest macOS the plugin supports (older needs an older SDK)")
project(license_worker_examples C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(LW_KEYRING "Build the library with the keyring feature" OFF)
# Plugins usually link the static CRT (/MT): build Rust the same way, or the link fails on a CRT mismatch.
option(LW_MSVC_STATIC_CRT "MSVC: link the static C runtime (/MT), in Rust too" OFF)
if(MSVC AND LW_MSVC_STATIC_CRT)
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
  set(LW_ENV ${CMAKE_COMMAND} -E env "RUSTFLAGS=-C target-feature=+crt-static")
endif()
set(LW_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/..")
set(LW_TARGET_DIR "${CMAKE_CURRENT_BINARY_DIR}/cargo")
set(LW_CARGO_ARGS build --release -p license-worker-client-capi --target-dir "${LW_TARGET_DIR}")
if(LW_KEYRING)
  list(APPEND LW_CARGO_ARGS --features keyring)
endif()
if(LW_RUST_TARGET)
  list(APPEND LW_CARGO_ARGS --target ${LW_RUST_TARGET})
  set(LW_LIB_DIR "${LW_TARGET_DIR}/${LW_RUST_TARGET}/release")
else()
  set(LW_LIB_DIR "${LW_TARGET_DIR}/release")
endif()

if(MSVC)
  set(LW_STATIC "${LW_LIB_DIR}/license_worker.lib")
  # What `cargo rustc --print native-static-libs` lists, with the system libraries
  # keyring's Credential Manager calls need in place of windows-targets' import lib.
  set(LW_SYSTEM_LIBS kernel32 ntdll userenv ws2_32 dbghelp synchronization advapi32 secur32 crypt32 bcrypt ncrypt)
else()
  set(LW_STATIC "${LW_LIB_DIR}/liblicense_worker.a")
  if(APPLE)
    set(LW_SYSTEM_LIBS "-framework Security" "-framework CoreFoundation" iconv m)
  else()
    set(LW_SYSTEM_LIBS pthread dl m)
    if(LW_KEYRING)
      find_package(PkgConfig REQUIRED)
      pkg_check_modules(DBUS REQUIRED dbus-1)
      list(APPEND LW_SYSTEM_LIBS ${DBUS_LINK_LIBRARIES})
    endif()
  endif()
endif()

if(APPLE)
  set(LW_ENV ${CMAKE_COMMAND} -E env MACOSX_DEPLOYMENT_TARGET=${CMAKE_OSX_DEPLOYMENT_TARGET})
  list(LENGTH CMAKE_OSX_ARCHITECTURES LW_ARCH_COUNT)
endif()
if(APPLE AND LW_ARCH_COUNT GREATER 1)
  # Universal: one cargo build per architecture, then lipo.
  set(LW_STATIC "${LW_TARGET_DIR}/universal/liblicense_worker.a")
  set(LW_SLICES)
  set(LW_COMMANDS)
  foreach(arch IN LISTS CMAKE_OSX_ARCHITECTURES)
    if(arch STREQUAL "arm64")
      set(triple aarch64-apple-darwin)
    else()
      set(triple ${arch}-apple-darwin)
    endif()
    list(APPEND LW_COMMANDS COMMAND ${LW_ENV} cargo ${LW_CARGO_ARGS} --target ${triple})
    list(APPEND LW_SLICES "${LW_TARGET_DIR}/${triple}/release/liblicense_worker.a")
  endforeach()
  add_custom_command(
    OUTPUT "${LW_STATIC}"
    ${LW_COMMANDS}
    COMMAND ${CMAKE_COMMAND} -E make_directory "${LW_TARGET_DIR}/universal"
    COMMAND lipo -create ${LW_SLICES} -output "${LW_STATIC}"
    WORKING_DIRECTORY "${LW_ROOT}"
    COMMENT "cargo: building the universal license_worker static library"
    USES_TERMINAL VERBATIM)
else()
  add_custom_command(
    OUTPUT "${LW_STATIC}"
    COMMAND ${LW_ENV} cargo ${LW_CARGO_ARGS}
    WORKING_DIRECTORY "${LW_ROOT}"
    COMMENT "cargo: building the license_worker static library"
    USES_TERMINAL VERBATIM)
endif()
add_custom_target(license_worker_cargo DEPENDS "${LW_STATIC}")

add_library(license_worker STATIC IMPORTED GLOBAL)
set_target_properties(license_worker PROPERTIES
  IMPORTED_LOCATION "${LW_STATIC}"
  INTERFACE_INCLUDE_DIRECTORIES "${LW_ROOT}/capi/include"
  INTERFACE_LINK_LIBRARIES "${LW_SYSTEM_LIBS}")
add_dependencies(license_worker license_worker_cargo)

add_executable(lw_cli c/lw_cli.c)
target_link_libraries(lw_cli PRIVATE license_worker)
add_dependencies(lw_cli license_worker_cargo)

add_executable(plugin_licence cpp/plugin_licence.cpp)
target_link_libraries(plugin_licence PRIVATE license_worker)
add_dependencies(plugin_licence license_worker_cargo)

if(MSVC)
  # strdup is POSIX; MSVC warns.
  target_compile_definitions(lw_cli PRIVATE _CRT_NONSTDC_NO_WARNINGS _CRT_SECURE_NO_WARNINGS)
endif()
