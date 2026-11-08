cmake_minimum_required(VERSION 3.22)
project(venera_native LANGUAGES C CXX)

get_filename_component(VENERA_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../../.." ABSOLUTE)
include("${VENERA_ROOT}/.dart_tool/ohos/native_deps.cmake")

set(CMAKE_POSITION_INDEPENDENT_CODE ON)
include("${FLUTTER_QJS_SOURCE}/cxx/quickjs.cmake")
add_library(qjs SHARED "${FLUTTER_QJS_SOURCE}/cxx/ffi.cpp")
target_compile_features(qjs PRIVATE cxx_std_17)
target_link_libraries(qjs PRIVATE quickjs m)

add_subdirectory("${ZIP_FLUTTER_SOURCE}/src" "${CMAKE_CURRENT_BINARY_DIR}/zip_flutter")
add_subdirectory("${FLUTTER_7ZIP_SOURCE}/src" "${CMAKE_CURRENT_BINARY_DIR}/flutter_7zip")
add_subdirectory("${LODEPNG_FLUTTER_SOURCE}/src" "${CMAKE_CURRENT_BINARY_DIR}/lodepng_flutter")

include(FetchContent)
# Official source and digest: https://www.sqlite.org/download.html
FetchContent_Declare(sqlite_source
  URL https://www.sqlite.org/2026/sqlite-amalgamation-3540100.zip
  URL_HASH SHA3_256=92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30
  TLS_VERIFY ON
  DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)
FetchContent_MakeAvailable(sqlite_source)

add_library(sqlite3 SHARED "${sqlite_source_SOURCE_DIR}/sqlite3.c")
target_compile_definitions(sqlite3 PRIVATE
  SQLITE_THREADSAFE=1
  SQLITE_ENABLE_FTS5
  SQLITE_ENABLE_RTREE
  SQLITE_ENABLE_MATH_FUNCTIONS
  SQLITE_ENABLE_SESSION
  SQLITE_ENABLE_PREUPDATE_HOOK
)
target_link_libraries(sqlite3 PRIVATE m dl pthread)
