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
  qt_add_executable(mokaid_orchestrator_qml_tests ../tests/orchestrator_qml_tests.cpp)
  set_target_properties(mokaid_orchestrator_qml_tests PROPERTIES WIN32_EXECUTABLE FALSE)
  target_link_libraries(mokaid_orchestrator_qml_tests PRIVATE Qt6::Quick Qt6::QuickControls2 Qt6::Test mokaid_options)
  target_compile_definitions(mokaid_orchestrator_qml_tests PRIVATE MOKAID_ORCHESTRATOR_QML_DIRECTORY="${CMAKE_CURRENT_SOURCE_DIR}/qml")
  add_test(NAME desktop-orchestrator-qml COMMAND mokaid_orchestrator_qml_tests)
  set_tests_properties(desktop-orchestrator-qml PROPERTIES TIMEOUT 60)
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
  qt_add_executable(mokaid_office_tour_qml_tests ../tests/office_tour_qml_tests.cpp)
  target_link_libraries(mokaid_office_tour_qml_tests PRIVATE mokaid_viewport Qt6::Quick Qt6::QuickControls2 Qt6::Test mokaid_options)
  target_compile_definitions(mokaid_office_tour_qml_tests PRIVATE
      MOKAID_OFFICE_QML_DIRECTORY="${CMAKE_CURRENT_SOURCE_DIR}/qml"
      MOKAID_OFFICE_ASSET_DIRECTORY="${CMAKE_CURRENT_SOURCE_DIR}/../build/assets")
  qt_add_resources(mokaid_office_tour_qml_tests office_tour_portraits PREFIX "/ui"
      BASE "${CMAKE_CURRENT_SOURCE_DIR}/assets" FILES
      "${CMAKE_CURRENT_SOURCE_DIR}/assets/portrait-male.png"
      "${CMAKE_CURRENT_SOURCE_DIR}/assets/portrait-design.png"
      "${CMAKE_CURRENT_SOURCE_DIR}/assets/portrait-finance.png"
      "${CMAKE_CURRENT_SOURCE_DIR}/assets/portrait-corporate.png"
      "${CMAKE_CURRENT_SOURCE_DIR}/assets/portrait-developer.png"
      "${CMAKE_CURRENT_SOURCE_DIR}/assets/portrait-research.png"
      "${CMAKE_CURRENT_SOURCE_DIR}/assets/portrait-legal.png"
      "${CMAKE_CURRENT_SOURCE_DIR}/assets/portrait-byte.png"
      "${CMAKE_CURRENT_SOURCE_DIR}/assets/portrait-nyx.png"
      "${CMAKE_CURRENT_SOURCE_DIR}/assets/portrait-moss.png")
  if(APPLE)
    set_target_properties(mokaid_office_tour_qml_tests PROPERTIES MACOSX_BUNDLE TRUE
        MACOSX_BUNDLE_GUI_IDENTIFIER "com.mokaid.desktop.officetourtests")
  endif()
  add_test(NAME desktop-office-tour-qml COMMAND mokaid_office_tour_qml_tests)
  set_tests_properties(desktop-office-tour-qml PROPERTIES RUN_SERIAL TRUE TIMEOUT 90 LABELS "gpu;integration")
endif()
set(MOKAID_QML_FILES
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/AgentDetailPanel.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/AgentDetailContent.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MokedDock.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MokedMascot.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/AgentCreationPage.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/AvatarCreator.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/AgentsPage.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/AgentPerformancePage.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/TasksPage.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/TasksBoard.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/TaskBoardCard.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/TasksInspector.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/TaskRuntimePanel.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MarketplacePage.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MarketplaceDiscover.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MarketplaceCard.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MarketplaceDetail.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MarketplaceSeller.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MarketplaceEarnings.qml"
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
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MailAccountsBar.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MailConnectDialog.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/MailAccountsDialog.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/DriveNavigation.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/ActionDialog.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/ActivityPanels.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/OfficePage.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/OfficeNavigationAnchors.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/OfficeTourControls.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/ChatPanel.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/PreviewPanel.qml"
    "${CMAKE_CURRENT_SOURCE_DIR}/qml/DeliveryView.qml"
    PARENT_SCOPE)
