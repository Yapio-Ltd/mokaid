add_library(mokaid_viewport STATIC native_viewport.cpp native_viewport.hpp
  agent_indicator_model.cpp agent_indicator_model.hpp
  custom_avatar_loader.cpp custom_avatar_loader.hpp)
set_target_properties(mokaid_viewport PROPERTIES AUTOMOC ON)
qt_add_qml_module(mokaid_viewport
  URI Mokaid.Native
  VERSION 1.0
  NO_PLUGIN
  RESOURCE_PREFIX "/qt/qml"
  OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/qml/Mokaid/Native"
  TYPEINFO bridge.qmltypes
  DEPENDENCIES QtQuick
)
if(APPLE)
  set_source_files_properties(native_viewport.cpp PROPERTIES LANGUAGE OBJCXX)
  target_compile_options(mokaid_viewport PRIVATE -fobjc-arc)
endif()
target_include_directories(mokaid_viewport PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(mokaid_viewport PUBLIC Qt6::Quick Qt6::Qml mokaid_renderer PRIVATE Qt6::Network Qt6::Concurrent)
target_compile_definitions(mokaid_viewport PRIVATE MOKAID_API_ORIGIN="${MOKAID_API_ORIGIN}")
target_compile_definitions(mokaid_viewport PRIVATE MOKAID_BUILD_SHADER_DIR="${MOKAID_SHADER_DIRECTORY}")
if(BUILD_TESTING)
  add_executable(mokaid_custom_avatar_loader_tests custom_avatar_loader_tests.cpp
    custom_avatar_loader.cpp custom_avatar_loader.hpp)
  set_target_properties(mokaid_custom_avatar_loader_tests PROPERTIES AUTOMOC ON)
  target_compile_definitions(mokaid_custom_avatar_loader_tests PRIVATE MOKAID_API_ORIGIN="https://mokaid.com")
  target_link_libraries(mokaid_custom_avatar_loader_tests PRIVATE Qt6::Core Qt6::Network Qt6::Concurrent mokaid_engine)
  add_test(NAME desktop.custom_avatar_urls COMMAND mokaid_custom_avatar_loader_tests)
  add_executable(mokaid_agent_indicator_tests agent_indicator_tests.cpp
    agent_indicator_model.cpp agent_indicator_model.hpp)
  target_include_directories(mokaid_agent_indicator_tests PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
  target_link_libraries(mokaid_agent_indicator_tests PRIVATE Qt6::Core mokaid_engine)
  add_test(NAME desktop.agent_indicators COMMAND mokaid_agent_indicator_tests)
  set_tests_properties(desktop.agent_indicators PROPERTIES TIMEOUT 15)
endif()
