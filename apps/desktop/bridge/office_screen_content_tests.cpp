#include "office_screen_content.hpp"
#include <mokaid/engine/office_screens.hpp>
#include <mokaid/engine/surrounding_offices.hpp>
#include <QFontDatabase>
#include <QGuiApplication>
#include <QImage>
#include <cassert>
#include <iostream>
#include <set>

int main(int argc, char** argv) {
  QGuiApplication app(argc, argv);
  QFontDatabase::addApplicationFont(QStringLiteral(MOKAID_SCREEN_FONT));
  mokaid::OfficeScreenContent content;
  mokaid::engine::Frame frame;
  content.sync({}); content.apply(frame, false);
  assert(frame.screenAtlas && frame.screenAtlas->mips.size() == 1);
  assert(frame.screenAtlas->mips[0].width == 1536 && frame.screenAtlas->mips[0].height == 864);
  auto empty = frame.screenAtlas;
  QVariantMap task{{"id", "mission-a"}, {"title", "Validate the launch page"}, {"status", "in_progress"},
    {"progress_percent", 37}, {"latest_run", QVariantMap{{"status", "running"}, {"tool_activity", QVariantList{
      QVariantMap{{"description", "Reading the actual project brief"}, {"tool", "read_file"}, {"status", "ok"}},
      QVariantMap{{"description", "Checking the mobile layout"}, {"tool", "browser"}, {"status", "running"}}}}}}};
  QVariantMap agent{{"id", "agent-a"}, {"name", "Alice"}, {"seat_index", 0}, {"status", "busy"},
    {"current_task_id", "mission-a"}, {"screen_task", task}, {"screen_connection", "live"}};
  content.sync({agent}); content.apply(frame, false);
  assert(frame.screenAtlas != empty && frame.screenActivity[0] == 1);
  const auto first = frame.screenAtlas;
  agent["level"] = 42; content.sync({agent}); content.apply(frame, false);
  assert(frame.screenAtlas == first); // Unrelated roster updates never upload another texture.
  content.apply(frame, true); assert(frame.screenActivity[0] == 0);
  content.apply(frame, false); assert(frame.screenActivity[0] == 1);
  agent["screen_connection"] = "offline";
  content.sync({agent}); content.apply(frame, false);
  assert(frame.screenAtlas != first && frame.screenActivity[0] == 0);
  agent["screen_connection"] = "live"; agent["seat_index"] = 8;
  content.sync({agent}); content.apply(frame, false);
  assert(frame.screenActivity[0] == 0 && frame.screenActivity[8] == 1);
  if (const auto output = qEnvironmentVariable("MOKAID_SCREEN_ATLAS_CAPTURE"); !output.isEmpty()) {
    const auto& mip = frame.screenAtlas->mips[0];
    QImage image(mip.rgba.data(), mip.width, mip.height, QImage::Format_RGBA8888);
    assert(image.save(output));
  }
  content.sync({}); content.apply(frame, false);
  assert(frame.screenActivity[8] == 0 && frame.screenAtlas->mips[0].rgba == empty->mips[0].rgba);
  if (argc > 1) {
    const auto scene = mokaid::engine::loadScene(std::filesystem::path(argv[1]) / "office.mokaidasset");
    const auto pose = mokaid::engine::evaluatePose(*scene, "", 0);
    const auto world = mokaid::engine::trs({}, {0, 1, 0, 0});
    std::set<int> seats;
    int unassigned = 0;
    for (const auto& mesh : scene->meshes) {
      if (scene->materials[mesh.material].surfaceKind != 1) continue;
      const auto seat = mokaid::engine::officeScreenSeat(mesh, world * pose.world[mesh.node]);
      if (seat < 0) { ++unassigned; continue; }
      assert(seat < 9); seats.insert(seat);
    }
    assert(unassigned == 1); // The source includes a spare monitor at an unoccupied station.
    const auto additions = mokaid::engine::makeSurroundingOffices(*scene);
    for (const auto& mesh : additions->meshes) {
      if (additions->materials[mesh.material].surfaceKind != 1) continue;
      const auto seat = mokaid::engine::officeScreenSeat(mesh, mokaid::engine::Mat4::identity());
      assert(seat == 4 || seat == 5); seats.insert(seat);
    }
    assert(seats.size() == 9);
  }
  std::cout << "Screen data, atlas lifecycle, reduced motion, reset and physical seat binding passed\n";
}
