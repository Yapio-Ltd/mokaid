#include <mokaid/presentation/frame_profiler.hpp>
#include <QQuickWindow>
#include <QThread>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <mutex>
#include <numeric>
#include <stdexcept>
#include <vector>

namespace mokaid::desktop {
FrameIntervalSummary summarizeFrameTimestamps(
    std::span<const FrameClock::time_point> timestamps) {
  FrameIntervalSummary result;
  if (timestamps.size() < 2)
    return result;
  std::vector<double> intervals;
  intervals.reserve(timestamps.size() - 1);
  for (std::size_t index = 1; index < timestamps.size(); ++index) {
    if (timestamps[index] < timestamps[index - 1])
      throw std::invalid_argument("Frame timestamps must be chronological");
    intervals.push_back(std::chrono::duration<double, std::milli>(
                            timestamps[index] - timestamps[index - 1]).count());
  }
  result.sampleCount = intervals.size();
  result.windowSeconds = std::chrono::duration<double>(
                             timestamps.back() - timestamps.front()).count();
  result.meanMs = std::accumulate(intervals.begin(), intervals.end(), 0.0) /
                  static_cast<double>(intervals.size());
  std::sort(intervals.begin(), intervals.end());
  result.maxMs = intervals.back();
  const auto percentile = [&intervals](double quantile) {
    const auto rank = static_cast<std::size_t>(
        std::ceil(quantile * static_cast<double>(intervals.size())));
    return intervals[std::max(std::size_t{1}, rank) - 1];
  };
  result.p50Ms = percentile(.50);
  result.p95Ms = percentile(.95);
  result.p99Ms = percentile(.99);
  return result;
}

struct FrameProfiler::State {
  std::mutex mutex;
  std::array<FrameClock::time_point, frameTimestampCapacity> timestamps{};
  std::size_t next{}, count{};
  std::uint64_t generation{};
  bool attached{};
};
struct FrameProfiler::Connections {
  QMetaObject::Connection frame, destroyed;
  void clear() {
    QObject::disconnect(frame);
    QObject::disconnect(destroyed);
    frame = {};
    destroyed = {};
  }
  ~Connections() { clear(); }
};
namespace {
QVariantMap toMetrics(const FrameIntervalSummary &summary, bool attached,
                     double lastFrameAgeSeconds) {
  return {{QStringLiteral("measurement"), QStringLiteral("presentationIntervals")},
          {QStringLiteral("sampleCount"), QVariant::fromValue<qulonglong>(summary.sampleCount)},
          {QStringLiteral("maxMs"), summary.maxMs},
          {QStringLiteral("meanMs"), summary.meanMs},
          {QStringLiteral("p50Ms"), summary.p50Ms},
          {QStringLiteral("p95Ms"), summary.p95Ms},
          {QStringLiteral("p99Ms"), summary.p99Ms},
          {QStringLiteral("windowSeconds"), summary.windowSeconds},
          {QStringLiteral("lastFrameAgeSeconds"), lastFrameAgeSeconds},
          {QStringLiteral("attached"), attached}};
}
} // namespace

FrameProfiler::FrameProfiler(QObject *parent)
    : QObject(parent), state_(std::make_shared<State>()),
      connections_(std::make_unique<Connections>()), publishTimer_(this),
      metrics_(toMetrics({}, false, 0)) {
  publishTimer_.setInterval(500);
  // PreciseTimer does not fire early, preserving the two-publications/s cap.
  publishTimer_.setTimerType(Qt::PreciseTimer);
  connect(&publishTimer_, &QTimer::timeout, this, &FrameProfiler::publish);
  publishTimer_.start();
}
FrameProfiler::~FrameProfiler() {
  publishTimer_.stop();
  connections_->clear();
  // A direct frame callback may already be executing on the render thread.
  // It owns only shared State, never this QObject or the QQuickWindow.
  std::lock_guard lock(state_->mutex);
  state_->attached = false;
  ++state_->generation;
}
void FrameProfiler::attach(QQuickWindow *window) {
  Q_ASSERT(QThread::currentThread() == thread());
  Q_ASSERT(!window || window->thread() == thread());
  if (window && window_ == window)
    return;
  connections_->clear();
  window_ = window;
  std::uint64_t generation;
  {
    std::lock_guard lock(state_->mutex);
    generation = ++state_->generation;
    state_->attached = window != nullptr;
    if (window) {
      state_->count = 0;
      state_->next = 0;
    }
  }
  if (!window)
    return;
  const auto state = state_;
  connections_->frame = connect(
      window, &QQuickWindow::frameSwapped, this,
      [state, generation] {
        std::lock_guard lock(state->mutex);
        if (!state->attached || state->generation != generation)
          return;
        // Taken on the emitting thread, not after GUI event-queue latency.
        // Reading under this short lock also preserves chronological order.
        state->timestamps[state->next] = FrameClock::now();
        state->next = (state->next + 1) % frameTimestampCapacity;
        state->count = std::min(state->count + 1, frameTimestampCapacity);
      }, Qt::DirectConnection);
  connections_->destroyed = connect(
      window, &QObject::destroyed, this,
      [this, generation] {
        {
          std::lock_guard lock(state_->mutex);
          if (state_->generation != generation)
            return;
          state_->attached = false;
          ++state_->generation;
        }
        window_.clear();
        connections_->clear();
      }, Qt::QueuedConnection);
}
void FrameProfiler::reset() {
  Q_ASSERT(QThread::currentThread() == thread());
  std::lock_guard lock(state_->mutex);
  state_->count = 0;
  state_->next = 0;
}
void FrameProfiler::publish() {
  Q_ASSERT(QThread::currentThread() == thread());
  const auto now = FrameClock::now();
  if (lastPublished_ != FrameClock::time_point{} &&
      now - lastPublished_ < std::chrono::milliseconds(500))
    return;
  std::array<FrameClock::time_point, frameTimestampCapacity> ordered{};
  std::size_t count;
  bool attached;
  {
    std::lock_guard lock(state_->mutex);
    count = state_->count;
    attached = state_->attached;
    const auto first = (state_->next + frameTimestampCapacity - count) %
                       frameTimestampCapacity;
    for (std::size_t index = 0; index < count; ++index)
      ordered[index] = state_->timestamps[(first + index) % frameTimestampCapacity];
  }
  const auto timestamps = std::span<const FrameClock::time_point>(ordered).first(count);
  const double age = count ? std::chrono::duration<double>(
                                FrameClock::now() - timestamps.back()).count() : 0;
  const auto next = toMetrics(summarizeFrameTimestamps(timestamps), attached, age);
  if (metrics_ != next) {
    metrics_ = next;
    lastPublished_ = now;
    emit metricsChanged();
  }
}
} // namespace mokaid::desktop
