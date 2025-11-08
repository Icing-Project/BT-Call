cmake_minimum_required(VERSION 3.10)
project(nadecore C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 14)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Source files
set(NADE_SOURCES
    src/nade_core.c
    src/modem_fsk.c
    src/handshake.c
    src/codec.c
    src/fec.c
    src/crypto.c
)

# Platform-specific sources
if(ANDROID)
    list(APPEND NADE_SOURCES src/jni_exports.c)
endif()

# Include directories
include_directories(
    include
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

# TODO: Add third-party dependencies
# These should be fetched as git submodules or via FetchContent
# - noise-c: Noise protocol implementation
# - codec2: Voice codec
# - fec: Reed-Solomon FEC library

# For now, placeholder comments:
# add_subdirectory(third_party/noise-c)
# add_subdirectory(third_party/codec2)
# add_subdirectory(third_party/libfec)

# Build as shared library
if(ANDROID)
    add_library(nadecore SHARED ${NADE_SOURCES})
    
    # Link Android libraries
    find_library(log-lib log)
    target_link_libraries(nadecore ${log-lib} pthread)
    
    # TODO: Link third-party libs
    # target_link_libraries(nadecore noise codec2 fec)
    
elseif(WIN32)
    add_library(nadecore SHARED ${NADE_SOURCES})
    target_compile_definitions(nadecore PRIVATE NADE_EXPORTS)
    
    # Link Windows libraries
    target_link_libraries(nadecore ws2_32)
    
    # TODO: Link third-party libs
    # target_link_libraries(nadecore noise codec2 fec)
    
else()
    # Linux/macOS
    add_library(nadecore SHARED ${NADE_SOURCES})
    target_link_libraries(nadecore pthread)
    
    # TODO: Link third-party libs
    # target_link_libraries(nadecore noise codec2 fec)
endif()

# Install rules
install(TARGETS nadecore
    LIBRARY DESTINATION lib
    ARCHIVE DESTINATION lib
    RUNTIME DESTINATION bin
)

install(FILES include/nade_core.h include/modem_fsk.h
    DESTINATION include
)
