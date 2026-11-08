cmake_minimum_required(VERSION 3.22)
project(venera_native LANGUAGES C)

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
