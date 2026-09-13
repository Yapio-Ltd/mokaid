#pragma once
#include <filesystem>
#include <memory>
#include <mokaid/engine/scene.hpp>

namespace mokaid::renderer {
struct Context {
  void *device{};
  void *queue{};
  void *commands{};
  void *deviceContext{};
};
struct Statistics {
  std::uint64_t triangles{}, drawCalls{}, textureBytes{};
  double cpuMilliseconds{};
};
// The engine never owns Qt's device, presentation surface, command buffer or
// event loop. All methods execute on the single scenegraph/render thread.
class Renderer {
public:
  virtual ~Renderer() = default;
  virtual void resize(std::uint32_t width, std::uint32_t height) = 0;
  virtual void *texture() const = 0;
  virtual void render(const Context &, const engine::Frame &) = 0;
  virtual void afterComposition(const Context &) = 0;
  virtual Statistics statistics() const = 0;
};
std::unique_ptr<Renderer>
createRenderer(const Context &, const std::filesystem::path &shaderDirectory);
} // namespace mokaid::renderer
