#include "native_viewport.hpp"
#include <QCoreApplication>
#include <QDir>
#include <QFocusEvent>
#include <QGuiApplication>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QPointer>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSGSimpleTextureNode>
#include <QSGTexture>
#include <QStyleHints>
#include <QtQml>
#include <cmath>
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
      updateTourState();
      if(++indicatorTick_%2==0) updateIndicators();
      update();
    }
  });
  connect(this,&QQuickItem::widthChanged,this,&NativeViewport::updateIndicators);
  connect(this,&QQuickItem::heightChanged,this,&NativeViewport::updateIndicators);
  connect(this, &QQuickItem::visibleChanged, this, [this] {
    if (!isVisible())
      stopWalking();
  });
  connect(this, &QQuickItem::windowChanged, this, [this](QQuickWindow *w) {
    disconnect(windowActiveConnection_);
    stopWalking();
    if (w)
      windowActiveConnection_ = connect(w, &QWindow::activeChanged, this, [this, w] {
        if (!w->isActive())
          stopWalking();
      });
  });
  timer_.start();
}
void NativeViewport::updateTourState(bool refreshRoutes) {
  // Office owns the simulation clock. Read its completed tour state here;
  // advancing it from the GUI timer would double the walking speed.
  const auto state = office_->tourState();
  const bool available = state.available && !loading_ && error_.isEmpty();
  const bool active = available && state.active;
  const bool moving = active && state.moving;
  const bool settling = active && state.settling;
  const auto current = QString::fromStdString(state.currentStop);
  const auto destination = QString::fromStdString(state.destination);
  const QPointF position(state.position.x, state.position.z);
  if (tourAvailable_ != available || immersive_ != active ||
      tourMoving_ != moving || tourSettling_ != settling || tourCurrentStop_ != current ||
      tourDestination_ != destination || tourPosition_ != position ||
      tourYaw_ != state.yaw || tourProgress_ != state.progress) {
    const bool changedMode = immersive_ != active;
    tourAvailable_ = available;
    immersive_ = active;
    tourMoving_ = moving;
    tourSettling_ = settling;
    tourCurrentStop_ = current;
    tourDestination_ = destination;
    tourPosition_ = position;
    tourYaw_ = state.yaw;
    tourProgress_ = state.progress;
    if (changedMode)
      resetInput();
    emit tourStateChanged();
  }
  if (!refreshRoutes)
    return;
  QVariantList stops, edges;
  if (available) {
    for (const auto &stop : office_->tourStops())
      stops.append(QVariantMap{{"id", QString::fromStdString(stop.id)},
                               {"label", QString::fromStdString(stop.label)},
                               {"seat", stop.seat},
                               {"x", stop.position.x},
                               {"z", stop.position.z}});
    for (const auto &edge : office_->tourEdges()) {
      QVariantList points;
      for (const auto &point : edge.points)
        points.append(QVariantMap{{"x", point.x}, {"z", point.z}});
      edges.append(QVariantMap{{"from", QString::fromStdString(edge.from)},
                               {"to", QString::fromStdString(edge.to)},
                               {"points", points}});
    }
  }
  if (tourStops_ != stops) {
    tourStops_ = std::move(stops);
    emit tourStopsChanged();
  }
  if (tourEdges_ != edges) {
    tourEdges_ = std::move(edges);
    emit tourEdgesChanged();
  }
}
void NativeViewport::updateIndicators() {
  if(loading_||!error_.isEmpty()||width()<1||height()<1){indicators_.clear();anchors_.clear();return;}
  const auto frame = office_->snapshot(static_cast<float>(width()/height()));
  indicators_.sync(*frame,QSizeF(width(),height()));
  anchors_.sync(*frame, office_->tourStops(), office_->visibleTourStops(), office_->tourState(), QSizeF(width(), height()));
}
void NativeViewport::setConversationAgentId(const QString &id) {
  if (conversationAgentId_ == id) return;
  conversationAgentId_ = id;
  office_->setConversationAgent(id.toStdString());
  emit conversationAgentIdChanged();
}
NativeViewport::~NativeViewport() {
  loader_.request_stop();
  if (loader_.joinable())
    loader_.join();
}
void NativeViewport::setAssetRoot(const QString &path) {
  if (assetRoot_ == path)
    return;
  leaveOffice();
  customAvatars_.reset();
  loadedCustomAvatars_.clear();
  assetRoot_ = path;
  emit assetRootChanged();
  loading_ = true;
  indicators_.clear();
  error_.clear();
  emit loadingChanged();
  emit errorChanged();
  updateTourState(true);
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
                guard->updateTourState(true);
                guard->update();
              },
              Qt::QueuedConnection);
      });
}
void NativeViewport::setAgents(const QVariantList &list) {
  agents_ = list;
  screens_.sync(list);
  QSet<QString> activeCustom;
  QSet<int> occupiedSeats;
  std::vector<engine::Agent> agents;
  agents.reserve(static_cast<std::size_t>(list.size()));
  for (const auto &v : list) {
    auto m = v.toMap();
    const auto status = m.value("status").toString().toStdString();
    if (status == "archived") continue;
    const auto seat = m.value("seat_index", -1).toInt();
    if (m.value("id").toString().isEmpty() || seat < 0 || seat >= 9 || occupiedSeats.contains(seat)) continue;
    occupiedSeats.insert(seat);
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
  office_->setConversationAgent(conversationAgentId_.toStdString());
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
  if (paused_)
    stopWalking();
  office_->setPaused(v);
  emit pausedChanged();
  update();
}
void NativeViewport::setReducedMotion(bool v) {
  if (reducedMotion_ == v)
    return;
  reducedMotion_ = v;
  office_->setTourReducedMotion(v);
  emit reducedMotionChanged();
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
  office_->exitTour();
  resetInput();
  indicators_.clear();
  emit errorChanged();
  updateTourState(true);
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
  updateTourState(true);
  update();
}
bool NativeViewport::enterOffice() {
  if (loading_ || paused_ || !error_.isEmpty() || !office_->enterTour())
    return false;
  updateTourState();
  forceActiveFocus(Qt::OtherFocusReason);
  updateIndicators();
  update();
  return true;
}
void NativeViewport::leaveOffice() {
  office_->exitTour();
  resetInput();
  updateTourState();
  updateIndicators();
  update();
}
bool NativeViewport::travelTo(const QString &stopId) {
  if (!immersive_ || loading_ || paused_ || !error_.isEmpty())
    return false;
  // Complete the control-to-scene focus handoff before starting movement, so
  // focus cleanup from the previous control cannot cancel the new route.
  forceActiveFocus(Qt::OtherFocusReason);
  if (!office_->travelTourTo(stopId.toStdString()))
    return false;
  updateTourState();
  update();
  return true;
}
void NativeViewport::lookAround(qreal yawDelta, qreal pitchDelta) {
  if (!immersive_ || loading_ || paused_ || !error_.isEmpty() ||
      !std::isfinite(yawDelta) || !std::isfinite(pitchDelta))
    return;
  const auto before = office_->tourState();
  if (!before.moving && before.settling)
    emit navigationInterrupted();
  office_->lookTour(static_cast<float>(yawDelta), static_cast<float>(pitchDelta));
  updateTourState();
  updateIndicators();
  update();
}
void NativeViewport::stopWalking() {
  const auto before = office_->tourState();
  if (before.active && (before.moving || before.settling))
    emit navigationInterrupted();
  office_->stopTour();
  resetInput();
  updateTourState();
  update();
}
bool NativeViewport::faceCurrentStop() {
  if (!immersive_ || loading_ || paused_ || !error_.isEmpty() || !office_->faceCurrentTourStop())
    return false;
  updateTourState(); updateIndicators(); update();
  return true;
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
    // Eye-level conversations expose facial detail. Auto uses native pixel
    // density there while retaining the cheaper overview and explicit low mode.
    const qreal scale = quality_ == "low" ? .65 : quality_ == "high" || immersive_ ? 1. : .85;
    const qreal dpr = window()->effectiveDevicePixelRatio();
    const QSize size(qBound(1, qRound(width() * dpr * scale), 3840),
                     qBound(1, qRound(height() * dpr * scale), 2160));
    auto displayFrame = std::make_shared<engine::Frame>(*office_->snapshot(static_cast<float>(width() / height())));
    screens_.apply(*displayFrame, reducedMotion_);
    node->sync(displayFrame, size, paused_);
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
bool NativeViewport::selectAgent(const QPointF &position) {
  if (loading_ || paused_ || !error_.isEmpty() || width() <= 0 || height() <= 0)
    return false;
  const auto id =
      office_->pick(static_cast<float>(position.x() / width()),
                    static_cast<float>(position.y() / height()),
                    static_cast<float>(width() / height()));
  if (!id.empty()) {
    if (immersive_)
      stopWalking();
    emit agentSelected(QString::fromStdString(id));
    return true;
  }
  return false;
}
void NativeViewport::resetInput() {
  pointerPressed_ = false;
  pointerDragged_ = false;
  setKeepMouseGrab(false);
  if (immersive_)
    setCursor(Qt::OpenHandCursor);
  else
    unsetCursor();
}
void NativeViewport::mousePressEvent(QMouseEvent *e) {
  if (loading_ || paused_ || !error_.isEmpty() || width() <= 0 || height() <= 0) {
    e->ignore();
    return;
  }
  if (immersive_) {
    forceActiveFocus(Qt::MouseFocusReason);
    pressPosition_ = lastPointerPosition_ = e->position();
    pointerPressed_ = true;
    pointerDragged_ = false;
    setKeepMouseGrab(true);
    setCursor(Qt::ClosedHandCursor);
    e->accept();
  } else if (selectAgent(e->position())) {
    e->accept();
  } else
    e->ignore();
}
void NativeViewport::mouseMoveEvent(QMouseEvent *e) {
  if (!immersive_ || !pointerPressed_) {
    e->ignore();
    return;
  }
  if (!pointerDragged_ &&
      (e->position() - pressPosition_).manhattanLength() >=
          QGuiApplication::styleHints()->startDragDistance())
    pointerDragged_ = true;
  if (pointerDragged_) {
    const auto delta = e->position() - lastPointerPosition_;
    lookAround(delta.x() * .006, -delta.y() * .006);
  }
  lastPointerPosition_ = e->position();
  e->accept();
}
void NativeViewport::mouseReleaseEvent(QMouseEvent *e) {
  if (!pointerPressed_) {
    e->ignore();
    return;
  }
  const bool clicked = !pointerDragged_ && boundingRect().contains(e->position());
  resetInput();
  if (clicked)
    selectAgent(e->position());
  e->accept();
}
void NativeViewport::mouseUngrabEvent() {
  resetInput();
  QQuickItem::mouseUngrabEvent();
}
void NativeViewport::keyPressEvent(QKeyEvent *e) {
  if (!immersive_ || loading_ || paused_ || !error_.isEmpty()) {
    QQuickItem::keyPressEvent(e);
    return;
  }
  constexpr qreal step = .10;
  switch (e->key()) {
  case Qt::Key_Escape:
    leaveOffice();
    break;
  case Qt::Key_Left:
    lookAround(-step, 0);
    break;
  case Qt::Key_Right:
    lookAround(step, 0);
    break;
  case Qt::Key_Up:
    lookAround(0, step);
    break;
  case Qt::Key_Down:
    lookAround(0, -step);
    break;
  default:
    QQuickItem::keyPressEvent(e);
    return;
  }
  e->accept();
}
void NativeViewport::focusOutEvent(QFocusEvent *e) {
  stopWalking();
  QQuickItem::focusOutEvent(e);
}
} // namespace mokaid

// The generated registrar owns registration exactly once. Keep its translation
// unit when the static bridge library is linked, including dead-strip builds.
void qml_register_types_Mokaid_Native();
void mokaid::registerViewportTypes() {
  volatile auto registration = &qml_register_types_Mokaid_Native;
  Q_UNUSED(registration);
}
