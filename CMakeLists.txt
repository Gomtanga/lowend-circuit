cmake_minimum_required(VERSION 3.22)

project(LowEndCircuit VERSION 0.1.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)

set(JUCE_GIT_TAG 8.0.13 CACHE STRING "JUCE git tag to use")
FetchContent_Declare(
    JUCE
    GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
    GIT_TAG ${JUCE_GIT_TAG}
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(JUCE)

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

# ─── Shared DSP Core ──────────────────────────────────────
add_subdirectory(Source/Core)

target_sources(LowEndCircuit
    PRIVATE
        Source/PluginEditor.cpp
        Source/PluginProcessor.cpp
)

target_compile_definitions(LowEndCircuit
    PUBLIC
        JUCE_WEB_BROWSER=0
        JUCE_USE_CURL=0
        JUCE_VST3_CAN_REPLACE_VST2=0
)

target_link_libraries(LowEndCircuit
    PRIVATE
        juce::juce_audio_utils
        juce::juce_dsp
        lowend_core
    PUBLIC
        juce::juce_recommended_config_flags
        juce::juce_recommended_lto_flags
        juce::juce_recommended_warning_flags
)
