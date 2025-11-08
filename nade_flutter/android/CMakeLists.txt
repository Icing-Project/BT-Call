cmake_minimum_required(VERSION 3.10)
project(nade_android)

# Resolve path to libnadecore
get_filename_component(NATIVE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
set(NADECORE_DIR "${NATIVE_DIR}/native/libnadecore")

message(STATUS "Looking for libnadecore at: ${NADECORE_DIR}")

# Check if libnadecore exists
if(NOT EXISTS "${NADECORE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "libnadecore not found at ${NADECORE_DIR}")
endif()

# Add libnadecore as subdirectory
add_subdirectory(${NADECORE_DIR} ${CMAKE_CURRENT_BINARY_DIR}/nadecore)

# No additional Android-specific setup needed since libnadecore has JNI exports
