cmake_minimum_required(VERSION 3.10)
project(nade_core LANGUAGES C)

add_library(nade_core SHARED
    src/monocypher.c
    src/nade_core.c
)

target_include_directories(nade_core PRIVATE include)

target_compile_definitions(nade_core PRIVATE -D_POSIX_C_SOURCE=200112L)

find_library(log-lib log)

# Link math library for sin/cos functions used in 4-FSK modulation
target_link_libraries(nade_core PRIVATE ${log-lib} m)
