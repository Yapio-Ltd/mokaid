option(MOKAID_ENABLE_UPDATES "Enable signed native update SDK" OFF)
set(MOKAID_RELEASE_CHANNEL "stable" CACHE STRING "Release channel: stable or beta")
set_property(CACHE MOKAID_RELEASE_CHANNEL PROPERTY STRINGS stable beta)
if(NOT MOKAID_RELEASE_CHANNEL MATCHES "^(stable|beta)$")
    message(FATAL_ERROR "MOKAID_RELEASE_CHANNEL must be stable or beta")
endif()

set(MOKAID_UPDATE_PUBLIC_KEY "" CACHE STRING "Base64 Ed25519 public key; never private")
set(MOKAID_UPDATER_SDK "" CACHE PATH "Verified unpacked Sparkle/WinSparkle SDK")
add_library(mokaid_updates STATIC src/update_service.cpp include/mokaid/updates/update_service.hpp)
set_target_properties(mokaid_updates PROPERTIES AUTOMOC ON)
target_include_directories(mokaid_updates PUBLIC include)
target_link_libraries(mokaid_updates PUBLIC Qt6::Core)
target_compile_features(mokaid_updates PUBLIC cxx_std_20)
target_compile_definitions(mokaid_updates PRIVATE
    MOKAID_ENABLE_UPDATES=$<BOOL:${MOKAID_ENABLE_UPDATES}>
    MOKAID_RELEASE_CHANNEL="${MOKAID_RELEASE_CHANNEL}")

if(MOKAID_ENABLE_UPDATES)
    string(LENGTH "${MOKAID_UPDATE_PUBLIC_KEY}" key_length)
    if(NOT key_length EQUAL 44 OR NOT MOKAID_UPDATE_PUBLIC_KEY MATCHES "^[A-Za-z0-9+/]+=*$")
        message(FATAL_ERROR "Signed updates require a 32-byte base64 Ed25519 public key")
    endif()
    if(APPLE)
        enable_language(OBJCXX)
        find_library(MOKAID_SPARKLE_FRAMEWORK Sparkle PATHS "${MOKAID_UPDATER_SDK}" NO_DEFAULT_PATH REQUIRED)
        target_sources(mokaid_updates PRIVATE src/sparkle_update_service.mm)
        set_source_files_properties(src/sparkle_update_service.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
        target_link_libraries(mokaid_updates PRIVATE "${MOKAID_SPARKLE_FRAMEWORK}" "-framework Foundation")
        set(MOKAID_UPDATE_PLATFORM macos-arm64)
    elseif(WIN32)
        find_path(WINSPARKLE_INCLUDE winsparkle.h PATHS "${MOKAID_UPDATER_SDK}/include" NO_DEFAULT_PATH REQUIRED)
        find_library(WINSPARKLE_LIB WinSparkle PATHS "${MOKAID_UPDATER_SDK}/x64/Release" "${MOKAID_UPDATER_SDK}/lib" NO_DEFAULT_PATH REQUIRED)
        target_sources(mokaid_updates PRIVATE src/winsparkle_update_service.cpp)
        target_include_directories(mokaid_updates PRIVATE "${WINSPARKLE_INCLUDE}")
        target_link_libraries(mokaid_updates PRIVATE "${WINSPARKLE_LIB}")
        set(MOKAID_UPDATE_PLATFORM windows-x64)
    else()
        message(FATAL_ERROR "Native updates support only macOS and Windows")
    endif()
    target_compile_definitions(mokaid_updates PRIVATE
        MOKAID_UPDATE_PUBLIC_KEY="${MOKAID_UPDATE_PUBLIC_KEY}"
        MOKAID_UPDATE_FEED_URL="https://downloads.mokaid.com/${MOKAID_RELEASE_CHANNEL}/${MOKAID_UPDATE_PLATFORM}.xml")
endif()

if(BUILD_TESTING)
    add_executable(mokaid_update_service_test tests/update_service_test.cpp)
    target_link_libraries(mokaid_update_service_test PRIVATE mokaid_updates)
    target_compile_definitions(mokaid_update_service_test PRIVATE MOKAID_TEST_UPDATES_ENABLED=$<BOOL:${MOKAID_ENABLE_UPDATES}>)
    add_test(NAME desktop_update_service_contract COMMAND mokaid_update_service_test)
    if(WIN32 AND MOKAID_ENABLE_UPDATES)
        add_custom_command(TARGET mokaid_update_service_test POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${MOKAID_UPDATER_SDK}/x64/Release/WinSparkle.dll"
                "$<TARGET_FILE_DIR:mokaid_update_service_test>"
            VERBATIM)
    endif()
endif()
