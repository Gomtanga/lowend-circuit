cmake_minimum_required(VERSION 3.22)

project(LowEndCircuit VERSION 0.1.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)

# ── JUCE ──────────────────────────────────────────────────────────────────────
set(JUCE_GIT_TAG 8.0.13 CACHE STRING "JUCE git tag to use")
FetchContent_Declare(
    JUCE
    GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
    GIT_TAG ${JUCE_GIT_TAG}
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(JUCE)

# ── CLI11 ─────────────────────────────────────────────────────────────────────
set(CLI11_GIT_TAG v2.6.2 CACHE STRING "CLI11 git tag to use")
FetchContent_Declare(
    CLI11
    GIT_REPOSITORY https://github.com/CLIUtils/CLI11.git
    GIT_TAG ${CLI11_GIT_TAG}
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(CLI11)

# ── Portable shared DSP core ─────────────────────────────────────────────────
option(LOWEND_JUCE_SHARED_CORE "Use the portable Core Circuit path in JUCE" OFF)
add_subdirectory(Source/Core)

# ── Shared DSP core ───────────────────────────────────────────────────────────
add_library(lowend_dsp_core STATIC
    Source/DSP/LowEndDSPCore.cpp
)
target_include_directories(lowend_dsp_core PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/Source)
target_link_libraries(lowend_dsp_core
    PUBLIC
        juce::juce_dsp
)
target_compile_definitions(lowend_dsp_core
    PUBLIC
        JUCE_WEB_BROWSER=0
        JUCE_USE_CURL=0
        JUCE_VST3_CAN_REPLACE_VST2=0
)

# ── Plugin (VST3 / AU / Standalone) ──────────────────────────────────────────
set(LOWEND_FORMATS VST3 Standalone)
if(APPLE)
    list(APPEND LOWEND_FORMATS AU)
endif()

juce_add_plugin(LowEndCircuit
    COMPANY_NAME "Codex Audio Lab"
    BUNDLE_ID "com.codexaudiolab.lowendcircuit"
    PLUGIN_MANUFACTURER_CODE Cxal
    PLUGIN_CODE Lecn
    FORMATS ${LOWEND_FORMATS}
    PRODUCT_NAME "LowEnd Circuit"
    IS_SYNTH FALSE
    NEEDS_MIDI_INPUT FALSE
    NEEDS_MIDI_OUTPUT FALSE
    IS_MIDI_EFFECT FALSE
    COPY_PLUGIN_AFTER_BUILD TRUE
)

juce_generate_juce_header(LowEndCircuit)

target_sources(LowEndCircuit
    PRIVATE
        Source/PluginEditor.cpp
        Source/PluginProcessor.cpp
)

target_link_libraries(LowEndCircuit
    PRIVATE
        lowend_dsp_core
        lowend_core
        juce::juce_audio_utils
    PUBLIC
        juce::juce_recommended_config_flags
        juce::juce_recommended_lto_flags
        juce::juce_recommended_warning_flags
)

target_compile_definitions(LowEndCircuit
    PRIVATE
        LOWEND_JUCE_SHARED_CORE=$<BOOL:${LOWEND_JUCE_SHARED_CORE}>
)

# ── CLI ───────────────────────────────────────────────────────────────────────
juce_add_console_app(LowEndCircuitCLI
    COMPANY_NAME "Codex Audio Lab"
    BUNDLE_ID "com.codexaudiolab.lowendcircuit.cli"
    PRODUCT_NAME "lowend-circuit"
)

target_sources(LowEndCircuitCLI
    PRIVATE
        Source/CLI/Main.cpp
        Source/CLI/CLICommands.cpp
)

target_link_libraries(LowEndCircuitCLI
    PRIVATE
        lowend_dsp_core
        CLI11::CLI11
        juce::juce_audio_utils
    PUBLIC
        juce::juce_recommended_config_flags
        juce::juce_recommended_lto_flags
        juce::juce_recommended_warning_flags
)

target_compile_definitions(LowEndCircuitCLI
    PUBLIC
        JUCE_WEB_BROWSER=0
        JUCE_USE_CURL=0
        JUCE_VST3_CAN_REPLACE_VST2=0
)
