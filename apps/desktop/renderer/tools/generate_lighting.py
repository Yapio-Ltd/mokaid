"""Compile the Blender light manifest used by the web into native uniforms."""
import json
from pathlib import Path
import re
import sys

source, output = map(Path, sys.argv[1:])
match = re.search(r"export const OFFICE_LIGHTS[^=]*=\s*(\[[\s\S]*\]);", source.read_text(encoding="utf-8"))
if not match:
    raise SystemExit("Office light manifest changed: review native conversion")
lights = [light for light in json.loads(match[1]) if light["name"] != "Point.005"]
if len(lights) != 16 or any(light["type"] not in {"AREA", "POINT"} for light in lights):
    raise SystemExit("Office light layout changed: review the native shader budget")

def vector(values):
    return "{" + ", ".join(f"{float(value):.6f}F" for value in values) + "}"

lines = ["// Generated from office-lighting.ts; positions converted to native RH Y-up.",
         "#pragma once", "#include <mokaid/engine/scene.hpp>",
         "namespace mokaid::renderer {",
         "struct OfficeLight { engine::Vec4 position, color, direction; };",
         "inline constexpr std::array<OfficeLight, 16> officeLights = {{"]
for light in lights:
    p, c = light["position"], light["color"]
    area = light["type"] == "AREA"
    lantern = light["name"] in {f"Point.{i:03}" for i in range(1, 5)}
    normal = light.get("normal", {"x": 0, "y": -1, "z": 0})
    lines.append("  {" + ", ".join([
        vector([p["x"], .9 if lantern else p["y"], -p["z"], 12 if area else 1.8]),
        vector([c["r"], c["g"], c["b"], light["energy"] * (.30 if area else .216)]),
        vector([normal["x"], normal["y"], -normal["z"], 1 if area else 0]),
    ]) + "}, // " + light["name"])
lines += ["}};", "struct OfficeLighting {", "  std::array<OfficeLight, 16> lights{officeLights};",
          "  std::array<engine::Vec4, 9> contacts{};", "};",
          "static_assert(sizeof(OfficeLighting) == 912);",
          "inline OfficeLighting lightingFor(const engine::Frame &frame) {",
          "  OfficeLighting result; std::size_t index = 0;",
          "  for (const auto &instance : frame.instances) {",
          "    if (instance.agentId.empty() || index == result.contacts.size()) continue;",
          "    const auto p = engine::transform(instance.transform, {0, 0, 0, 1});",
          "    result.contacts[index++] = {p.x, 0, p.z, .38F};",
          "  }", "  return result;", "}", "} // namespace mokaid::renderer", ""]
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text("\n".join(lines), encoding="utf-8", newline="\n")
