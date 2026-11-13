cmake_minimum_required(VERSION 3.13)
project(omnicore_source)

file(GLOB SRC "src/*.cpp")

include(${SDRPP_MODULE_CMAKE})

# OmniCore Host (OCH), the OmniCore SDR's own driver library, is built here from its source
# (the omnicore-host git submodule, pinned to a release) so that every package carries a matching copy.
set(OMNICORE_HOST_DIR "${CMAKE_CURRENT_SOURCE_DIR}/omnicore-host" CACHE PATH "OmniCore Host source tree")
if (NOT EXISTS "${OMNICORE_HOST_DIR}/include/omnicore/och.h")
    message(FATAL_ERROR "OmniCore Host source not found in ${OMNICORE_HOST_DIR}: run 'git submodule update --init'")
endif ()

set(_och "${OMNICORE_HOST_DIR}")
if (ANDROID)
    # Android hands the app a permission-granted USB file descriptor instead of a device path.
    # Patch a build-local copy; the submodule stays untouched.
    set(_och "${CMAKE_CURRENT_BINARY_DIR}/omnicore-host-android")
    file(REMOVE_RECURSE "${_och}")
    file(COPY "${OMNICORE_HOST_DIR}/src" "${OMNICORE_HOST_DIR}/include" DESTINATION "${_och}")
    foreach (_file src/capi/device.cpp src/transport/posix/libusb_link.cpp)
        file(READ "${_och}/${_file}" _text)
        string(REPLACE "\r\n" "\n" _text "${_text}")
        file(WRITE "${_och}/${_file}" "${_text}")
    endforeach ()
    find_program(PATCH_EXECUTABLE patch REQUIRED)
    execute_process(COMMAND "${PATCH_EXECUTABLE}" --batch -p1 -i "${CMAKE_CURRENT_SOURCE_DIR}/android/omnicore-host-android.patch"
        WORKING_DIRECTORY "${_och}" RESULT_VARIABLE _och_patch_result)
    if (NOT _och_patch_result EQUAL 0)
        message(FATAL_ERROR "OmniCore Host Android patch failed")
    endif ()
endif ()

add_library(omnicore SHARED
    ${_och}/src/capi/device.cpp ${_och}/src/capi/stream.cpp ${_och}/src/capi/rf.cpp
    ${_och}/src/capi/board.cpp ${_och}/src/capi/firmware.cpp ${_och}/src/capi/timebase.cpp ${_och}/src/capi/sync.cpp
    ${_och}/src/core/device.cpp ${_och}/src/core/control.cpp ${_och}/src/core/configuration.cpp
    ${_och}/src/core/reconfigure.cpp ${_och}/src/core/stream.cpp ${_och}/src/core/stream_io.cpp
    ${_och}/src/core/rf.cpp ${_och}/src/core/power.cpp ${_och}/src/core/board.cpp
    ${_och}/src/core/firmware.cpp ${_och}/src/core/timebase.cpp ${_och}/src/core/sync.cpp
    ${_och}/src/dsp/codec.cpp ${_och}/src/protocol/frame.cpp)
if (WIN32)
    target_sources(omnicore PRIVATE ${_och}/src/transport/win/libusbk_link.cpp)
else ()
    target_sources(omnicore PRIVATE ${_och}/src/transport/posix/libusb_link.cpp)
endif ()
target_include_directories(omnicore PUBLIC "${_och}/include" PRIVATE "${_och}/src")
target_compile_definitions(omnicore PRIVATE OCH_BUILD)
set_target_properties(omnicore PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
find_package(Threads REQUIRED)
target_link_libraries(omnicore PRIVATE Threads::Threads)

if (WIN32)
    # libusbK.dll (loaded at run time) is the user-mode half of the libusbK driver the radio uses on Windows
    target_compile_definitions(omnicore PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)
    target_link_libraries(omnicore PRIVATE setupapi ole32 advapi32)
    set_target_properties(omnicore PROPERTIES PREFIX "")
    if (MINGW)
        target_link_options(omnicore PRIVATE -static -static-libgcc -static-libstdc++)
    endif ()
    # Not in git (a download of github.com/mcuee/libusbk V3.1.0.0, see omnicore-host/third_party/driver/SOURCES.json)
    set(OMNICORE_LIBUSBK_DLL "${OMNICORE_HOST_DIR}/third_party/driver/libusbK-3.1.0.0/libusbK-3.1.0.0-bin/bin/dll/amd64/libusbK.dll"
        CACHE FILEPATH "libusbK.dll (amd64) to ship next to omnicore.dll")
    # Windows looks for a module's DLLs next to sdrpp.exe: install them there, and copy them there in the build tree
    add_custom_command(TARGET omnicore POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different "$<TARGET_FILE:omnicore>" "${CMAKE_BINARY_DIR}/$<TARGET_FILE_NAME:omnicore>")
    install(TARGETS omnicore RUNTIME DESTINATION .)
    if (EXISTS "${OMNICORE_LIBUSBK_DLL}")
        add_custom_command(TARGET omnicore POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different "${OMNICORE_LIBUSBK_DLL}" "${CMAKE_BINARY_DIR}/libusbK.dll")
        install(FILES "${OMNICORE_LIBUSBK_DLL}" DESTINATION .)
    else ()
        message(WARNING "libusbK.dll not found (OMNICORE_LIBUSBK_DLL): the OmniCore source then needs the one the libusbK driver installs")
    endif ()
elseif (ANDROID)
    set_target_properties(omnicore PROPERTIES CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN YES)
    target_link_libraries(omnicore PRIVATE ${SDR_KIT_ROOT}/${ANDROID_ABI}/lib/libusb1.0.so log)
    target_include_directories(omnicore PRIVATE ${SDR_KIT_ROOT}/${ANDROID_ABI}/include)
else ()
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(OCH_LIBUSB REQUIRED IMPORTED_TARGET libusb-1.0>=1.0.21)
    target_link_libraries(omnicore PRIVATE PkgConfig::OCH_LIBUSB)
    set_target_properties(omnicore PROPERTIES CXX_VISIBILITY_PRESET hidden VISIBILITY_INLINES_HIDDEN YES
        VERSION 0.8.0 SOVERSION 1)
    install(TARGETS omnicore LIBRARY DESTINATION lib)
    if (APPLE)
        target_link_libraries(omnicore PRIVATE "-framework IOKit" "-framework CoreFoundation")
    endif ()
    if (${CMAKE_SYSTEM_NAME} MATCHES "Linux")
        # USB access for normal users
        install(FILES "${OMNICORE_HOST_DIR}/packaging/linux/60-omnicore.rules" DESTINATION lib/udev/rules.d)
    endif ()
endif ()

target_link_libraries(omnicore_source PRIVATE omnicore)
