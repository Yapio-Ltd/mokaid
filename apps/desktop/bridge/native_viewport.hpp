#pragma once
#include <QPointF>
#include <QQuickItem>
#include <QTimer>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>
#include <mokaid/engine/office.hpp>
#include "agent_indicator_model.hpp"
#include "custom_avatar_loader.hpp"
#include "office_anchor_model.hpp"
#include "office_screen_content.hpp"

namespace mokaid {
class NativeViewport : public QQuickItem {
  Q_OBJECT
  QML_NAMED_ELEMENT(NativeViewport)
  Q_PROPERTY(QString assetRoot READ assetRoot WRITE setAssetRoot NOTIFY
                 assetRootChanged)
  Q_PROPERTY(
      QVariantList agents READ agents WRITE setAgents NOTIFY agentsChanged)
  Q_PROPERTY(bool paused READ paused WRITE setPaused NOTIFY pausedChanged)
  Q_PROPERTY(
      QString quality READ quality WRITE setQuality NOTIFY qualityChanged)
  Q_PROPERTY(QString error READ error NOTIFY errorChanged)
  Q_PROPERTY(QString avatarError READ avatarError NOTIFY avatarErrorChanged)
  Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
  Q_PROPERTY(QVariantMap diagnostics READ diagnostics NOTIFY diagnosticsChanged)
  Q_PROPERTY(QAbstractItemModel *actorIndicators READ actorIndicators CONSTANT)
  Q_PROPERTY(QAbstractItemModel *tourAnchors READ tourAnchors CONSTANT)
  Q_PROPERTY(QString conversationAgentId READ conversationAgentId WRITE setConversationAgentId NOTIFY conversationAgentIdChanged)
  Q_PROPERTY(bool tourAvailable READ tourAvailable NOTIFY tourStateChanged)
  Q_PROPERTY(bool immersive READ immersive NOTIFY tourStateChanged)
  Q_PROPERTY(bool tourMoving READ tourMoving NOTIFY tourStateChanged)
  Q_PROPERTY(bool tourSettling READ tourSettling NOTIFY tourStateChanged)
  Q_PROPERTY(QString tourCurrentStop READ tourCurrentStop NOTIFY tourStateChanged)
  Q_PROPERTY(QString tourDestination READ tourDestination NOTIFY tourStateChanged)
  Q_PROPERTY(QPointF tourPosition READ tourPosition NOTIFY tourStateChanged)
  Q_PROPERTY(qreal tourYaw READ tourYaw NOTIFY tourStateChanged)
  Q_PROPERTY(qreal tourProgress READ tourProgress NOTIFY tourStateChanged)
  Q_PROPERTY(QVariantList tourStops READ tourStops NOTIFY tourStopsChanged)
  Q_PROPERTY(QVariantList tourEdges READ tourEdges NOTIFY tourEdgesChanged)
  Q_PROPERTY(bool reducedMotion READ reducedMotion WRITE setReducedMotion NOTIFY
                 reducedMotionChanged)
public:
  explicit NativeViewport(QQuickItem *parent = nullptr);
  ~NativeViewport() override;
  QString assetRoot() const { return assetRoot_; }
  void setAssetRoot(const QString &);
  QVariantList agents() const { return agents_; }
  void setAgents(const QVariantList &);
  bool paused() const { return paused_; }
  void setPaused(bool);
  QString quality() const { return quality_; }
  void setQuality(const QString &);
  QString error() const { return error_; }
  QString avatarError() const { return avatarError_; }
  bool loading() const { return loading_; }
  QVariantMap diagnostics() const { return diagnostics_; }
  QAbstractItemModel *actorIndicators() { return &indicators_; }
  QAbstractItemModel *tourAnchors() { return &anchors_; }
  QString conversationAgentId() const { return conversationAgentId_; }
  void setConversationAgentId(const QString &);
  bool tourAvailable() const { return tourAvailable_; }
  bool immersive() const { return immersive_; }
  bool tourMoving() const { return tourMoving_; }
  bool tourSettling() const { return tourSettling_; }
  QString tourCurrentStop() const { return tourCurrentStop_; }
  QString tourDestination() const { return tourDestination_; }
  QPointF tourPosition() const { return tourPosition_; }
  qreal tourYaw() const { return tourYaw_; }
  qreal tourProgress() const { return tourProgress_; }
  QVariantList tourStops() const { return tourStops_; }
  QVariantList tourEdges() const { return tourEdges_; }
  bool reducedMotion() const { return reducedMotion_; }
  void setReducedMotion(bool);
  void reportError(QString);
  void reportDiagnostics(QVariantMap);
  Q_INVOKABLE void retryRenderer();
  Q_INVOKABLE void retryCustomAvatars();
  Q_INVOKABLE bool enterOffice();
  Q_INVOKABLE void leaveOffice();
  Q_INVOKABLE bool travelTo(const QString &stopId);
  Q_INVOKABLE void lookAround(qreal yawDelta, qreal pitchDelta);
  Q_INVOKABLE bool faceCurrentStop();
  Q_INVOKABLE void stopWalking();
signals:
  void assetRootChanged();
  void agentsChanged();
  void pausedChanged();
  void qualityChanged();
  void errorChanged();
  void avatarErrorChanged();
  void loadingChanged();
  void diagnosticsChanged();
  void tourStateChanged();
  void tourStopsChanged();
  void tourEdgesChanged();
  void reducedMotionChanged();
  void conversationAgentIdChanged();
  void navigationInterrupted();
  void agentSelected(QString id);

protected:
  QSGNode *updatePaintNode(QSGNode *, UpdatePaintNodeData *) override;
  void mousePressEvent(QMouseEvent *) override;
  void mouseMoveEvent(QMouseEvent *) override;
  void mouseReleaseEvent(QMouseEvent *) override;
  void mouseUngrabEvent() override;
  void keyPressEvent(QKeyEvent *) override;
  void focusOutEvent(QFocusEvent *) override;

private:
  std::shared_ptr<engine::Office> office_;
  AgentIndicatorModel indicators_{this};
  OfficeAnchorModel anchors_{this};
  OfficeScreenContent screens_;
  QString conversationAgentId_;
  CustomAvatarLoader customAvatars_{this};
  QSet<QString> loadedCustomAvatars_;
  QSet<QString> activeCustomAvatars_;
  QString avatarError_;
  void updateIndicators();
  void updateTourState(bool refreshRoutes = false);
  void resetInput();
  bool selectAgent(const QPointF &position);
  std::jthread loader_;
  QString assetRoot_, quality_{"auto"}, error_;
  QVariantList agents_;
  QVariantMap diagnostics_;
  QVariantList tourStops_, tourEdges_;
  QString tourCurrentStop_, tourDestination_;
  QPointF tourPosition_, pressPosition_, lastPointerPosition_;
  qreal tourYaw_{}, tourProgress_{};
  bool tourAvailable_{}, immersive_{}, tourMoving_{}, tourSettling_{}, reducedMotion_{};
  bool pointerPressed_{}, pointerDragged_{};
  QMetaObject::Connection windowActiveConnection_;
  QTimer timer_;
  int indicatorTick_{};
  bool paused_{}, loading_{};
  std::uint64_t generation_{};
  std::uint64_t rendererGeneration_{};
};
void registerViewportTypes();
} // namespace mokaid
