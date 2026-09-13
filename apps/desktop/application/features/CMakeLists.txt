add_library(mokaid_features STATIC
  feature_catalog.cpp feature_controller.cpp record_list_model.cpp detail_browser.cpp
  include/mokaid/features/feature_catalog.hpp
  include/mokaid/features/feature_controller.hpp
  include/mokaid/features/record_list_model.hpp include/mokaid/features/detail_browser.hpp)
target_include_directories(mokaid_features PUBLIC include)
target_link_libraries(mokaid_features PUBLIC Qt6::Core mokaid_application mokaid_network mokaid_storage PRIVATE mokaid_options)
if(BUILD_TESTING)
  qt_add_executable(mokaid_feature_tests tests/feature_tests.cpp)
  target_link_libraries(mokaid_feature_tests PRIVATE mokaid_features Qt6::Test Qt6::Sql mokaid_options)
  add_test(NAME desktop-feature-contracts COMMAND mokaid_feature_tests)
  if(TARGET Qt6::Quick AND TARGET Qt6::QuickControls2)
    qt_add_executable(mokaid_feature_qml_tests tests/feature_qml_tests.cpp)
    target_link_libraries(mokaid_feature_qml_tests PRIVATE mokaid_features Qt6::Quick Qt6::QuickControls2 Qt6::Test mokaid_options)
    target_compile_definitions(mokaid_feature_qml_tests PRIVATE MOKAID_FEATURE_QML_DIRECTORY="${CMAKE_CURRENT_SOURCE_DIR}/../../presentation/qml")
    add_test(NAME desktop-feature-qml COMMAND mokaid_feature_qml_tests)
  endif()
endif()
