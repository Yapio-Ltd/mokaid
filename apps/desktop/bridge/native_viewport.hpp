#pragma once
#include <QQuickItem>
#include <QTimer>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>
#include <mokaid/engine/office.hpp>
#include "agent_indicator_model.hpp"

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
  Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)
  Q_PROPERTY(QVariantMap diagnostics READ diagnostics NOTIFY diagnosticsChanged)
  Q_PROPERTY(QAbstractItemModel *actorIndicators READ actorIndicators CONSTANT)
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
  bool loading() const { return loading_; }
  QVariantMap diagnostics() const { return diagnostics_; }
  QAbstractItemModel *actorIndicators() { return &indicators_; }
  void reportError(QString);
  void reportDiagnostics(QVariantMap);
  Q_INVOKABLE void retryRenderer();
signals:
  void assetRootChanged();
  void agentsChanged();
  void pausedChanged();
  void qualityChanged();
  void errorChanged();
  void loadingChanged();
  void diagnosticsChanged();
  void agentSelected(QString id);

protected:
  QSGNode *updatePaintNode(QSGNode *, UpdatePaintNodeData *) override;
  void mousePressEvent(QMouseEvent *) override;

private:
  std::shared_ptr<engine::Office> office_;
  AgentIndicatorModel indicators_{this};
  void updateIndicators();
  std::jthread loader_;
  QString assetRoot_, quality_{"auto"}, error_;
  QVariantList agents_;
  QVariantMap diagnostics_;
  QTimer timer_;
  int indicatorTick_{};
  bool paused_{}, loading_{};
  std::uint64_t generation_{};
  std::uint64_t rendererGeneration_{};
};
void registerViewportTypes();
} // namespace mokaid
