cmake_minimum_required(VERSION 4.3)
project(time_mapper_lib)

set(CMAKE_CXX_STANDARD 26)

add_library(time_mapper_lib STATIC library.cpp)

find_package(PkgConfig REQUIRED)
pkg_check_modules(FFMPEG REQUIRED IMPORTED_TARGET
        libavcodec libavformat libavutil libswscale libswresample)

find_package(OpenCV REQUIRED)

find_package(OpenMP REQUIRED)

find_package(ncnn REQUIRED)

target_link_libraries(time_mapper_lib PUBLIC PkgConfig::FFMPEG ${OpenCV_LIBS})
target_include_directories(time_mapper_lib PUBLIC ${OpenCV_INCLUDE_DIRS})
