add_library(mokaid_presentation STATIC system_controller.cpp frame_profiler.cpp project_runtime.cpp
    include/mokaid/presentation/project_runtime.hpp
    include/mokaid/presentation/system_controller.hpp include/mokaid/presentation/frame_profiler.hpp)
target_include_directories(mokaid_presentation PUBLIC include)
target_link_libraries(mokaid_presentation PUBLIC Qt6::Core Qt6::Gui Qt6::Quick Qt6::Network mokaid_options)
if(APPLE)
  target_link_libraries(mokaid_presentation PRIVATE "-framework AudioToolbox")
elseif(WIN32)
  target_link_libraries(mokaid_presentation PRIVATE user32)
endif()
if(BUILD_TESTING)
  qt_add_executable(mokaid_menu_qml_tests ../tests/menu_qml_tests.cpp)
  target_link_libraries(mokaid_menu_qml_tests PRIVATE Qt6::Quick Qt6::QuickControls2 Qt6::Test mokaid_options)
  target_compile_definitions(mokaid_menu_qml_tests PRIVATE MOKAID_MENU_QML_DIRECTORY="${CMAKE_CURRENT_SOURCE_DIR}/qml")
  add_test(NAME desktop-menu-qml COMMAND mokaid_menu_qml_tests)
  qt_add_executable(mokaid_mission_qml_tests ../tests/mission_qml_tests.cpp)
  target_link_libraries(mokaid_mission_qml_tests PRIVATE mokaid_application mokaid_presentation Qt6::Quick Qt6::QuickControls2 Qt6::Test mokaid_options)
  target_compile_definitions(mokaid_mission_qml_tests PRIVATE MOKAID_MISSION_QML_DIRECTORY="${CMAKE_CURRENT_SOURCE_DIR}/qml")
  add_test(NAME desktop-mission-qml COMMAND mokaid_mission_qml_tests)
  qt_add_executable(mokaid_profiler_tests ../tests/frame_profiler_tests.cpp)
  target_link_libraries(mokaid_profiler_tests PRIVATE mokaid_presentation Qt6::Test mokaid_options)
  add_test(NAME desktop-frame-profiler COMMAND mokaid_profiler_tests)
  qt_add_executable(mokaid_project_runtime_tests ../tests/project_runtime_tests.cpp)
  target_link_libraries(mokaid_project_runtime_tests PRIVATE mokaid_presentation Qt6::Test mokaid_options)
  add_test(NAME desktop-project-runtime COMMAND mokaid_project_runtime_tests)
  set_tests_properties(desktop-project-runtime PROPERTIES RUN_SERIAL TRUE TIMEOUT 90)
endif()
set(MOKAID_QML_FILES
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/AgentCreationPage.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/AgentsPage.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/WorkforcePortrait.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/FeatureLogic.js"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/FeatureCollection.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/FeatureInspector.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/FeatureCalendar.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/FeatureSummary.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/DeliveryCard.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/DeliveryGallery.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/ProjectPanel.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MissionPanel.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/DesktopShell.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MokaidIcon.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MokaidIconButton.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MokaidDialog.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MokaidMenu.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/AgentIndicators.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/AgentPortrait.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/AgentCard.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/OfficeStat.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MokaidLabel.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MokaidButton.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MokaidTextField.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MokaidTextArea.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MokaidComboBox.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/Main.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/Theme.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/FeaturePage.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/DriveNavigation.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/ActionDialog.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/ActivityPanels.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/OfficePage.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/ChatPanel.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/PreviewPanel.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/DeliveryView.qml"
    PARENT_SCOPE)
