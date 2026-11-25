# A rustup launcher alone does not imply a working x64 MSVC toolchain.
find_program(VENERA_RUSTC rustc)
if(VENERA_RUSTC)
  set(source "${CMAKE_CURRENT_SOURCE_DIR}/detector.rs")
  set(library "${CMAKE_CURRENT_BINARY_DIR}/venera_ocr.dll")
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${source}")
  execute_process(
    COMMAND "${VENERA_RUSTC}" --crate-type cdylib --edition=2021
      --target x86_64-pc-windows-msvc -C opt-level=3 "${source}" -o "${library}"
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    RESULT_VARIABLE compiled)
  if(compiled STREQUAL "0")
    install(FILES "${library}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
    return()
  endif()
endif()

message(STATUS "Rust OCR library unavailable for x64 MSVC; using Dart preprocessing")
# An incremental install may still contain the library from a previous build.
install(CODE "file(REMOVE \"\$ENV{DESTDIR}${INSTALL_BUNDLE_LIB_DIR}/venera_ocr.dll\")" COMPONENT Runtime)
