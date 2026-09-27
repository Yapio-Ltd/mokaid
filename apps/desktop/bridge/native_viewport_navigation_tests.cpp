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
    // Blocked fixture URLs exercise reload decisions without contacting a
    // server. Real cached-decode/revision races are covered by loader tests.
    auto *characters = viewport.findChild<mokaid::CustomAvatarLoader *>();
    expect(characters != nullptr, "Viewport owns a custom character loader");
    const QString key = "custom:revised-character";
    const QUrl original("fixture:///original/model.mokaidasset"), revised("fixture:///revised/model.mokaidasset");
    QVariantMap agent{{"id","fixture-agent"},{"name","Fixture character"},{"asset_type",key},
                      {"seat_index",0},{"status","idle"},{"avatar_native_cdn_path",original.toString()}};
    viewport.setAgents({agent});
    expect(!viewport.avatarError().isEmpty(), "Initial character URL is checked");
    const auto scene = mokaid::engine::loadScene(std::filesystem::path(argv[1]) / "avatar_male.mokaidasset");
    characters->ready(key, original, scene);
    expect(viewport.avatarError().isEmpty(), "Current completed revision becomes the loaded character");
    agent.insert("avatar_native_cdn_path", revised.toString()); viewport.setAgents({agent});
    expect(!viewport.avatarError().isEmpty(), "A new URL reloads an already loaded stable asset ID");
    characters->ready(key, original, scene);
    expect(!viewport.avatarError().isEmpty(), "An obsolete completion cannot replace the new revision");
    characters->ready(key, revised, scene);
    expect(viewport.avatarError().isEmpty(), "The new revision replaces the old one");
    characters->failed(key, original, "Obsolete request failed");
    expect(viewport.avatarError().isEmpty(), "An obsolete failure cannot obscure a successful revision");
    viewport.setAgents({agent});
    expect(viewport.avatarError().isEmpty(), "Unchanged revision is not loaded repeatedly");
    std::cout << "Native navigation cancellation and custom revision tests passed\n";
    return 0;
  } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 1; }
}
