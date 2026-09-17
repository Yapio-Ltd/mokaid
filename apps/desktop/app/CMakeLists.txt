qt_add_executable(mokaid_desktop main.cpp)
target_link_libraries(mokaid_desktop PRIVATE mokaid_features mokaid_presentation mokaid_preview mokaid_viewport mokaid_updates
    mokaid_application Qt6::QuickControls2 Qt6::WebEngineQuick mokaid_options)
target_compile_definitions(mokaid_desktop PRIVATE MOKAID_API_ORIGIN="${MOKAID_API_ORIGIN}"
    MOKAID_DEVELOPMENT=$<BOOL:${MOKAID_DEVELOPMENT}>
    MOKAID_WEB_ORIGIN="${MOKAID_WEB_ORIGIN}"
    MOKAID_RELEASE_VERSION="${MOKAID_RELEASE_VERSION}" MOKAID_RELEASE_CHANNEL="${MOKAID_RELEASE_CHANNEL}"
    MOKAID_DEV_ASSETS="${CMAKE_BINARY_DIR}/../assets")
foreach(qml IN LISTS MOKAID_QML_FILES)
    get_filename_component(name "${qml}" NAME)
    set_source_files_properties("${qml}" PROPERTIES QT_RESOURCE_ALIAS "${name}")
    if(name STREQUAL "Theme.qml")
        set_source_files_properties("${qml}" PROPERTIES QT_QML_SINGLETON_TYPE TRUE)
    endif()
endforeach()
qt_add_qml_module(mokaid_desktop URI Mokaid.Desktop VERSION 1.0 RESOURCE_PREFIX "/qt/qml"
    IMPORT_PATH "${CMAKE_BINARY_DIR}/qml" QML_FILES ${MOKAID_QML_FILES})
qt_add_resources(mokaid_desktop branding PREFIX "/branding" BASE "${CMAKE_SOURCE_DIR}/../web/public/branding"
    FILES "${CMAKE_SOURCE_DIR}/../web/public/branding/logo-without-bg.png" "${CMAKE_SOURCE_DIR}/../web/public/branding/logo-with-bg.png")
qt_add_resources(mokaid_desktop desktop_ui PREFIX "/ui" BASE "${CMAKE_SOURCE_DIR}/presentation/assets"
    FILES
    "${CMAKE_SOURCE_DIR}/presentation/assets/fonts/Manrope.ttf"
    "${CMAKE_SOURCE_DIR}/presentation/assets/fonts/OFL-Manrope.txt"
    "${CMAKE_SOURCE_DIR}/presentation/assets/portrait-male.png"
    "${CMAKE_SOURCE_DIR}/presentation/assets/portrait-design.png"
    "${CMAKE_SOURCE_DIR}/presentation/assets/portrait-finance.png"
    "${CMAKE_SOURCE_DIR}/presentation/assets/portrait-corporate.png"
    "${CMAKE_SOURCE_DIR}/presentation/assets/portrait-developer.png"
    "${CMAKE_SOURCE_DIR}/presentation/assets/portrait-research.png"
    "${CMAKE_SOURCE_DIR}/presentation/assets/portrait-legal.png"
    "${CMAKE_SOURCE_DIR}/presentation/assets/portrait-byte.png"
    "${CMAKE_SOURCE_DIR}/presentation/assets/portrait-nyx.png"
    "${CMAKE_SOURCE_DIR}/presentation/assets/portrait-moss.png"
    "${CMAKE_SOURCE_DIR}/presentation/assets/brand-orb.png"
    "${CMAKE_SOURCE_DIR}/presentation/assets/workforce-energy-orb.png")
include("${CMAKE_SOURCE_DIR}/distribution/DesktopBundle.cmake")
mokaid_configure_bundle(mokaid_desktop)
