#include "office_anchor_model.hpp"
#include <QCoreApplication>
#include <iostream>
#include <stdexcept>

using namespace mokaid;
using namespace mokaid::engine;
namespace {
void expect(bool value, const char *message) { if (!value) throw std::runtime_error(message); }
}
int main(int argc, char **argv) {
  QCoreApplication app(argc, argv);
  try {
    OfficeAnchorModel model;
    Frame frame;
    frame.camera = {0, 1.62F, 0};
    frame.viewProjection = perspective(1.12F, 1.5F, .055F, 100.F) * lookAt(frame.camera, {0, 0, -4});
    const std::vector<TourStop> stops{
      {"front", "Front desk", 0, {0, 0, -4}, {}},
      {"behind", "Behind", -1, {0, 0, 4}, {}},
      {"hidden", "Occluded", -1, {1, 0, -4}, {}}
    };
    TourState visitor; visitor.active = true; visitor.moving = true; visitor.destination = "front";
    int resets = 0;
    QObject::connect(&model, &QAbstractItemModel::modelReset, [&] { ++resets; });
    model.sync(frame, stops, {stops[0], stops[1]}, visitor, {900, 600});
    expect(model.rowCount() == 3 && resets == 1, "Anchor identities are created once");
    const auto front = model.index(0);
    expect(model.data(front, OfficeAnchorModel::OnScreen).toBool(), "Visible floor stop is projected into the scene");
    expect(std::abs(model.data(front, OfficeAnchorModel::ScreenX).toDouble() - 450) < .01,
        "Floor anchor uses the same camera as the rendered office");
    expect(model.data(front, OfficeAnchorModel::Destination).toBool(), "The selected route has a persistent visual state");
    expect(!model.data(model.index(1), OfficeAnchorModel::OnScreen).toBool(), "Stops behind the camera cannot intercept clicks");
    expect(!model.data(model.index(2), OfficeAnchorModel::OnScreen).toBool(), "Occluded stops are hidden instead of drawn over furniture");
    frame.viewProjection = perspective(1.12F, 1.5F, .055F, 100.F) * lookAt(frame.camera, {.1F, 0, -4});
    model.sync(frame, stops, {stops[0]}, visitor, {900, 600});
    expect(resets == 1, "Camera motion updates roles without recreating a pressed or focused button");
    model.clear(); expect(model.rowCount() == 0, "Loading and renderer failure remove stale navigation targets");
    std::cout << "Office anchor projection tests passed\n";
    return 0;
  } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 1; }
}
