#include "native_viewport.hpp"
#include <QElapsedTimer>
#include <QGuiApplication>
#include <QThread>
#include <iostream>
#include <stdexcept>

namespace {
void expect(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
}
int main(int argc, char **argv) {
  QGuiApplication app(argc, argv);
  try {
    expect(argc > 1, "Native navigation test requires the cooked asset directory");
    mokaid::NativeViewport viewport;
    int interrupted = 0;
    bool settlingWhenInterrupted = false;
    QObject::connect(&viewport, &mokaid::NativeViewport::navigationInterrupted, [&] {
      ++interrupted;
      settlingWhenInterrupted = viewport.tourSettling();
    });
    viewport.setAssetRoot(QString::fromLocal8Bit(argv[1]));
    QElapsedTimer timeout; timeout.start();
    while (viewport.loading() && timeout.elapsed() < 30000) {
      QCoreApplication::processEvents(); QThread::msleep(5);
    }
    expect(!viewport.loading() && viewport.error().isEmpty(), "Real office assets load without a window or a renderer");
    expect(viewport.enterOffice(), "The visitor can enter the office");
    viewport.lookAround(.8, 0);
    expect(interrupted == 0, "Looking around at rest does not report a canceled approach");
    expect(viewport.faceCurrentStop() && viewport.tourSettling(), "Facing a destination starts a bounded camera settlement");
    viewport.lookAround(.2, 0);
    expect(interrupted == 1 && settlingWhenInterrupted && !viewport.tourSettling(),
        "Manual look cancels pending conversation before QML observes settlement ending");
    viewport.stopWalking();
    expect(interrupted == 1, "An idle stop is not a spurious cancellation");
    expect(viewport.travelTo("south_aisle") && viewport.tourMoving(), "Explicit approach follows the fixed route");
    viewport.lookAround(.1, 0);
    expect(interrupted == 1 && viewport.tourMoving(), "Looking during the walk preserves the intentional route");
    viewport.stopWalking();
    expect(interrupted == 2 && !viewport.tourMoving(), "Stopping a walk cancels an active approach exactly once");
    viewport.stopWalking();
    expect(interrupted == 2, "Repeated focus cleanup cannot duplicate cancellation");
    viewport.leaveOffice(); viewport.enterOffice(); viewport.lookAround(.8, 0);
    expect(viewport.faceCurrentStop() && viewport.tourSettling(), "Another destination-facing request can start after cancellation");
    viewport.stopWalking();
    expect(interrupted == 3 && settlingWhenInterrupted && !viewport.tourSettling(),
        "Loss of focus during the final camera turn cancels instead of opening an off-axis conversation");
    std::cout << "Native navigation cancellation tests passed\n";
    return 0;
  } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 1; }
}
