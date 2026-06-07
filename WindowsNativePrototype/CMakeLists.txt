cmake_minimum_required(VERSION 3.16)
project(LowEndWinPrototype VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ─── Shared Core DSP library ──────────────────────────────────
# Source/Core/ provides Biquad, OnePole, CircuitBass, HighExciter, DSPPrecompute.
# Built as a static library (lowend_core) and linked below.
get_filename_component(CORE_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../Source/Core" ABSOLUTE)
get_filename_component(AUDIO_RING_BUFFER_INCLUDE
    "${CMAKE_CURRENT_SOURCE_DIR}/../SystemAudioProcessor/Sources/AudioRingBufferC/include"
    ABSOLUTE)

# ─── Platform-specific target ─────────────────────────────────
if(WIN32)
    add_subdirectory(${CORE_DIR} build/lowend_core)
    # lowend_core target is now available

    add_executable(LowEndWinPrototype
        main.cpp
        WasapiLoopbackCapture.h
        WasapiLoopbackCapture.cpp
        WasapiPlayback.h
        WasapiPlayback.cpp
    )

    target_link_libraries(LowEndWinPrototype PRIVATE
        lowend_core
        ole32.lib
        avrt.lib
    )

    target_include_directories(LowEndWinPrototype PRIVATE
        ${CORE_DIR}/include
        ${AUDIO_RING_BUFFER_INCLUDE}
    )

    target_compile_definitions(LowEndWinPrototype PRIVATE
        _CRT_SECURE_NO_WARNINGS
    )

    set_target_properties(LowEndWinPrototype PROPERTIES
        WIN32_EXECUTABLE FALSE   # console app, not GUI
    )

    message(STATUS "LowEndWinPrototype: Windows build configured (Core linked)")

elseif(APPLE)
    # macOS stub
    add_custom_target(LowEndWinPrototype
        COMMAND ${CMAKE_COMMAND} -E echo
            "LowEndWinPrototype is a Windows-only project. Build on Windows with MSVC."
    )
    message(STATUS "LowEndWinPrototype: macOS — stub only")

else()
    add_custom_target(LowEndWinPrototype
        COMMAND ${CMAKE_COMMAND} -E echo
            "LowEndWinPrototype requires Windows."
    )
endif()
