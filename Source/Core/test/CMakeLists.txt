set(TEST_SOURCES
    test_biquad.cpp
    test_precompute.cpp
    test_circuit_bass.cpp
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
