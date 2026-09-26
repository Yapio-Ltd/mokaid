#pragma once
#include <QVariantList>
#include <mokaid/engine/scene.hpp>

namespace mokaid {
// Paint only when canonical work data changes; animation stays on the GPU.
// Immutable image ownership crosses the GUI/render boundary with each Frame.
class OfficeScreenContent {
public:
  void sync(const QVariantList& agents);
  void apply(engine::Frame&, bool reducedMotion) const;
private:
  QVariantList content_;
  std::shared_ptr<const engine::Texture> atlas_;
  std::array<float, 9> activity_{};
};
}
