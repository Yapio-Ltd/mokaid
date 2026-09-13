include_guard(GLOBAL)
set(MOKAID_DISTRIBUTION_DIR "${CMAKE_CURRENT_LIST_DIR}")
function(mokaid_configure_bundle target)
    find_package(Python3 3.11 REQUIRED COMPONENTS Interpreter)
    set(MOKAID_PRODUCT_NAME Mokaid)
    set(MOKAID_BUNDLE_ID com.mokaid.desktop)
    set(MOKAID_AUTOMATIC_UPDATE_CHECKS false)
    if(MOKAID_ENABLE_UPDATES)
        set(MOKAID_AUTOMATIC_UPDATE_CHECKS true)
    endif()
    set(MOKAID_BUILD_VERSION "${MOKAID_RELEASE_VERSION}")
    string(REPLACE "-beta." "b" MOKAID_BUILD_VERSION "${MOKAID_BUILD_VERSION}")
    if(MOKAID_RELEASE_CHANNEL STREQUAL beta)
        set(MOKAID_PRODUCT_NAME "Mokaid Beta")
        set(MOKAID_BUNDLE_ID com.mokaid.desktop.beta)
    endif()
    if(MOKAID_DEVELOPMENT)
        if(MOKAID_ENABLE_UPDATES OR MOKAID_RELEASE_CHANNEL STREQUAL beta)
            message(FATAL_ERROR "Development identity cannot use release updates or the beta identity")
        endif()
        set(MOKAID_PRODUCT_NAME "Mokaid Development")
        set(MOKAID_BUNDLE_ID com.mokaid.desktop.development)
    endif()
    set(icon_dir "${CMAKE_BINARY_DIR}/icons")
    add_custom_command(OUTPUT "${icon_dir}/Mokaid.icns" "${icon_dir}/Mokaid.ico"
        COMMAND Python3::Interpreter "${MOKAID_DISTRIBUTION_DIR}/release.py" icons
            --output "${icon_dir}"
        DEPENDS "${MOKAID_DISTRIBUTION_DIR}/release.py"
            "${MOKAID_DISTRIBUTION_DIR}/../../web/public/branding/logo-with-bg.png"
        VERBATIM)
    add_custom_target(mokaid_icons DEPENDS "${icon_dir}/Mokaid.icns" "${icon_dir}/Mokaid.ico")
    add_dependencies(${target} mokaid_icons)
    set_target_properties(${target} PROPERTIES OUTPUT_NAME Mokaid)
    if(APPLE)
        configure_file("${MOKAID_DISTRIBUTION_DIR}/macos/Info.plist.in"
            "${CMAKE_CURRENT_BINARY_DIR}/Mokaid-Info.plist" @ONLY)
        set_target_properties(${target} PROPERTIES MACOSX_BUNDLE TRUE
            MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/Mokaid-Info.plist"
            MACOSX_BUNDLE_GUI_IDENTIFIER "${MOKAID_BUNDLE_ID}"
            MACOSX_BUNDLE_BUNDLE_NAME "${MOKAID_PRODUCT_NAME}"
            MACOSX_BUNDLE_BUNDLE_VERSION "${MOKAID_BUILD_VERSION}"
            MACOSX_BUNDLE_SHORT_VERSION_STRING "${MOKAID_RELEASE_VERSION}"
            INSTALL_RPATH "@executable_path/../Frameworks")
        target_sources(${target} PRIVATE "${icon_dir}/Mokaid.icns")
        set_source_files_properties("${icon_dir}/Mokaid.icns" PROPERTIES MACOSX_PACKAGE_LOCATION Resources GENERATED TRUE)
        install(TARGETS ${target} BUNDLE DESTINATION .)
    elseif(WIN32)
        file(GENERATE OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/Mokaid.rc"
            CONTENT "IDI_ICON1 ICON DISCARDABLE \"${icon_dir}/Mokaid.ico\"\n")
        target_sources(${target} PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/Mokaid.rc")
        set_target_properties(${target} PROPERTIES WIN32_EXECUTABLE TRUE)
        install(TARGETS ${target} RUNTIME DESTINATION .)
    endif()
endfunction()
