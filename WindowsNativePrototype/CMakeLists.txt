cmake_minimum_required(VERSION 3.16)
project(LowEndWinPrototype VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ─── Shared Core DSP library ──────────────────────────────────
# Core.h + Core.cpp + CircuitBass provide the cross-platform DSP.
# 참조: Source/Core/ (spike/cross-platform-core)
#
# WindowsNativePrototype is a standalone CMake project that can also
# be built via add_subdirectory from the root CMakeLists.txt.

# ─── Platform-specific target ─────────────────────────────────
if(WIN32)
    add_executable(LowEndWinPrototype
        main.cpp
    )

    target_link_libraries(LowEndWinPrototype PRIVATE
        ole32.lib
        avrt.lib
    )

    target_compile_definitions(LowEndWinPrototype PRIVATE
        _CRT_SECURE_NO_WARNINGS
    )

    # WASAPI headers are part of the Windows SDK — no extra include paths needed.
    # Key headers used later:
    #   <windows.h>
    #   <mmdeviceapi.h>
    #   <audioclient.h>
    #   <functiondiscoverykeys_devpkey.h>

    set_target_properties(LowEndWinPrototype PROPERTIES
        WIN32_EXECUTABLE FALSE   # console app, not GUI
    )

    message(STATUS "LowEndWinPrototype: Windows build configured")

elseif(APPLE)
    # macOS stub — Silly message to let the user know this only builds on Windows.
    add_custom_target(LowEndWinPrototype
        COMMAND ${CMAKE_COMMAND} -E echo
            "LowEndWinPrototype is a Windows-only project. Build on Windows with MSVC."
    )

    message(STATUS "LowEndWinPrototype: macOS — stub only (not a real target)")

else()
    add_custom_target(LowEndWinPrototype
        COMMAND ${CMAKE_COMMAND} -E echo
            "LowEndWinPrototype requires Windows. Build with Visual Studio 2022."
    )

endif()
