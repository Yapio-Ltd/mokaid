#include "office_anchor_model.hpp"
#include <unordered_set>

namespace mokaid {
int OfficeAnchorModel::rowCount(const QModelIndex &parent) const {
  return parent.isValid() ? 0 : static_cast<int>(rows_.size());
}
QVariant OfficeAnchorModel::data(const QModelIndex &index, int role) const {
  if (!index.isValid() || index.row() < 0 || index.row() >= rowCount()) return {};
  const auto &row = rows_[static_cast<std::size_t>(index.row())];
  switch (role) {
  case StopId: return row.id;
  case Label: return row.label;
  case Seat: return row.seat;
  case ScreenX: return row.x;
  case ScreenY: return row.y;
  case Distance: return row.distance;
  case MarkerScale: return row.scale;
  case OnScreen: return row.onScreen;
  case Destination: return row.destination;
  default: return {};
  }
}
QHash<int, QByteArray> OfficeAnchorModel::roleNames() const {
  return {{StopId,"stopId"},{Label,"stopLabel"},{Seat,"seatIndex"},
          {ScreenX,"screenX"},{ScreenY,"screenY"},{Distance,"distance"},
          {MarkerScale,"markerScale"},{OnScreen,"onScreen"},{Destination,"destination"}};
}
void OfficeAnchorModel::clear() {
  if (rows_.empty()) return;
  beginResetModel(); rows_.clear(); endResetModel();
}
void OfficeAnchorModel::sync(const engine::Frame &frame,
    const std::vector<engine::TourStop> &stops,
    const std::vector<engine::TourStop> &visibleStops,
    const engine::TourState &visitor, QSizeF size) {
  if (size.width() <= 0 || size.height() <= 0 || stops.empty()) { clear(); return; }
  std::unordered_set<std::string> visible;
  for (const auto &stop : visibleStops) visible.insert(stop.id);
  std::vector<Row> next;
  next.reserve(stops.size());
  for (const auto &stop : stops) {
    Row row;
    row.id = QString::fromStdString(stop.id);
    row.label = QString::fromStdString(stop.label);
    row.seat = stop.seat;
    const auto point = stop.position + engine::Vec3{0, .065F, 0};
    const auto projected = engine::transform(frame.viewProjection, {point.x, point.y, point.z, 1});
    row.distance = engine::length(frame.camera - point);
    row.scale = visitor.active ? std::clamp(5.0 / std::max(1.0, row.distance), .65, 1.12) : .78;
    row.destination = visitor.active && visitor.moving && visitor.destination == stop.id;
    if (projected.w > .05F && projected.z >= 0 && projected.z <= projected.w) {
      row.x = (.5 + .5 * projected.x / projected.w) * size.width();
      row.y = (.5 - .5 * projected.y / projected.w) * size.height();
      row.onScreen = visible.contains(stop.id) && row.x >= 24 && row.x <= size.width() - 24 &&
          row.y >= 24 && row.y <= size.height() - 24;
    }
    next.push_back(row);
  }
  const bool reset = next.size() != rows_.size() ||
      !std::equal(next.begin(), next.end(), rows_.begin(), [](const auto &a, const auto &b) { return a.id == b.id; });
  if (reset) { beginResetModel(); rows_ = std::move(next); endResetModel(); return; }
  for (std::size_t i = 0; i < next.size(); ++i) {
    const auto &a = rows_[i], &b = next[i];
    if (a.x == b.x && a.y == b.y && a.distance == b.distance && a.scale == b.scale &&
        a.onScreen == b.onScreen && a.destination == b.destination && a.label == b.label) continue;
    rows_[i] = b;
    emit dataChanged(index(static_cast<int>(i)), index(static_cast<int>(i)));
  }
}
} // namespace mokaid
