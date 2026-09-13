add_library(mokaid_presentation STATIC system_controller.cpp frame_profiler.cpp
    include/mokaid/presentation/system_controller.hpp include/mokaid/presentation/frame_profiler.hpp)
target_include_directories(mokaid_presentation PUBLIC include)
target_link_libraries(mokaid_presentation PUBLIC Qt6::Core Qt6::Gui Qt6::Quick mokaid_options)
if(BUILD_TESTING)
  qt_add_executable(mokaid_profiler_tests ../tests/frame_profiler_tests.cpp)
  target_link_libraries(mokaid_profiler_tests PRIVATE mokaid_presentation Qt6::Test mokaid_options)
  add_test(NAME desktop-frame-profiler COMMAND mokaid_profiler_tests)
endif()
set(MOKAID_QML_FILES
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MokaidLabel.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MokaidButton.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MokaidTextField.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MokaidTextArea.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MokaidComboBox.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/Main.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/Theme.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/FeaturePage.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/ActionDialog.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/ActivityPanels.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/OfficePage.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/ChatPanel.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/PreviewPanel.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/DeliveryView.qml"
    PARENT_SCOPE)
