add_library(mokaid_features STATIC
  feature_catalog.cpp feature_controller.cpp record_list_model.cpp detail_browser.cpp drive_download.cpp
  avatar_generation_controller.cpp include/mokaid/features/avatar_generation_controller.hpp
  prepared_download.cpp prepared_download.hpp
  include/mokaid/features/feature_catalog.hpp
  include/mokaid/features/feature_controller.hpp
  include/mokaid/features/drive_download.hpp
  include/mokaid/features/record_list_model.hpp include/mokaid/features/detail_browser.hpp)
target_include_directories(mokaid_features PUBLIC include)
target_link_libraries(mokaid_features PUBLIC Qt6::Core mokaid_application mokaid_network mokaid_storage PRIVATE mokaid_options)
if(BUILD_TESTING)
  qt_add_executable(mokaid_feature_tests tests/feature_tests.cpp)
  target_link_libraries(mokaid_feature_tests PRIVATE mokaid_features Qt6::Test Qt6::Sql mokaid_options)
  add_test(NAME desktop-feature-contracts COMMAND mokaid_feature_tests)
  qt_add_executable(mokaid_drive_file_tests tests/prepared_download_tests.cpp)
  target_link_libraries(mokaid_drive_file_tests PRIVATE mokaid_features Qt6::Test mokaid_options)
  add_test(NAME desktop-drive-files COMMAND mokaid_drive_file_tests)
  if(TARGET Qt6::Quick AND TARGET Qt6::QuickControls2)
    qt_add_executable(mokaid_feature_qml_tests tests/feature_qml_tests.cpp)
    target_link_libraries(mokaid_feature_qml_tests PRIVATE mokaid_features Qt6::Quick Qt6::QuickControls2 Qt6::Test mokaid_options)
    target_compile_definitions(mokaid_feature_qml_tests PRIVATE MOKAID_FEATURE_QML_DIRECTORY="${CMAKE_CURRENT_SOURCE_DIR}/../../presentation/qml")
    add_test(NAME desktop-feature-qml COMMAND mokaid_feature_qml_tests)
    qt_add_executable(mokaid_native_pages_qml_tests tests/native_pages_qml_tests.cpp)
    target_link_libraries(mokaid_native_pages_qml_tests PRIVATE mokaid_features Qt6::Quick Qt6::QuickControls2 Qt6::Test mokaid_options)
    target_compile_definitions(mokaid_native_pages_qml_tests PRIVATE MOKAID_NATIVE_QML_DIRECTORY="${CMAKE_CURRENT_SOURCE_DIR}/../../presentation/qml")
    set(native_page_portraits "${CMAKE_CURRENT_SOURCE_DIR}/../../presentation/assets")
    qt_add_resources(mokaid_native_pages_qml_tests native_page_portraits
      PREFIX "/ui" BASE "${native_page_portraits}"
      FILES "${native_page_portraits}/portrait-male.png" "${native_page_portraits}/portrait-design.png"
        "${native_page_portraits}/portrait-finance.png" "${native_page_portraits}/portrait-corporate.png"
        "${native_page_portraits}/portrait-developer.png" "${native_page_portraits}/portrait-research.png"
        "${native_page_portraits}/portrait-legal.png" "${native_page_portraits}/portrait-byte.png"
        "${native_page_portraits}/portrait-nyx.png" "${native_page_portraits}/portrait-moss.png")
    add_test(NAME desktop-native-pages-qml COMMAND mokaid_native_pages_qml_tests)
  endif()
endif()
