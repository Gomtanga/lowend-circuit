cmake_minimum_required(VERSION 3.16)
project(LowEndCore VERSION 0.1.0 LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ─── Find AudioRingBufferC include path ──────────────────────────────
# Core.h reuses the C ABI types from AudioRingBufferC.h.
# The header lives in SystemAudioProcessor/ — we reference it by relative
# path so Core/ can be built independently without moving files.
get_filename_component(AUDIO_RING_BUFFER_INCLUDE
    "${CMAKE_CURRENT_SOURCE_DIR}/../../SystemAudioProcessor/Sources/AudioRingBufferC/include"
    ABSOLUTE)

# ─── Core static library ────────────────────────────────────────────
add_library(lowend_core STATIC
    src/Core.cpp
    src/CircuitBass.cpp
)

target_include_directories(lowend_core
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<BUILD_INTERFACE:${AUDIO_RING_BUFFER_INCLUDE}>
)

target_compile_features(lowend_core PUBLIC cxx_std_17)

# ─── Tests (optional) ───────────────────────────────────────────────
option(BUILD_TESTING "Build Core tests" OFF)

if(BUILD_TESTING)
    enable_testing()
    add_subdirectory(test)
endif()
