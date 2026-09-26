#include "office_screen_content.hpp"
#include <QFont>
#include <QFontMetrics>
#include <QImage>
#include <QPainter>
#include <QSet>
#include <algorithm>
#include <cstring>

namespace mokaid {
namespace {
constexpr int tileWidth = 512, tileHeight = 288;
QString clipped(const QVariant& value, int limit = 160) {
  return value.toString().simplified().left(limit);
}
QString statusText(const QString& status) {
  if (status == "in_progress" || status == "running") return "Working";
  if (status == "completed" || status == "ok") return "Completed";
  if (status == "in_review") return "In review";
  if (status == "waiting" || status == "awaiting_approval" || status == "waiting_for_user_input") return "Waiting for you";
  if (status == "blocked" || status == "failed" || status == "error") return "Needs attention";
  if (status == "canceled") return "Canceled";
  if (status == "queued" || status == "to_do") return "Queued";
  return status.isEmpty() ? "At desk" : QString(status).replace('_', ' ');
}
void font(QPainter& painter, int size, QFont::Weight weight = QFont::Normal) {
  QFont f("Manrope"); f.setPixelSize(size); f.setWeight(weight); painter.setFont(f);
}
void line(QPainter& painter, QRect rect, const QString& text, QColor color) {
  painter.setPen(color);
  painter.drawText(rect, Qt::AlignVCenter | Qt::AlignLeft,
    QFontMetrics(painter.font()).elidedText(text, Qt::ElideRight, rect.width()));
}
bool activeWork(const QVariantMap& agent) {
  const auto task = agent.value("screen_task").toMap();
  const auto connection = agent.value("screen_connection").toString();
  const auto status = task.value("status").toString();
  const auto runStatus = task.value("latest_run").toMap().value("status").toString();
  return !agent.value("current_task_id").toString().isEmpty()
    && (connection == "live" || connection == "synced") && status == "in_progress"
    && runStatus != "waiting_for_user_input" && runStatus != "awaiting_approval"
    && runStatus != "failed" && runStatus != "completed" && runStatus != "canceled";
}
QVariantMap displayRecord(const QVariantMap& agent) {
  // Compare only visible fields, avoiding atlas uploads on irrelevant roster updates.
  const auto task = agent.value("screen_task").toMap();
  const auto run = task.value("latest_run").toMap();
  QVariantList events;
  const auto all = run.value("tool_activity").toList();
  for (qsizetype i = std::max(qsizetype{0}, all.size() - 3); i < all.size(); ++i) {
    const auto event = all[i].toMap();
    events.append(QVariantMap{{"description", clipped(event.value("description"))},
      {"tool", clipped(event.value("tool"), 40)}, {"status", event.value("status")}});
  }
  return {{"name", clipped(agent.value("name"), 70)}, {"status", agent.value("status")},
    {"current_task_id", agent.value("current_task_id")}, {"screen_connection", agent.value("screen_connection")},
    {"screen_task", QVariantMap{{"title", clipped(task.value("title"))}, {"status", task.value("status")},
      {"progress_percent", task.value("progress_percent")}, {"latest_run", QVariantMap{
        {"status", run.value("status")}, {"tool_activity", events}}}}}};
}
void paintTile(QPainter& p, const QVariantMap& agent) {
  const QColor white("#e1e9ff"), muted("#92a5c7"), violet("#bc9dff"), mint("#64dcc0");
  p.fillRect(QRect(0, 0, tileWidth, tileHeight), QColor("#0b1525"));
  p.fillRect(QRect(0, 0, tileWidth, 44), QColor("#19243a"));
  font(p, 16, QFont::DemiBold);
  line(p, {20, 7, 322, 30}, agent.isEmpty() ? "MOKAID" : agent.value("name").toString(), white);
  const auto connection = agent.value("screen_connection").toString();
  font(p, 11, QFont::DemiBold);
  const auto connectionLabel = connection == "live" ? "LIVE ACTIVITY" : connection == "synced" ? "SYNCED"
    : connection == "offline" ? "OFFLINE" : connection == "unavailable" ? "UNAVAILABLE" : "SYNCING";
  line(p, {360, 7, 138, 30}, agent.isEmpty() ? "WORKSPACE" : connectionLabel,
    connection == "live" ? mint : muted);
  if (agent.isEmpty() || agent.value("current_task_id").toString().isEmpty()) {
    font(p, 26, QFont::DemiBold);
    line(p, {28, 90, 458, 42}, agent.isEmpty() ? "A place for your next agent" : "Ready for the next mission", white);
    font(p, 15);
    line(p, {28, 137, 458, 32}, agent.isEmpty() ? "Your office, connected." : "No task currently assigned", muted);
    return;
  }
  const auto task = agent.value("screen_task").toMap();
  const auto run = task.value("latest_run").toMap();
  font(p, 20, QFont::DemiBold); p.setPen(white);
  p.drawText(QRect(22, 56, 468, 56), Qt::TextWordWrap | Qt::AlignTop,
    task.value("title").toString().isEmpty()
      ? connection == "unavailable" ? "Current mission unavailable"
        : connection == "offline" ? "Reconnect to view this mission" : "Fetching current mission…"
      : task.value("title").toString());
  font(p, 12, QFont::Medium);
  const auto status = run.value("status").toString();
  line(p, {22, 118, 342, 22}, statusText(status.isEmpty() ? task.value("status").toString() : status), violet);
  bool hasProgress = false;
  const auto rawProgress = task.value("progress_percent").toDouble(&hasProgress);
  const auto progress = std::clamp(rawProgress, 0., 100.);
  if (hasProgress) {
    line(p, {431, 118, 66, 22}, QString::number(qRound(progress)) + "%", white);
    p.fillRect(QRectF(22, 144, 468, 3), QColor("#263550"));
    p.fillRect(QRectF(22, 144, 468 * progress / 100., 3), violet);
  }
  const auto events = run.value("tool_activity").toList();
  if (events.isEmpty()) {
    font(p, 13);
    line(p, {22, 170, 468, 30}, connection == "unavailable" ? "Current activity is unavailable"
      : connection == "offline" ? "Reconnect to update this screen" : "Waiting for reported activity", muted);
  } else {
    for (qsizetype i = 0; i < events.size(); ++i) {
      const auto event = events[i].toMap();
      const int y = 162 + static_cast<int>(i) * 30;
      const auto status = event.value("status").toString();
      p.setPen(Qt::NoPen);
      p.setBrush(status == "running" ? mint : status == "error" ? QColor("#ff9c9e") : muted);
      p.drawEllipse(QRectF(24, y + 10, 5, 5));
      font(p, 12);
      line(p, {39, y, 449, 27}, event.value("description").toString().isEmpty()
        ? event.value("tool").toString() : event.value("description").toString(), white);
    }
  }
  font(p, 10);
  line(p, {22, 263, 470, 16}, connection == "offline" || connection == "reconnecting"
    ? "Connection interrupted · showing last received activity" : "Current mission · reported actions", muted);
}
}
void OfficeScreenContent::sync(const QVariantList& agents) {
  QVariantList next;
  for (int i = 0; i < 9; ++i) next.append(QVariantMap{});
  QSet<int> occupied;
  activity_.fill(0);
  for (const auto& value : agents) {
    const auto agent = value.toMap(); const int seat = agent.value("seat_index", -1).toInt();
    if (seat < 0 || seat >= 9 || occupied.contains(seat) || agent.value("status") == "archived"
        || agent.value("id").toString().isEmpty()) continue;
    occupied.insert(seat); next[seat] = displayRecord(agent);
    activity_[seat] = activeWork(agent) ? 1.F : 0.F;
  }
  if (atlas_ && next == content_) return;
  content_ = next;
  QImage image(tileWidth * 3, tileHeight * 3, QImage::Format_RGBA8888);
  image.fill(Qt::black);
  QPainter painter(&image); painter.setRenderHint(QPainter::Antialiasing);
  painter.setRenderHint(QPainter::TextAntialiasing);
  for (int i = 0; i < 9; ++i) {
    painter.save(); painter.translate((i % 3) * tileWidth, (i / 3) * tileHeight);
    painter.setClipRect(0, 0, tileWidth, tileHeight); paintTile(painter, next[i].toMap()); painter.restore();
  }
  painter.end();
  auto atlas = std::make_shared<engine::Texture>();
  engine::TextureMip mip;
  mip.width = image.width(); mip.height = image.height();
  mip.rgba.resize(static_cast<std::size_t>(image.sizeInBytes()));
  std::memcpy(mip.rgba.data(), image.constBits(), mip.rgba.size());
  atlas->mips.push_back(std::move(mip)); atlas_ = std::move(atlas);
}
void OfficeScreenContent::apply(engine::Frame& frame, bool reducedMotion) const {
  frame.screenAtlas = atlas_;
  frame.screenActivity = activity_;
  if (reducedMotion) frame.screenActivity.fill(0);
}
}
