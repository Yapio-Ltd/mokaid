qt_add_executable(mokaid_graphics_probe probe.cpp)
if(APPLE)
    # LaunchServices can foreground this test window as a real GUI application.
    # A bare executable may stay occluded behind the terminal/Codex, in which
    # case Qt legitimately stops composing and the timing sample must fail.
    set_target_properties(mokaid_graphics_probe PROPERTIES
        MACOSX_BUNDLE TRUE
        MACOSX_BUNDLE_GUI_IDENTIFIER "com.mokaid.desktop.graphicsprobe"
        MACOSX_BUNDLE_BUNDLE_NAME "Mokaid Graphics Probe")
endif()
target_link_libraries(mokaid_graphics_probe PRIVATE mokaid_viewport mokaid_preview
    Qt6::Quick Qt6::QuickControls2 Qt6::WebEngineQuick Qt6::Test mokaid_options)
target_compile_features(mokaid_graphics_probe PRIVATE cxx_std_20)
target_compile_definitions(mokaid_graphics_probe PRIVATE MOKAID_PROBE_INSTRUMENTED=$<BOOL:${MOKAID_ENABLE_SANITIZERS}>)
set(production_qml "${CMAKE_CURRENT_SOURCE_DIR}/../../presentation/qml")
set_source_files_properties("${production_qml}/Theme.qml" PROPERTIES QT_QML_SINGLETON_TYPE TRUE QT_RESOURCE_ALIAS Theme.qml)
set_source_files_properties("${production_qml}/DeliveryView.qml" PROPERTIES QT_RESOURCE_ALIAS DeliveryView.qml)
set_source_files_properties("${production_qml}/MokaidButton.qml" PROPERTIES QT_RESOURCE_ALIAS MokaidButton.qml)
set_source_files_properties("${production_qml}/MokaidLabel.qml" PROPERTIES QT_RESOURCE_ALIAS MokaidLabel.qml)
qt_add_qml_module(mokaid_graphics_probe URI Mokaid.GraphicsProbe VERSION 1.0
    RESOURCE_PREFIX "/qt/qml" QML_FILES Harness.qml "${production_qml}/Theme.qml" "${production_qml}/DeliveryView.qml"
        "${production_qml}/MokaidButton.qml" "${production_qml}/MokaidLabel.qml")
qt_add_resources(mokaid_graphics_probe probe_fixture PREFIX "/probe" FILES fixture.html)

# Hosted build success is not GPU acceptance. Opt in only on a real desktop
# session with freshly cooked assets; the normal application has no test bypass.
option(MOKAID_RUN_GRAPHICS_PROBE_CTEST "Run the visible native/WebEngine graphics probe" OFF)
set(MOKAID_PROBE_ASSETS "${CMAKE_BINARY_DIR}/../assets" CACHE PATH "Cooked graphics probe assets")
set(MOKAID_PROBE_MACHINE "Uncharacterized test host" CACHE STRING "Honest physical machine label")
if(BUILD_TESTING AND MOKAID_RUN_GRAPHICS_PROBE_CTEST)
    add_test(NAME native_webengine_graphics_probe COMMAND mokaid_graphics_probe
        --assets "${MOKAID_PROBE_ASSETS}" --output "${CMAKE_CURRENT_BINARY_DIR}/results"
        --machine-label "${MOKAID_PROBE_MACHINE}")
    set_tests_properties(native_webengine_graphics_probe PROPERTIES TIMEOUT 120 LABELS "gpu;integration")
endif()
