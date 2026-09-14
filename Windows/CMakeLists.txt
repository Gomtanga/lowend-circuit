cmake_minimum_required(VERSION 3.16)
project(LowEndCircuitWindows VERSION 0.1.0 LANGUAGES CXX C)

# ─── Windows-only build ───────────────────────────────────────────────
# Source/Core is the portable, platform-independent DSP library. This project
# adds the Windows audio engine (WASAPI) plus the CLI and GUI front ends on top
# of it. The DSP is never re-implemented here, and the engine never depends on a
# UI: both front ends link the same lowend_engine target.
if(NOT WIN32)
    message(FATAL_ERROR
        "Windows/ builds only on Windows. Build Source/Core for portable DSP.")
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

option(LOWEND_WINDOWS_BUILD_GUI "Build the Windows GUI front end" ON)

# ─── Portable core (authoritative DSP) ────────────────────────────────
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../Source/Core" "${CMAKE_CURRENT_BINARY_DIR}/core")

# ─── Audio engine (no UI dependency) ──────────────────────────────────
# The engine, device layer, DSP stage and offline checks live in a static
# library so a front end adds only its own entry point. Nothing here references
# a window, a control, or an event loop, which is what keeps the DSP and the
# audio engine independent of the UI.
add_library(lowend_engine STATIC
    Source/AudioEngine/Settings.cpp
    Source/AudioEngine/DspStage.cpp
    Source/AudioEngine/WasapiDevices.cpp
    Source/AudioEngine/Engine.cpp
    Source/AudioEngine/SelfTest.cpp
)

target_include_directories(lowend_engine PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/Source"
)

target_link_libraries(lowend_engine PUBLIC
    lowend_core
    lowend_ring_buffer
    ole32
    uuid
    avrt
    propsys
)

target_compile_definitions(lowend_engine PUBLIC
    UNICODE
    _UNICODE
    WIN32_LEAN_AND_MEAN
    NOMINMAX
)

if(MSVC)
    target_compile_options(lowend_engine PRIVATE /W4 /permissive- /utf-8)
endif()

# ─── CLI front end ────────────────────────────────────────────────────
add_executable(lowend_windows
    Source/CLI/Main.cpp
    Source/CLI/CommandLine.cpp
)

target_link_libraries(lowend_windows PRIVATE lowend_engine)

if(MSVC)
    target_compile_options(lowend_windows PRIVATE /W4 /permissive- /utf-8)
endif()

# ─── GUI front end ────────────────────────────────────────────────────
# A thin window over the same engine: it reads and writes Settings, calls
# Engine::start/stop/requestSettings/stats, and nothing else. No DSP code and no
# device code lives in this target.
if(LOWEND_WINDOWS_BUILD_GUI)
    add_executable(lowend_gui WIN32
        Source/GUI/Main.cpp
        Source/GUI/MainWindow.cpp
        Source/GUI/ControlPanel.cpp
    )

    target_link_libraries(lowend_gui PRIVATE
        lowend_engine
        comctl32
        gdi32
        user32
    )

    if(MSVC)
        target_compile_options(lowend_gui PRIVATE /W4 /permissive- /utf-8)
    endif()
endif()

# ─── Offline checks (no audio device required) ────────────────────────
# The CLI's --self-test runs the same checks a user can run locally, so the CI
# job and the shipped binary agree on what was verified.
option(LOWEND_WINDOWS_BUILD_TESTING "Register Windows ctest targets" OFF)

if(LOWEND_WINDOWS_BUILD_TESTING)
    enable_testing()
    add_test(NAME lowend_windows_self_test COMMAND lowend_windows --self-test)
    set_tests_properties(lowend_windows_self_test PROPERTIES TIMEOUT 120)
endif()
