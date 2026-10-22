# --- Windows diagnostic target ---

cmake_minimum_required(VERSION 3.20)
project(CRDWindowProbe VERSION 0.1.0 LANGUAGES CXX)
if(NOT WIN32)
  message(FATAL_ERROR "CRDWindowProbe requires Windows 10/11 and a Windows SDK. It is not a macOS backend.")
endif()
add_executable(CRDWindowProbe src/WindowProbe.cpp)
target_compile_features(CRDWindowProbe PRIVATE cxx_std_17)
target_compile_definitions(CRDWindowProbe PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX _WIN32_WINNT=0x0A00)
target_link_libraries(CRDWindowProbe PRIVATE user32 wintrust crypt32)
# --- Compiler and entry-point options ---

if(MSVC)
  target_compile_options(CRDWindowProbe PRIVATE /W4 /permissive- /utf-8)
else()
  target_compile_options(CRDWindowProbe PRIVATE -Wall -Wextra -Wpedantic)
  if(MINGW)
    target_link_options(CRDWindowProbe PRIVATE -municode)
  endif()
endif()
