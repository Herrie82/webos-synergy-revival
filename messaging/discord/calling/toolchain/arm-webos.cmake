# arm-webos.cmake — CMake toolchain for cross-compiling libdave / mlspp / the DAVE
# probe for the HP TouchPad (webOS 3.0.5, ARMv7 Cortex-A8, glibc, softfp).
#
# Reproduces the GREEN libdave-spike cross build. Copied from the session scratchpad
# spike (libdave-spike/arm-toolchain.cmake) and made repo-relative where possible.
#
# Override the two absolute paths below via -D or environment if your layout differs:
#   TC   = crosstool-NG GCC 12.5 toolchain root
#   OSSL = cross-built OpenSSL 1.1.1w (matches the device rootfs)
#
# Usage:
#   cmake -DCMAKE_TOOLCHAIN_FILE=.../arm-webos.cmake ...

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)

# --- crosstool-NG GCC 12.5 (proven green; GCC 9.3 slot also present) ------------
if(NOT DEFINED TC)
  if(DEFINED ENV{ARM_TC})
    set(TC $ENV{ARM_TC})
  else()
    set(TC /home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125)
  endif()
endif()

set(CMAKE_C_COMPILER   ${TC}/bin/arm-unknown-linux-gnueabi-gcc)
set(CMAKE_CXX_COMPILER ${TC}/bin/arm-unknown-linux-gnueabi-g++)
set(CMAKE_SYSROOT      ${TC}/arm-unknown-linux-gnueabi/sysroot)

# --- Cross OpenSSL 1.1.1w (user's rootfs build) ---------------------------------
if(NOT DEFINED OSSL)
  if(DEFINED ENV{ARM_OSSL})
    set(OSSL $ENV{ARM_OSSL})
  else()
    set(OSSL /home/herrie/webos/touchpad-kernel/doctor305/OpenSSL-11-Update/openssl-1.1.1w)
  endif()
endif()

set(CMAKE_FIND_ROOT_PATH "${CMAKE_SYSROOT};${OSSL}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)

# ARMv7 Cortex-A8 NEON softfp. The two -Wno-* flags suppress GCC 12.5 FALSE-POSITIVE
# -Warray-bounds / -Wstringop-overflow diagnostics in mlspp's std::vector inlining.
# NOTE: libdave's CMakeLists only adds -Werror for Clang/MSVC, NOT for GNU, so no
# source patch is required — these -Wno flags are belt-and-suspenders for the GNU path.
set(_arch "-march=armv7-a -mtune=cortex-a8 -mfpu=neon -mfloat-abi=softfp -Wno-array-bounds -Wno-stringop-overflow")
set(CMAKE_C_FLAGS   "${_arch}" CACHE STRING "")
set(CMAKE_CXX_FLAGS "${_arch}" CACHE STRING "")

# Point find_package(OpenSSL) at the cross 1.1.1w build
set(OPENSSL_ROOT_DIR      ${OSSL})
set(OPENSSL_INCLUDE_DIR   ${OSSL}/include)
set(OPENSSL_CRYPTO_LIBRARY ${OSSL}/libcrypto.so)
set(OPENSSL_SSL_LIBRARY    ${OSSL}/libssl.so)
