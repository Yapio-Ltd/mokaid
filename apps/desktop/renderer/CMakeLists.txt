find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(MOKAID_LIGHT_HEADER "${CMAKE_CURRENT_BINARY_DIR}/generated/office_lighting.hpp")
add_custom_command(OUTPUT "${MOKAID_LIGHT_HEADER}"
  COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/tools/generate_lighting.py"
    "${CMAKE_CURRENT_SOURCE_DIR}/../../web/src/three/office-lighting.ts" "${MOKAID_LIGHT_HEADER}"
  DEPENDS tools/generate_lighting.py ../../web/src/three/office-lighting.ts VERBATIM)
add_custom_target(mokaid_lighting DEPENDS "${MOKAID_LIGHT_HEADER}")
if(APPLE)
  enable_language(OBJCXX)
  find_program(MOKAID_XCRUN xcrun REQUIRED)
  set(MOKAID_METAL_TOOLCHAIN "" CACHE STRING "Optional explicit Xcode Metal toolchain identifier")
  set(MOKAID_METAL_TOOLCHAIN_ARGS)
  if(MOKAID_METAL_TOOLCHAIN)
    list(APPEND MOKAID_METAL_TOOLCHAIN_ARGS --toolchain "${MOKAID_METAL_TOOLCHAIN}")
  endif()
  set(MOKAID_SHADER_OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/shaders")
  add_custom_command(OUTPUT "${MOKAID_SHADER_OUTPUT}/office.metallib"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${MOKAID_SHADER_OUTPUT}"
    COMMAND ${MOKAID_XCRUN} ${MOKAID_METAL_TOOLCHAIN_ARGS} -sdk macosx metal -std=metal3.0 -mmacosx-version-min=13.0 -fmodules-cache-path=${CMAKE_CURRENT_BINARY_DIR}/module-cache -c "${CMAKE_CURRENT_SOURCE_DIR}/shaders/office.metal" -o "${MOKAID_SHADER_OUTPUT}/office.air"
    COMMAND ${MOKAID_XCRUN} ${MOKAID_METAL_TOOLCHAIN_ARGS} -sdk macosx metallib "${MOKAID_SHADER_OUTPUT}/office.air" -o "${MOKAID_SHADER_OUTPUT}/office.metallib"
    DEPENDS shaders/office.metal shaders/screen_content.h VERBATIM)
  add_custom_target(mokaid_shaders ALL DEPENDS "${MOKAID_SHADER_OUTPUT}/office.metallib")
  add_library(mokaid_renderer STATIC src/metal_renderer.mm)
  target_compile_options(mokaid_renderer PRIVATE -fobjc-arc -Wall -Wextra -Wpedantic)
  target_link_libraries(mokaid_renderer PRIVATE "-framework Metal" "-framework Foundation")
elseif(WIN32)
  find_program(MOKAID_DXC dxc REQUIRED)
  set(MOKAID_SHADER_OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/shaders")
  foreach(stage IN ITEMS vs ps)
    add_custom_command(OUTPUT "${MOKAID_SHADER_OUTPUT}/office.${stage}.dxil"
      COMMAND ${CMAKE_COMMAND} -E make_directory "${MOKAID_SHADER_OUTPUT}"
      COMMAND ${MOKAID_DXC} -E ${stage}Main -T ${stage}_6_0 -Fo "${MOKAID_SHADER_OUTPUT}/office.${stage}.dxil" "${CMAKE_CURRENT_SOURCE_DIR}/shaders/office.hlsl"
      DEPENDS shaders/office.hlsl shaders/screen_content.h VERBATIM)
  endforeach()
  add_custom_command(OUTPUT "${MOKAID_SHADER_OUTPUT}/office.post.vs.dxil"
    COMMAND ${CMAKE_COMMAND} -E make_directory "${MOKAID_SHADER_OUTPUT}"
    COMMAND ${MOKAID_DXC} -E postVertex -T vs_6_0 -Fo "${MOKAID_SHADER_OUTPUT}/office.post.vs.dxil" "${CMAKE_CURRENT_SOURCE_DIR}/shaders/office.hlsl"
    DEPENDS shaders/office.hlsl shaders/screen_content.h VERBATIM)
  set(MOKAID_POST_SHADERS)
  foreach(entry IN ITEMS bloomDownsample bloomBlur officeComposite)
    add_custom_command(OUTPUT "${MOKAID_SHADER_OUTPUT}/${entry}.ps.dxil"
      COMMAND ${CMAKE_COMMAND} -E make_directory "${MOKAID_SHADER_OUTPUT}"
      COMMAND ${MOKAID_DXC} -E ${entry} -T ps_6_0 -Fo "${MOKAID_SHADER_OUTPUT}/${entry}.ps.dxil" "${CMAKE_CURRENT_SOURCE_DIR}/shaders/office.hlsl"
      DEPENDS shaders/office.hlsl shaders/screen_content.h VERBATIM)
    list(APPEND MOKAID_POST_SHADERS "${MOKAID_SHADER_OUTPUT}/${entry}.ps.dxil")
  endforeach()
  add_custom_target(mokaid_shaders ALL DEPENDS "${MOKAID_SHADER_OUTPUT}/office.vs.dxil" "${MOKAID_SHADER_OUTPUT}/office.ps.dxil"
    "${MOKAID_SHADER_OUTPUT}/office.post.vs.dxil" ${MOKAID_POST_SHADERS})
  add_library(mokaid_renderer STATIC src/d3d12_renderer.cpp)
  target_link_libraries(mokaid_renderer PRIVATE d3d12 d3d11 dxgi dxguid)
  target_compile_definitions(mokaid_renderer PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
else()
  message(FATAL_ERROR "The native desktop renderer supports macOS Metal and Windows D3D12 only")
endif()
target_include_directories(mokaid_renderer PUBLIC include)
target_include_directories(mokaid_renderer PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/generated")
target_link_libraries(mokaid_renderer PUBLIC mokaid_engine)
target_compile_features(mokaid_renderer PUBLIC cxx_std_20)
add_dependencies(mokaid_renderer mokaid_shaders mokaid_lighting)
set(MOKAID_SHADER_DIRECTORY "${MOKAID_SHADER_OUTPUT}" CACHE INTERNAL "Compiled native shaders")
install(DIRECTORY "${MOKAID_SHADER_OUTPUT}/" DESTINATION shaders FILES_MATCHING PATTERN "*.metallib" PATTERN "*.dxil")
if(APPLE AND BUILD_TESTING)
  # Explicit target: build-only CI has no authority to claim GPU validation.
  add_executable(mokaid_metal_smoke EXCLUDE_FROM_ALL tests/metal_smoke.mm)
  target_compile_options(mokaid_metal_smoke PRIVATE -fobjc-arc -Wall -Wextra -Wpedantic)
  target_link_libraries(mokaid_metal_smoke PRIVATE mokaid_renderer
    "-framework Metal" "-framework Foundation" "-framework ImageIO" "-framework CoreGraphics")
endif()
