cmake_minimum_required(VERSION 3.22.1)
project("narrator_ncnn")

# NCNN headers & prebuilt libs — expected in android/app/src/main/jni/ncnn/
set(NCNN_DIR ${CMAKE_SOURCE_DIR}/ncnn)

add_library(narrator_ncnn SHARED narrator_ncnn.cpp)

# Include NCNN headers
target_include_directories(narrator_ncnn PRIVATE ${NCNN_DIR}/include)

# Link prebuilt NCNN static lib for this ABI
add_library(ncnn STATIC IMPORTED)
set_target_properties(ncnn PROPERTIES
    IMPORTED_LOCATION ${NCNN_DIR}/lib/${ANDROID_ABI}/libncnn.a)


target_link_libraries(narrator_ncnn
    ncnn
    -fopenmp -static-openmp
    android
    log
    z)
