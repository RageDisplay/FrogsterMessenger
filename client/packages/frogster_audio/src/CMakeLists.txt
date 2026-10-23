# Native audio for Frogster: RNNoise noise suppression and the Opus codec,
# behind a small C interface that Dart calls through FFI.
#
# Built by the Android Gradle plugin (NDK) and by the Windows runner's CMake.
# Opus needs CMake 3.16; Android Studio's bundled 3.22 and Visual Studio's
# own both have it.
cmake_minimum_required(VERSION 3.16)

project(frogster_audio_library VERSION 0.1.0 LANGUAGES C)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Opus: the plain codec. Its neural extensions (DRED, deep PLC, OSCE) need
# tens of megabytes of weights the app has no use for.
set(BUILD_SHARED_LIBS OFF)
foreach(option
    OPUS_BUILD_SHARED_LIBRARY OPUS_BUILD_TESTING OPUS_BUILD_PROGRAMS
    OPUS_INSTALL_PKG_CONFIG_MODULE OPUS_INSTALL_CMAKE_CONFIG_MODULE
    OPUS_DEEP_PLC OPUS_DRED OPUS_OSCE OPUS_CUSTOM_MODES)
  set(${option} OFF CACHE BOOL "" FORCE)
endforeach()
add_subdirectory(third_party/opus EXCLUDE_FROM_ALL)

# RNNoise 0.2, with its model compiled in. Generic C only: the AVX and SSE4
# variants need run-time CPU dispatch, and the generic code is already far
# faster than real time.
add_library(rnnoise STATIC
  third_party/rnnoise/src/denoise.c
  third_party/rnnoise/src/rnn.c
  third_party/rnnoise/src/pitch.c
  third_party/rnnoise/src/kiss_fft.c
  third_party/rnnoise/src/celt_lpc.c
  third_party/rnnoise/src/nnet.c
  third_party/rnnoise/src/nnet_default.c
  third_party/rnnoise/src/rnnoise_data.c
  third_party/rnnoise/src/rnnoise_tables.c
  third_party/rnnoise/src/parse_lpcnet_weights.c
)
target_include_directories(rnnoise
  PUBLIC third_party/rnnoise/include
  PRIVATE third_party/rnnoise/src
  # os_support.h, which RNNoise's plain-C vector code takes from Opus.
  PRIVATE third_party/opus/celt third_party/opus/include)
# RNNoise carries its own copies of a few CELT routines that Opus has too;
# renamed here so the two can live in one library.
target_compile_definitions(rnnoise PRIVATE
  RNNOISE_BUILD
  celt_lpc=rnn_celt_lpc
  _celt_lpc=rnn__celt_lpc
  _celt_autocorr=rnn__celt_autocorr
  celt_fir=rnn_celt_fir
  celt_iir=rnn_celt_iir
  pitch_downsample=rnn_pitch_downsample
  pitch_search=rnn_pitch_search
  remove_doubling=rnn_remove_doubling
  celt_pitch_xcorr=rnn_celt_pitch_xcorr
  opus_fft_alloc=rnn_opus_fft_alloc
  opus_fft_alloc_twiddles=rnn_opus_fft_alloc_twiddles
  opus_fft_free=rnn_opus_fft_free
  opus_fft_c=rnn_opus_fft_c
  opus_fft_impl=rnn_opus_fft_impl
  opus_ifft_c=rnn_opus_ifft_c
  compute_linear=rnn_compute_linear
  compute_activation=rnn_compute_activation
  compute_generic_dense=rnn_compute_generic_dense
  compute_generic_gru=rnn_compute_generic_gru
  compute_generic_conv1d=rnn_compute_generic_conv1d
  compute_glu=rnn_compute_glu
  compute_gated_activation=rnn_compute_gated_activation
  parse_weights=rnn_parse_weights
  linear_init=rnn_linear_init
  conv2d_init=rnn_conv2d_init
)
if(NOT MSVC)
  target_link_libraries(rnnoise PRIVATE m)
endif()

# Hardening for code we compile ourselves: stack canaries, checked libc
# calls, read-only relocations, a non-executable stack. Opus turns on its own
# (OPUS_HARDENING, on by default).
if(NOT MSVC)
  set(FROGSTER_HARDENING -fstack-protector-strong -D_FORTIFY_SOURCE=2)
  target_compile_options(rnnoise PRIVATE ${FROGSTER_HARDENING} -O2)
endif()

add_library(frogster_audio SHARED frogster_audio.c)
if(NOT MSVC)
  target_compile_options(frogster_audio PRIVATE ${FROGSTER_HARDENING} -O2)
  target_link_options(frogster_audio PRIVATE -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack)
else()
  target_compile_options(frogster_audio PRIVATE /GS)
  target_link_options(frogster_audio PRIVATE /NXCOMPAT /DYNAMICBASE)
endif()
target_link_libraries(frogster_audio PRIVATE opus rnnoise)

set_target_properties(frogster_audio PROPERTIES
  PUBLIC_HEADER frogster_audio.h
  OUTPUT_NAME "frogster_audio"
)

target_compile_definitions(frogster_audio PUBLIC DART_SHARED_LIB)

if(ANDROID)
  # Android 15 devices with 16 KB pages.
  target_link_options(frogster_audio PRIVATE "-Wl,-z,max-page-size=16384")
endif()
