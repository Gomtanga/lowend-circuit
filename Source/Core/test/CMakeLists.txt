set(TEST_SOURCES
    test_biquad.cpp
    test_precompute.cpp
    test_circuit_bass.cpp
    test_high_exciter.cpp
    test_processor.cpp
    test_spatial_geometry.cpp
    test_precise_biquad.cpp
    test_tonal_measurements.cpp
)

foreach(TEST_SRC ${TEST_SOURCES})
    get_filename_component(TEST_NAME ${TEST_SRC} NAME_WE)

    add_executable(${TEST_NAME} ${TEST_SRC})
    target_link_libraries(${TEST_NAME} PRIVATE lowend_core)

    # Make sure the test can find Core.h + AudioRingBufferC.h
    target_include_directories(${TEST_NAME} PRIVATE
        $<BUILD_INTERFACE:${CMAKE_SOURCE_DIR}/include>
    )

    add_test(NAME ${TEST_NAME} COMMAND ${TEST_NAME})
endforeach()

# Compile the implementation as C11 (not C++) while the concurrency harness
# uses C++17 threads. This keeps the atomic ABI identical to SwiftPM's target.
find_package(Threads REQUIRED)
add_executable(test_audio_ring_buffer
    "${CMAKE_CURRENT_LIST_DIR}/../../../SystemAudioProcessor/Tests/AudioRingBufferChecks/main.cpp"
    "${CMAKE_CURRENT_LIST_DIR}/../../../SystemAudioProcessor/Sources/AudioRingBufferC/AudioRingBufferC.c"
)
target_include_directories(test_audio_ring_buffer PRIVATE "${AUDIO_RING_BUFFER_INCLUDE}")
target_compile_features(test_audio_ring_buffer PRIVATE c_std_11 cxx_std_17)
target_link_libraries(test_audio_ring_buffer PRIVATE Threads::Threads)
if(UNIX AND NOT APPLE)
    target_link_libraries(test_audio_ring_buffer PRIVATE m)
endif()
add_test(NAME test_audio_ring_buffer COMMAND test_audio_ring_buffer)
set_tests_properties(test_audio_ring_buffer PROPERTIES TIMEOUT 45)
