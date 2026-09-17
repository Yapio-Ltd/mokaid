#pragma once
#include <QAbstractListModel>
#include <QPointF>
#include <QSizeF>
#include <mokaid/engine/scene.hpp>

namespace mokaid {
// A stable model keeps QML labels alive while their projected positions change.
class AgentIndicatorModel final : public QAbstractListModel {
  Q_OBJECT
public:
  enum Role { AgentId = Qt::UserRole + 1, AgentName, AgentLevel, ActivityText,
              ActivityTone, LabelX, LabelY, AnchorX, AnchorY, LabelWidth, OnScreen,
              LabelHeight, ActivityDetail, TetherVisible };
  explicit AgentIndicatorModel(QObject *parent = nullptr) : QAbstractListModel(parent) {}
  int rowCount(const QModelIndex &parent = {}) const override;
  QVariant data(const QModelIndex &, int role) const override;
  QHash<int,QByteArray> roleNames() const override;
  void sync(const engine::Frame &, QSizeF viewport);
  void clear();
  static QString activityText(std::string_view);
  static QString activityDetail(std::string_view);

private:
  struct Row {
    QString id, name, activity, detail, tone;
    int level{};
    QPointF anchor, label, placementAnchor;
    qreal width{96};
    bool visible{}, tether{};
    bool operator==(const Row &) const = default;
  };
  QVector<Row> rows_;
  QSizeF viewport_;
};
} // namespace mokaid
