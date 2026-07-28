# Cross toolchain for boring-sys (BoringSSL) -> webOS 3.0.5 ARMv7 soft-float / glibc 2.23.
#
# boring-sys ships cmake/armv7-linux.cmake, which sets NO compiler ("rely on environment variables")
# and so lets cmake fall back to the HOST /usr/bin/cc -- which then rejects -mfloat-abi=soft and the
# whole CDSI/libsignal-net build dies at enable_language(). Point cmake at OUR cross gcc instead.
#
# Selected via TARGET_CMAKE_TOOLCHAIN_FILE in build-presage.sh: that form is honored BOTH by boring-sys
# (build/config.rs target_var -> early-returns from its own toolchain logic) AND by the cmake crate
# (getenv_target_os -> passes -DCMAKE_TOOLCHAIN_FILE). It is target-scoped, so host cmake builds are
# unaffected. The float ABI / -march come from the cmake crate's CMAKE_C_FLAGS (soft, matching the
# rest of libpresage.so -- soft and softfp are call-ABI compatible, which is why this plugin already
# loads into the softfp transport).
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)

set(_tc /home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125)
set(CMAKE_C_COMPILER   ${_tc}/bin/arm-unknown-linux-gnueabi-gcc)
set(CMAKE_CXX_COMPILER ${_tc}/bin/arm-unknown-linux-gnueabi-g++)
set(CMAKE_ASM_COMPILER ${_tc}/bin/arm-unknown-linux-gnueabi-gcc)
set(CMAKE_SYSROOT      ${_tc}/arm-unknown-linux-gnueabi/sysroot)

# Search the cross sysroot for headers/libs, but run host-native programs (protoc etc.).
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
