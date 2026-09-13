#pragma once

#include <QObject>
#include <QPointer>
#include <QTimer>
#include <QVariantMap>
#include <chrono>
#include <cstddef>
#include <memory>
#include <span>

class QQuickWindow;

namespace mokaid::desktop {
using FrameClock = std::chrono::steady_clock;
inline constexpr std::size_t frameTimestampCapacity = 600;

struct FrameIntervalSummary {
  std::size_t sampleCount{};
  double maxMs{}, meanMs{}, p50Ms{}, p95Ms{}, p99Ms{}, windowSeconds{};
};

// Pure calculation over chronological emission timestamps. Percentiles use
// nearest rank. Zero intervals and long stalls are retained; unordered input
// is an error rather than silently dropping samples. No window/GPU is involved.
FrameIntervalSummary summarizeFrameTimestamps(
    std::span<const FrameClock::time_point> timestamps);

class FrameProfiler final : public QObject {
  Q_OBJECT
  Q_PROPERTY(QVariantMap metrics READ metrics NOTIFY metricsChanged)

public:
  explicit FrameProfiler(QObject *parent = nullptr);
  ~FrameProfiler() override;
  // GUI-thread methods. A new window starts a fresh ring; nullptr detaches and
  // retains the last statistics. Reset is visible on the next <=2 Hz publish.
  void attach(QQuickWindow *window);
  QVariantMap metrics() const { return metrics_; }
  Q_INVOKABLE void reset();

signals:
  void metricsChanged();

private:
  struct State;
  struct Connections;
  void publish();
  std::shared_ptr<State> state_;
  std::unique_ptr<Connections> connections_;
  QPointer<QQuickWindow> window_;
  QTimer publishTimer_;
  QVariantMap metrics_;
  FrameClock::time_point lastPublished_{};
};
} // namespace mokaid::desktop
