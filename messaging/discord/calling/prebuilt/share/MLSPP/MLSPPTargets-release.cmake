#----------------------------------------------------------------
# Generated CMake target import file for configuration "Release".
#----------------------------------------------------------------

# Commands may need to know the format version.
set(CMAKE_IMPORT_FILE_VERSION 1)

# Import target "MLSPP::bytes" for configuration "Release"
set_property(TARGET MLSPP::bytes APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(MLSPP::bytes PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "CXX"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libbytes.a"
  )

list(APPEND _cmake_import_check_targets MLSPP::bytes )
list(APPEND _cmake_import_check_files_for_MLSPP::bytes "${_IMPORT_PREFIX}/lib/libbytes.a" )

# Import target "MLSPP::hpke" for configuration "Release"
set_property(TARGET MLSPP::hpke APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(MLSPP::hpke PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "CXX"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libhpke.a"
  )

list(APPEND _cmake_import_check_targets MLSPP::hpke )
list(APPEND _cmake_import_check_files_for_MLSPP::hpke "${_IMPORT_PREFIX}/lib/libhpke.a" )

# Import target "MLSPP::tls_syntax" for configuration "Release"
set_property(TARGET MLSPP::tls_syntax APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(MLSPP::tls_syntax PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "CXX"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libtls_syntax.a"
  )

list(APPEND _cmake_import_check_targets MLSPP::tls_syntax )
list(APPEND _cmake_import_check_files_for_MLSPP::tls_syntax "${_IMPORT_PREFIX}/lib/libtls_syntax.a" )

# Import target "MLSPP::mls_ds" for configuration "Release"
set_property(TARGET MLSPP::mls_ds APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(MLSPP::mls_ds PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "CXX"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libmls_ds.a"
  )

list(APPEND _cmake_import_check_targets MLSPP::mls_ds )
list(APPEND _cmake_import_check_files_for_MLSPP::mls_ds "${_IMPORT_PREFIX}/lib/libmls_ds.a" )

# Import target "MLSPP::mls_vectors" for configuration "Release"
set_property(TARGET MLSPP::mls_vectors APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(MLSPP::mls_vectors PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "CXX"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libmls_vectors.a"
  )

list(APPEND _cmake_import_check_targets MLSPP::mls_vectors )
list(APPEND _cmake_import_check_files_for_MLSPP::mls_vectors "${_IMPORT_PREFIX}/lib/libmls_vectors.a" )

# Import target "MLSPP::mlspp" for configuration "Release"
set_property(TARGET MLSPP::mlspp APPEND PROPERTY IMPORTED_CONFIGURATIONS RELEASE)
set_target_properties(MLSPP::mlspp PROPERTIES
  IMPORTED_LINK_INTERFACE_LANGUAGES_RELEASE "CXX"
  IMPORTED_LOCATION_RELEASE "${_IMPORT_PREFIX}/lib/libmlspp.a"
  )

list(APPEND _cmake_import_check_targets MLSPP::mlspp )
list(APPEND _cmake_import_check_files_for_MLSPP::mlspp "${_IMPORT_PREFIX}/lib/libmlspp.a" )

# Commands beyond this point should not need to know the version.
set(CMAKE_IMPORT_FILE_VERSION)
