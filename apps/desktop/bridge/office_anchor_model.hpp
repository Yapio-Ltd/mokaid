#pragma once
#include <QAbstractListModel>
#include <QSizeF>
#include <mokaid/engine/guided_tour.hpp>
#include <mokaid/engine/scene.hpp>

namespace mokaid {
class OfficeAnchorModel final : public QAbstractListModel {
  Q_OBJECT
public:
  explicit OfficeAnchorModel(QObject *parent = nullptr) : QAbstractListModel(parent) {}
  enum Role { StopId = Qt::UserRole + 1, Label, Seat, ScreenX, ScreenY,
              Distance, MarkerScale, OnScreen, Destination };
  int rowCount(const QModelIndex &parent = {}) const override;
  QVariant data(const QModelIndex &, int role) const override;
  QHash<int, QByteArray> roleNames() const override;
  void sync(const engine::Frame &, const std::vector<engine::TourStop> &,
            const std::vector<engine::TourStop> &visibleStops,
            const engine::TourState &, QSizeF);
  void clear();
private:
  struct Row {
    QString id, label;
    int seat{-1};
    qreal x{}, y{}, distance{}, scale{1};
    bool onScreen{}, destination{};
  };
  std::vector<Row> rows_;
};
} // namespace mokaid
