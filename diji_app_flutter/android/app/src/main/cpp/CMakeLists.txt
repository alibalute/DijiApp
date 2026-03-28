cmake_minimum_required(VERSION 3.22.1)
project(native_usb_synth)

add_library(native_usb_synth SHARED native_synth_jni.cpp)
target_include_directories(native_usb_synth PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

find_library(log-lib log)
target_link_libraries(native_usb_synth ${log-lib} android)
