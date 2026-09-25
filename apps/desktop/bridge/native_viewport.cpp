#include "native_viewport.hpp"
#include <QCoreApplication>
#include <QDir>
#include <QMouseEvent>
#include <QPointer>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSGSimpleTextureNode>
#include <QSGTexture>
#include <QtQml>
#include <mokaid/renderer/renderer.hpp>
#ifdef Q_OS_MACOS
#import <Metal/Metal.h>
#endif

namespace mokaid {
namespace {
renderer::Context context(QQuickWindow *w) {
  auto *r = w->rendererInterface();
  renderer::Context c;
  c.device = r->getResource(w, QSGRendererInterface::DeviceResource);
  c.queue = r->getResource(w, QSGRendererInterface::CommandQueueResource);
  c.commands = r->getResource(w, QSGRendererInterface::CommandListResource);
  c.deviceContext =
      r->getResource(w, QSGRendererInterface::DeviceContextResource);
  // Qt's Metal texture-import example returns Objective-C objects directly
  // here (unlike Vulkan's pointer-to-handle resources). Do not dereference
  // them.
  return c;
}
std::filesystem::path shaderDirectory() {
  const QDir app(QCoreApplication::applicationDirPath());
  for (const auto &relative :
       {QStringLiteral("../Resources/shaders"), QStringLiteral("shaders")}) {
    const auto p = app.absoluteFilePath(relative);
    if (QDir(p).exists())
      return p.toStdString();
  }
  return MOKAID_BUILD_SHADER_DIR;
}
class TextureNode final : public QObject, public QSGSimpleTextureNode {
  QQuickWindow *window_;
  QPointer<NativeViewport> item_;
  std::unique_ptr<renderer::Renderer> renderer_;
  std::unique_ptr<QSGTexture> texture_;
  std::shared_ptr<const engine::Frame> frame_;
  bool paused_{}, needsRender_{}, faulted_{};
  QSize size_;
  int counter_{};
  void *nativeTexture_{};
  std::uint64_t generation_{};

public:
  TextureNode(QQuickWindow *w, NativeViewport *item, std::uint64_t generation)
      : window_(w), item_(item), generation_(generation) {
    setFiltering(QSGTexture::Linear);
    connect(
        w, &QQuickWindow::beforeRendering, this, [this] { render(); },
        Qt::DirectConnection);
    connect(
        w, &QQuickWindow::afterRendering, this,
        [this] {
          try {
            if (renderer_)
              renderer_->afterComposition(context(window_));
          } catch (const std::exception &e) {
            const auto message = QString::fromUtf8(e.what());
            if (item_)
              QMetaObject::invokeMethod(
                  item_,
                  [item = item_, message] {
                    if (item)
                      item->reportError(message);
                  },
                  Qt::QueuedConnection);
          }
        },
        Qt::DirectConnection);
  }
  void fail() { faulted_ = true; }
  bool hasTexture() const { return texture_ != nullptr; }
  std::uint64_t generation() const { return generation_; }
  void sync(std::shared_ptr<const engine::Frame> frame, QSize size, bool paused) {
    if (faulted_)
      return;
    const auto api = window_->rendererInterface()->graphicsApi();
#ifdef Q_OS_MACOS
    if (api != QSGRendererInterface::Metal)
      throw std::runtime_error(
          "Native office requires Qt Quick's Metal backend");
#elif defined(Q_OS_WIN)
    if (api != QSGRendererInterface::Direct3D11)
      throw std::runtime_error(
          "Native office requires Qt Quick's Direct3D11 backend");
#endif
    if (paused && texture_) {
      frame_ = std::move(frame);
      paused_ = true;
      return;
    }
    if (!renderer_)
      renderer_ = renderer::createRenderer(context(window_), shaderDirectory());
    renderer_->resize(static_cast<std::uint32_t>(size.width()),
                      static_cast<std::uint32_t>(size.height()));
    if (!texture_ || size_ != size || nativeTexture_ != renderer_->texture()) {
      QSGTexture *wrapped = nullptr;
#ifdef Q_OS_MACOS
      wrapped = QNativeInterface::QSGMetalTexture::fromNative(
          (__bridge id<MTLTexture>)renderer_->texture(), window_, size);
#elif defined(Q_OS_WIN)
      wrapped = QNativeInterface::QSGD3D11Texture::fromNative(
          renderer_->texture(), window_, size);
#endif
      if (!wrapped)
        throw std::runtime_error("Native Qt texture import failed");
      // Qt's setter requires non-null textures. Keep the previous wrapper
      // alive until Qt has switched its material to the new native texture.
      setTexture(wrapped);
      texture_.reset(wrapped);
      size_ = size;
      nativeTexture_ = renderer_->texture();
    }
    frame_ = std::move(frame);
    paused_ = paused && counter_ > 0;
    needsRender_ = true;
    markDirty(QSGNode::DirtyMaterial);
  }
  void render() {
    if (!renderer_ || !frame_ || paused_ || faulted_ || !needsRender_)
      return;
    needsRender_ = false;
    try {
      window_->beginExternalCommands();
      renderer_->render(context(window_), *frame_);
      window_->endExternalCommands();
      if (++counter_ % 60 == 0 && item_) {
        const auto stats = renderer_->statistics();
        QVariantMap data{
            {"drawCalls", QVariant::fromValue(stats.drawCalls)},
            {"triangles", QVariant::fromValue(stats.triangles)},
            {"textureBytes", QVariant::fromValue(stats.textureBytes)},
            {"renderCpuMs", stats.cpuMilliseconds},
            {"renderWidth", size_.width()},
            {"renderHeight", size_.height()}};
        QMetaObject::invokeMethod(
            item_,
            [item = item_, data] {
              if (item)
                item->reportDiagnostics(data);
            },
            Qt::QueuedConnection);
      }
    } catch (const std::exception &e) {
      window_->endExternalCommands();
      paused_ = true;
      faulted_ = true;
      const auto message = QString::fromUtf8(e.what());
      if (item_)
        QMetaObject::invokeMethod(
            item_,
            [item = item_, message] {
              if (item)
                item->reportError(message);
            },
            Qt::QueuedConnection);
    }
  }
};
} // namespace
NativeViewport::NativeViewport(QQuickItem *parent)
    : QQuickItem(parent), office_(std::make_shared<engine::Office>()) {
  setFlag(ItemHasContents, true);
  connect(&customAvatars_, &CustomAvatarLoader::ready, this,
          [this](QString key, std::shared_ptr<const engine::Scene> scene) {
    if (!activeCustomAvatars_.contains(key)) return;
    office_->setCustomAvatar(key.toStdString(), std::move(scene));
    loadedCustomAvatars_.insert(key);
    avatarError_.clear(); emit avatarErrorChanged(); update();
  });
  connect(&customAvatars_, &CustomAvatarLoader::failed, this, [this](const QString &message) {
    avatarError_ = message; emit avatarErrorChanged();
  });
  setAcceptedMouseButtons(Qt::LeftButton);
  timer_.setInterval(16);
  timer_.setTimerType(Qt::PreciseTimer);
  connect(&timer_, &QTimer::timeout, this, [this] {
    if (!paused_ && error_.isEmpty() && isVisible() && window() &&
        window()->isVisible()) {
      if(++indicatorTick_%2==0) updateIndicators();
      update();
    }
  });
  connect(this,&QQuickItem::widthChanged,this,&NativeViewport::updateIndicators);
  connect(this,&QQuickItem::heightChanged,this,&NativeViewport::updateIndicators);
  timer_.start();
}
void NativeViewport::updateIndicators() {
  if(loading_||!error_.isEmpty()||width()<1||height()<1){indicators_.clear();return;}
  indicators_.sync(*office_->snapshot(static_cast<float>(width()/height())),QSizeF(width(),height()));
}
NativeViewport::~NativeViewport() {
  loader_.request_stop();
  if (loader_.joinable())
    loader_.join();
}
void NativeViewport::setAssetRoot(const QString &path) {
  if (assetRoot_ == path)
    return;
  customAvatars_.reset();
  loadedCustomAvatars_.clear();
  assetRoot_ = path;
  emit assetRootChanged();
  loading_ = true;
  indicators_.clear();
  error_.clear();
  emit loadingChanged();
  emit errorChanged();
  const auto generation = ++generation_;
  const QPointer<NativeViewport> guard(this);
  const auto office = office_;
  loader_ =
      std::jthread([guard, office, path, generation](std::stop_token stop) {
        QString error;
        try {
          office->load(path.toStdString());
        } catch (const std::exception &e) {
          error = QString::fromUtf8(e.what());
        }
        if (stop.stop_requested())
          return;
        if (guard)
          QMetaObject::invokeMethod(
              guard,
              [guard, generation, error] {
                if (!guard || guard->generation_ != generation)
                  return;
                guard->loading_ = false;
                emit guard->loadingChanged();
                if (!error.isEmpty())
                  guard->reportError(error);
                else {
                  ++guard->rendererGeneration_;
                  guard->retryCustomAvatars();
                }
                guard->update();
              },
              Qt::QueuedConnection);
      });
}
void NativeViewport::setAgents(const QVariantList &list) {
  agents_ = list;
  QSet<QString> activeCustom;
  std::vector<engine::Agent> agents;
  agents.reserve(static_cast<std::size_t>(list.size()));
  for (const auto &v : list) {
    auto m = v.toMap();
    const auto status = m.value("status").toString().toStdString();
    if (status == "archived") continue;
    const auto presence = m.value("kind").toString() == "human_linked"
        ? m.value("presence_status").toString().toStdString() : std::string("online");
    const auto animation = engine::agentVisualState(status, presence,
        !m.value("current_task_id").toString().isEmpty());
    auto type = m.value("asset_type").toString();
    if (type.startsWith("avatar_"))
      type = type.mid(7);
    if (type.startsWith("custom:")) activeCustom.insert(type);
    agents.push_back({m.value("id").toString().toStdString(),
                      m.value("name").toString().toStdString(),
                      std::string(animation),
                      type.toStdString(), m.value("seat_index", -1).toInt(),
                      std::max(0,m.value("level",0).toInt())});
  }
  // Native renderer scene caches retain GPU resources; replacing a custom
  // roster rebuilds the renderer and releases models no longer in this office.
  if (!(activeCustomAvatars_ - activeCustom).isEmpty()) ++rendererGeneration_;
  activeCustomAvatars_ = activeCustom;
  loadedCustomAvatars_.intersect(activeCustom);
  office_->setAgents(std::move(agents));
  if (activeCustom.isEmpty()) {
    customAvatars_.reset();
    avatarError_.clear(); emit avatarErrorChanged();
  } else if (!loading_) {
    for (const auto &value : agents_) {
      const auto agent = value.toMap();
      const auto key = agent.value("asset_type").toString();
      if (activeCustom.contains(key) && !loadedCustomAvatars_.contains(key))
        customAvatars_.load(key, QUrl(agent.value("avatar_native_cdn_path").toString()));
    }
  }
  emit agentsChanged();
  updateIndicators();
  update();
}
void NativeViewport::retryCustomAvatars() {
  avatarError_.clear(); emit avatarErrorChanged();
  setAgents(agents_);
}
void NativeViewport::setPaused(bool v) {
  if (paused_ == v)
    return;
  paused_ = v;
  office_->setPaused(v);
  emit pausedChanged();
  update();
}
void NativeViewport::setQuality(const QString &v) {
  if (quality_ == v)
    return;
  quality_ = v;
  emit qualityChanged();
  update();
}
void NativeViewport::reportError(QString e) {
  error_ = std::move(e);
  indicators_.clear();
  emit errorChanged();
}
void NativeViewport::reportDiagnostics(QVariantMap d) {
  d["assetBytes"] = QVariant::fromValue(office_->residentBytes());
  diagnostics_ = std::move(d);
  emit diagnosticsChanged();
}
void NativeViewport::retryRenderer() {
  ++rendererGeneration_;
  error_.clear();
  emit errorChanged();
  update();
}
QSGNode *NativeViewport::updatePaintNode(QSGNode *old, UpdatePaintNodeData *) {
  if (!window() || width() < 1 || height() < 1)
    return old;
  auto node = std::unique_ptr<TextureNode>(static_cast<TextureNode *>(old));
  if (!error_.isEmpty())
    return node && node->hasTexture() ? node.release() : nullptr;
  try {
    // Recreate the node as a unit. QSGSimpleTextureNode::setTexture(nullptr)
    // dereferences the texture in Qt 6.11 and is not a valid reset operation.
    if (node && node->generation() != rendererGeneration_)
      node.reset();
    if (!node)
      node = std::make_unique<TextureNode>(window(), this, rendererGeneration_);
    const qreal scale = quality_ == "low" ? .65 : quality_ == "high" ? 1. : .85;
    const qreal dpr = window()->effectiveDevicePixelRatio();
    const QSize size(qBound(1, qRound(width() * dpr * scale), 3840),
                     qBound(1, qRound(height() * dpr * scale), 2160));
    node->sync(office_->snapshot(static_cast<float>(width() / height())), size,
               paused_);
    node->setRect(boundingRect());
  } catch (const std::exception &e) {
    if (node)
      node->fail();
    const auto message = QString::fromUtf8(e.what());
    QMetaObject::invokeMethod(
        this, [this, message] { reportError(message); }, Qt::QueuedConnection);
    // A failed resize/import may have replaced a native target. Remove the
    // node instead of presenting a wrapper to a possibly retired resource.
    return nullptr;
  }
  // A QSGSimpleTextureNode without a texture must never enter Qt's renderer.
  return node && node->hasTexture() ? node.release() : nullptr;
}
void NativeViewport::mousePressEvent(QMouseEvent *e) {
  if (width() <= 0 || height() <= 0)
    return;
  const auto id =
      office_->pick(static_cast<float>(e->position().x() / width()),
                    static_cast<float>(e->position().y() / height()),
                    static_cast<float>(width() / height()));
  if (!id.empty()) {
    emit agentSelected(QString::fromStdString(id));
    e->accept();
  } else
    e->ignore();
}
} // namespace mokaid

// The generated registrar owns registration exactly once. Keep its translation
// unit when the static bridge library is linked, including dead-strip builds.
void qml_register_types_Mokaid_Native();
void mokaid::registerViewportTypes() {
  volatile auto registration = &qml_register_types_Mokaid_Native;
  Q_UNUSED(registration);
}
