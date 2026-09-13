#include <mokaid/presentation/frame_profiler.hpp>
#include <QtTest>
#include <array>
#include <stdexcept>
#include <vector>

using namespace mokaid::desktop;
using namespace std::chrono_literals;

class FrameProfilerTests : public QObject {
  Q_OBJECT
private slots:
  void emptyAndSingleTimestamp() {
    QCOMPARE(summarizeFrameTimestamps({}).sampleCount, std::size_t{0});
    const std::array one{FrameClock::time_point{}};
    const auto result = summarizeFrameTimestamps(one);
    QCOMPARE(result.sampleCount, std::size_t{0});
    QCOMPARE(result.meanMs, 0.0);
    QCOMPARE(result.windowSeconds, 0.0);
  }
  void exactNearestRankPercentiles() {
    std::vector<FrameClock::time_point> timestamps(1);
    for (int interval = 1; interval <= 100; ++interval)
      timestamps.push_back(timestamps.back() + std::chrono::milliseconds(interval));
    const auto result = summarizeFrameTimestamps(timestamps);
    QCOMPARE(result.sampleCount, std::size_t{100});
    QCOMPARE(result.p50Ms, 50.0);
    QCOMPARE(result.p95Ms, 95.0);
    QCOMPARE(result.p99Ms, 99.0);
    QCOMPARE(result.maxMs, 100.0);
    QCOMPARE(result.meanMs, 50.5);
    QCOMPARE(result.windowSeconds, 5.05);
  }
  void stallsAndDuplicateTimesAreNotDiscarded() {
    const auto origin = FrameClock::time_point{};
    const std::array timestamps{origin, origin, origin + 16ms, origin + 60s + 16ms};
    const auto result = summarizeFrameTimestamps(timestamps);
    QCOMPARE(result.sampleCount, std::size_t{3});
    QCOMPARE(result.p50Ms, 16.0);
    QCOMPARE(result.maxMs, 60000.0);
    QCOMPARE(result.p99Ms, 60000.0);
    QCOMPARE(result.windowSeconds, 60.016);
  }
  void boundedWindowHas599Intervals() {
    std::array<FrameClock::time_point, frameTimestampCapacity> timestamps{};
    for (std::size_t index = 1; index < timestamps.size(); ++index)
      timestamps[index] = timestamps[index - 1] + 8ms;
    const auto result = summarizeFrameTimestamps(timestamps);
    QCOMPARE(result.sampleCount, frameTimestampCapacity - 1);
    QCOMPARE(result.maxMs, 8.0);
    QCOMPARE(result.p95Ms, 8.0);
  }
  void unorderedInputIsNotMisreportedAsAFrameTime() {
    const auto origin = FrameClock::time_point{};
    const std::array timestamps{origin + 1s, origin};
    QVERIFY_THROWS_EXCEPTION(std::invalid_argument, summarizeFrameTimestamps(timestamps));
  }
};
QTEST_APPLESS_MAIN(FrameProfilerTests)
#include "frame_profiler_tests.moc"
