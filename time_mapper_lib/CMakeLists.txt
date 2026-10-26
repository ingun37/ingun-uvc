cmake_minimum_required(VERSION 3.20)
project(time_mapper_lib LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(time_mapper_lib STATIC library.cpp)

find_package(PkgConfig REQUIRED)
pkg_check_modules(FFMPEG REQUIRED IMPORTED_TARGET
        libavcodec libavformat libavutil libswscale)

target_link_libraries(time_mapper_lib PRIVATE PkgConfig::FFMPEG)
target_compile_definitions(time_mapper_lib PRIVATE
        TIME_MAPPER_OCR_SCRIPT="${CMAKE_CURRENT_LIST_DIR}/../ocr/main.py"
        TIME_MAPPER_PYTHON="${CMAKE_CURRENT_LIST_DIR}/../ocr/.venv/bin/python")

include(CTest)
if(BUILD_TESTING)
    add_executable(time_mapper_lib_tests tests.cpp)
    target_link_libraries(time_mapper_lib_tests PRIVATE time_mapper_lib)
    target_compile_definitions(time_mapper_lib_tests PRIVATE
            TEST_DATA_DIR="${CMAKE_CURRENT_LIST_DIR}/test-data")
    add_test(NAME time_mapper_lib_tests COMMAND time_mapper_lib_tests)
endif()
