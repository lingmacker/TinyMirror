cmake_minimum_required(VERSION 3.22)
project(mirrorcore C)

# The AirPlay core is built as a SHARED library, not linked into the app.
# Everything copyleft (UxPlay's lib/, playfair, libplist) lives here behind the
# small C ABI in include/mirror_bridge.h, so this component can be rebuilt from
# source and swapped without rebuilding the app. See licenses/NOTICE.md.
set(NO_MARCH_NATIVE ON)
add_definitions(-DUXPLAY_HAVE_APPLE_P2P)

# Required: the static sub-libraries get linked into a shared object.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(UXPLAY ${CMAKE_CURRENT_SOURCE_DIR}/../vendor/UxPlay)
get_filename_component(DEPS_PREFIX "${CMAKE_CURRENT_SOURCE_DIR}/build/deps/macos26" ABSOLUTE)
if(NOT EXISTS "${DEPS_PREFIX}/include/openssl/evp.h" OR
   NOT EXISTS "${DEPS_PREFIX}/include/plist/plist.h")
    message(FATAL_ERROR "Native dependencies are missing; run ./native/build.sh to rebuild them.")
endif()
# UxPlay overwrites PKG_CONFIG_PATH; give pkgconf the selected prefix explicitly.
set(PKG_CONFIG_ARGN "--with-path=${DEPS_PREFIX}/lib/pkgconfig" CACHE STRING "Local native dependencies" FORCE)
set(CMAKE_PREFIX_PATH "${DEPS_PREFIX};${CMAKE_PREFIX_PATH}")
set(LIBCRYPTO "${DEPS_PREFIX}/lib/libcrypto.a" CACHE FILEPATH "macOS 26 libcrypto" FORCE)
set(LIBPLIST "${DEPS_PREFIX}/lib/libplist-2.0.a" CACHE FILEPATH "macOS 26 libplist" FORCE)
# Refresh cached pkg-config results after dependency deletion or repository moves.
get_cmake_property(cached_variables CACHE_VARIABLES)
foreach(variable IN LISTS cached_variables)
    if(variable MATCHES "^(OPENSSL_|PLIST_|pkgcfg_lib_(OPENSSL|PLIST)|__pkg_config_(checked|arguments)_(OPENSSL|PLIST))")
        unset(${variable})
        unset(${variable} CACHE)
    endif()
endforeach()

add_subdirectory(${UXPLAY}/lib/dns_sd dns_sd)
add_subdirectory(${UXPLAY}/lib/llhttp llhttp)
add_subdirectory(${UXPLAY}/lib/playfair playfair)
add_subdirectory(${UXPLAY}/lib airplay)

add_library(mirrorcore SHARED mirror_bridge.c)
target_include_directories(mirrorcore PRIVATE
    ${UXPLAY}/lib
    ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(mirrorcore PRIVATE airplay)

# Only the mb_* bridge API is exported, keeping the boundary between this
# library and the application explicit.
set_target_properties(mirrorcore PROPERTIES
    OUTPUT_NAME MirrorCore
    MACOSX_RPATH ON
    INSTALL_NAME_DIR "@rpath"
    LINK_FLAGS "-Wl,-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/exported_symbols.txt")
