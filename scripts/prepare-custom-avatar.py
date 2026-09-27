#!/usr/bin/env python3
"""Prepare one generated humanoid for the complete Mokaid office animation set.

Run with Blender 5.2 LTS:
  blender --background --python-exit-code 1 --python scripts/prepare-custom-avatar.py \
    -- --input character.glb --output-dir prepared

The original surface and albedo are preserved. The catalog's geometric IK
author adds grip joints and office props, bakes all 48 actions, and independently
reimports and validates the exported GLB before any output is marked ready.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import runpy
import struct
import sys
import tempfile
import time
import traceback
from pathlib import Path

import bpy
import numpy as np
from mathutils import Matrix, Vector

SCRIPTS = Path(__file__).resolve().parent
LIFE = runpy.run_path(str(SCRIPTS / "blender-avatar-life.py"))
BASE = LIFE["BASE"]
REQUIRED = {"Hips", "Spine", "Spine01", "Spine02", "Head"} | {
    side + bone
    for side in ("Left", "Right")
    for bone in ("UpLeg", "Leg", "Foot", "Arm", "ForeArm", "Hand")
}
TARGET_HEIGHT = 1.75


def require(condition, message):
    if not condition:
        raise ValueError(message)


def preflight(path):
    data = path.read_bytes()
    require(20 <= len(data) <= 64 * 1024 * 1024, "Character GLB must be under 64 MiB.")
    magic, version, size, json_size, chunk = struct.unpack_from("<4s4I", data)
    require(magic == b"glTF" and version == 2 and size == len(data)
            and chunk == 0x4E4F534A and json_size <= size - 20, "Invalid character GLB.")
    doc = json.loads(data[20:20 + json_size])
    require(bool(doc.get("meshes")) and bool(doc.get("skins")), "Character needs a humanoid skeleton and skin weights.")
    require(len(doc.get("nodes", [])) <= 4096, "Character scene has too many nodes.")
    for entry in doc.get("buffers", []) + doc.get("images", []):
        uri = entry.get("uri")
        require(uri is None or (isinstance(uri, str) and uri.startswith("data:") and ";base64," in uri),
                "Character must embed all textures and geometry.")
    for node in doc.get("nodes", []):
        for key in ("translation", "rotation", "scale", "matrix"):
            require(all(isinstance(n, (int, float)) and math.isfinite(n) for n in node.get(key, [])),
                    "Character contains invalid transforms.")
    names = {node.get("name") for node in doc["nodes"]}
    require(REQUIRED <= names, "This character needs a standard humanoid rig with separate arms, legs, hands and head.")
    for skin in doc["skins"]:
        joints = skin.get("joints", [])
        require(0 < len(joints) <= 119, "Character skeleton exceeds the supported joint count.")
        require(doc["nodes"][joints[0]].get("name") == "Hips", "The character skeleton must start at its pelvis.")
    return hashlib.sha256(data).hexdigest()


def geometry_digest(meshes):
    return {
        obj.name: hashlib.sha256(np.asarray([list(v.co) for v in obj.data.vertices], dtype="<f4").tobytes()).hexdigest()
        for obj in meshes
    }


def deformed_height(meshes):
    dg = bpy.context.evaluated_depsgraph_get()
    low, high = float("inf"), -float("inf")
    for obj in meshes:
        evaluated = obj.evaluated_get(dg)
        mesh = evaluated.to_mesh()
        try:
            points = np.empty(len(mesh.vertices) * 3)
            mesh.vertices.foreach_get("co", points)
            mat = np.asarray(obj.matrix_world)
            zs = points.reshape((-1, 3)) @ mat[2, :3] + mat[2, 3]
            require(np.isfinite(zs).all(), "Character deformation contains invalid coordinates.")
            low, high = min(low, float(zs.min())), max(high, float(zs.max()))
        finally:
            evaluated.to_mesh_clear()
    require(high > low and math.isfinite(high - low), "Character has invalid body dimensions.")
    return high - low


def prepare_rig(input_path, staging):
    arm, meshes, repaired = BASE["source"](input_path, staging / "source.glb")
    require(len([o for o in bpy.data.objects if o.type == "ARMATURE"]) == 1,
            "Character must contain exactly one humanoid skeleton.")
    require(REQUIRED <= set(arm.data.bones.keys()), "Character skeleton is not supported.")
    # The author only supports this known hierarchy. Bone names alone cannot
    # establish a valid rig, especially for asymmetric or disconnected bodies.
    for side in ("Left", "Right"):
        for parent, child in (("UpLeg", "Leg"), ("Leg", "Foot"), ("Arm", "ForeArm"), ("ForeArm", "Hand")):
            require(arm.data.bones[side + child].parent == arm.data.bones[side + parent],
                    "Character limbs do not form supported two-segment chains.")
    source_meshes = list(meshes)
    source_geometry = geometry_digest(meshes)
    rig = BASE["Rig"](arm, meshes)
    bind_height = rig.height
    rig.walk_duration = LIFE["gait_config"]("avatar_corporate", "walking")[0]
    for _ in range(2):
        BASE["animate"](rig, "idle", 0)
        rig.apply(None)
        bpy.context.view_layer.update()
        rig.height = deformed_height(meshes)
    reference_height = rig.height
    meshes = BASE["add_cup"](rig)
    rig = BASE["Rig"](arm, meshes)
    rig.height = reference_height
    frames = {side: q.copy() for side, q in rig.hand_frames.items()}
    lengths = {side: LIFE["hand_geometry"](rig, side)["length"] for side in ("l", "r")}
    grips = LIFE["add_grip_bones"](rig)
    meshes = LIFE["add_phone"](rig)
    rig = BASE["Rig"](arm, meshes)
    rig.height, rig.key, rig.grip_report = reference_height, "avatar_corporate", grips
    rig.hand_frames, rig.hand_lengths = frames, lengths
    rig.cup_offset = Vector((.063 * reference_height / TARGET_HEIGHT, 0, -.38 * lengths["r"]))
    ns = reference_height / TARGET_HEIGHT
    head = rig.rest[rig.head].translation
    head_points = []
    for obj in source_meshes:
        group = obj.vertex_groups.get(rig.head)
        if group:
            for vertex in obj.data.vertices:
                point = obj.matrix_world @ vertex.co
                if head.z + .02 * ns < point.z < head.z + .18 * ns and any(g.group == group.index and g.weight > .7 for g in vertex.groups):
                    head_points.append(point.x - head.x)
    rig.ear_width = max(.080 * ns, min(.16 * ns, float(np.quantile(head_points, .92)) if head_points else .11 * ns)) + .013 * ns
    LIFE["calibrate_reach"](rig)
    BASE["normalize_avatar_materials"](meshes)
    require(geometry_digest(source_meshes) == source_geometry, "Source geometry changed while preparing the character.")
    return rig, repaired, bind_height


def bake(rig):
    scene = bpy.context.scene
    scene.render.fps, scene.frame_start = LIFE["FPS"], 0
    actions, metrics = {}, {}
    for name, default_duration in LIFE["DURATIONS"].items():
        duration, gait = LIFE["gait_config"](rig.key, name) if name in LIFE["WALKS"] else (default_duration, {})
        rig.walk_duration = LIFE["gait_config"](rig.key, "walking")[0]
        action = bpy.data.actions.new(name)
        action.use_fake_user = True
        rig.arm.animation_data_create()
        rig.arm.animation_data.action = action
        frames = round(duration * LIFE["FPS"])
        contact_error, rig.max_ik_error = 0, 0
        for frame in range(frames + 1):
            phase = frame / frames if frame < frames or name in LIFE["NON_LOOP"] else 0
            feet = LIFE["animate"](rig, name, phase)
            rig.apply(frame)
            contact_error = max(contact_error, *( (rig.pos(limb["foot"]) - feet[side]).length * TARGET_HEIGHT / rig.height
                                                    for side, limb in rig.limbs.items()))
        for curve in BASE["channel_curves"](action):
            for point in curve.keyframe_points:
                point.interpolation = "LINEAR"
        metrics[name] = {"duration_seconds": duration, "frames": frames + 1,
                         "foot_target_error_m": contact_error,
                         "max_ik_target_error_m": rig.max_ik_error * TARGET_HEIGHT / rig.height,
                         "loop": name not in LIFE["NON_LOOP"]}
        if gait:
            metrics[name].update(reference_speed_mps=LIFE["WALK_SPEEDS"][name], gait=gait)
        actions[name] = action
        print("BAKED", name, flush=True)
    rig.arm.animation_data.action = actions["idle"]
    scene.frame_set(0)
    bpy.context.view_layer.update()
    return actions, metrics


def portrait(output):
    arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
    arm.animation_data.action = bpy.data.actions["idle"]
    scene = bpy.context.scene
    scene.frame_set(0)
    bpy.context.view_layer.update()
    head = arm.pose.bones["Head"]
    names = {head.name} | {b.name for b in head.children_recursive}
    points, dg = [], bpy.context.evaluated_depsgraph_get()
    for obj in bpy.data.objects:
        if obj.type != "MESH" or not obj.vertex_groups:
            continue
        indices = [v.index for v in obj.data.vertices if sum(g.weight for g in v.groups
                   if obj.vertex_groups[g.group].name in names) > .65]
        if indices:
            evaluated = obj.evaluated_get(dg)
            mesh = evaluated.to_mesh()
            points.extend(list(obj.matrix_world @ mesh.vertices[i].co) for i in indices)
            evaluated.to_mesh_clear()
        if obj.name in {"OfficeCoffeeCup", "OfficePhone", "OfficePhoneDock"}:
            obj.hide_render = True
    require(len(points) >= 4, "Cannot locate the character's head for its portrait.")
    low, high = np.min(points, axis=0), np.max(points, axis=0)
    height, width = float(high[2] - low[2]), float(high[0] - low[0])
    require(height > 0 and width > 0, "Character head has invalid dimensions.")
    unit = height / .40
    target = Vector((float((low[0] + high[0]) / 2), float((low[1] + high[1]) / 2), float(low[2] + .43 * height)))
    camera_data = bpy.data.cameras.new("Character portrait")
    camera = bpy.data.objects.new("Character portrait", camera_data)
    scene.collection.objects.link(camera)
    scene.camera = camera
    camera_data.type = "ORTHO"
    camera_data.ortho_scale = max(1.43 * height, 1.42 * width)
    camera.location = target + Vector((.45, -3.5, .10)) * unit
    camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
    scene.world = bpy.data.worlds.new("Character portrait studio")
    scene.world.use_nodes = True
    scene.world.node_tree.nodes["Background"].inputs["Color"].default_value = (.08, .09, .17, 1)
    scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = .35
    for name, position, energy, size, color in [
        ("Soft key", (-1.7, -2.6, 2.6), 210, 3, (1, .90, .82)),
        ("Cool fill", (2, -1, 1), 100, 2, (.60, .68, 1)),
        ("Violet rim", (.4, 1.2, 1.5), 190, 2, (.50, .25, 1))]:
        data = bpy.data.lights.new(name, "AREA")
        data.energy, data.size, data.color = energy * unit ** 2, size * unit, color
        light = bpy.data.objects.new(name, data)
        scene.collection.objects.link(light)
        light.location = target + Vector(position) * unit
        light.rotation_euler = (target - light.location).to_track_quat("-Z", "Y").to_euler()
    scene.render.resolution_x = scene.render.resolution_y = 384
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.film_transparent = True
    scene.view_settings.view_transform = "AgX"
    scene.render.filepath = str(output)
    # Headless CPU rendering is deterministic and works on the production host
    # without an EGL/Metal display. Opt in to EEVEE where GPU support is known.
    engine = "BLENDER_EEVEE" if os.environ.get("MOKAID_PORTRAIT_EEVEE") == "1" else "CYCLES"
    scene.render.engine = engine
    if engine == "CYCLES":
        scene.cycles.device, scene.cycles.samples, scene.cycles.use_denoising = "CPU", 24, True
    try:
        bpy.ops.render.render(write_still=True)
    except RuntimeError:
        if engine != "BLENDER_EEVEE":
            raise
        scene.render.engine = "CYCLES"
        scene.cycles.device, scene.cycles.samples, scene.cycles.use_denoising = "CPU", 24, True
        bpy.ops.render.render(write_still=True)
    return {"size": [384, 384], "head_bounds": [low.tolist(), high.tolist()],
            "weighted_head_vertices": len(points), "ortho_scale": camera_data.ortho_scale,
            "renderer": scene.render.engine}


def preview(rig, actions, output):
    """Offline contact sheet with measured reference desk/seat surfaces."""
    scene = bpy.context.scene
    height, ns = rig.height, rig.height / TARGET_HEIGHT
    names = ["idle", "walking", "typing_focused", "phone_call",
             "carrying_coffee", "drinking_coffee", "playing_foosball", "sitting_sofa"]
    surface = LIFE["material"]("Reference furniture", (.16, .19, .25, 1))

    def box(name, center, dimensions, transform):
        bpy.ops.mesh.primitive_cube_add(size=1)
        obj = bpy.context.object
        obj.name = name
        obj.matrix_world = transform @ Matrix.Translation(center) @ Matrix.Diagonal(Vector((*dimensions, 1)))
        obj.data.materials.append(surface)

    for i, name in enumerate(names):
        rig.arm.animation_data.action = actions[name]
        frame = actions[name].frame_range[1] * (.4 if name == "drinking_coffee" else .28)
        scene.frame_set(int(frame), subframe=frame % 1)
        bpy.context.view_layer.update()
        dg = bpy.context.evaluated_depsgraph_get()
        offset = Vector(((i % 4) * 1.3 * height, 0, -(i // 4) * 1.5 * height))
        transform = Matrix.Translation(offset) @ Matrix.Rotation(.42, 4, "Z")
        for obj in rig.meshes:
            mesh = bpy.data.meshes.new_from_object(obj.evaluated_get(dg), depsgraph=dg)
            snapshot = bpy.data.objects.new(name + " " + obj.name, mesh)
            scene.collection.objects.link(snapshot)
            snapshot.matrix_world = transform @ obj.matrix_world
        origin = rig.origin.copy()
        if name in {"typing_focused", "phone_call"}:
            box(name + " reference desktop", Vector((origin.x, origin.y - .46 * ns, rig.floor + .745 * ns)),
                (1.05 * ns, .48 * ns, .03 * ns), transform)
            box(name + " reference chair", Vector((origin.x, origin.y + .025 * ns, rig.floor + .435 * ns)),
                (.46 * ns, .41 * ns, .055 * ns), transform)
        if name == "sitting_sofa":
            box("reference sofa cushion", Vector((origin.x, origin.y + .06 * ns, rig.floor + .625 * ns)),
                (.70 * ns, .48 * ns, .10 * ns), transform)
        data = bpy.data.curves.new(name, "FONT")
        data.body, data.align_x, data.size = name.replace("_", " "), "CENTER", .055 * height
        label = bpy.data.objects.new(name + " label", data)
        scene.collection.objects.link(label)
        label.location = offset + Vector((0, -.30 * height, -.15 * height))
        label.rotation_euler = (math.pi / 2, 0, 0)
    for obj in rig.meshes:
        obj.hide_render = True
    target = Vector((1.95 * height, 0, -.19 * height))
    BASE["camera_at"](target + Vector((0, -9 * height, .45 * height)), target, 5.2 * height)
    scene.world = bpy.data.worlds.new("Validation studio")
    scene.world.use_nodes = True
    scene.world.node_tree.nodes["Background"].inputs["Color"].default_value = (.06, .075, .105, 1)
    scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = .4
    for name, position, energy, color in [
        ("Key", (-2, -4, 4), 1800, (1, .89, .8)),
        ("Fill", (5, -3, 2), 1400, (.75, .84, 1)),
        ("Rim", (2, 2, 4), 1600, (.74, .91, 1))]:
        data = bpy.data.lights.new(name, "AREA")
        data.energy, data.size, data.color = energy, 6, color
        light = bpy.data.objects.new(name, data)
        scene.collection.objects.link(light)
        light.location = target + Vector(position)
        light.rotation_euler = (target - light.location).to_track_quat("-Z", "Y").to_euler()
    scene.render.engine = "CYCLES"
    scene.cycles.device, scene.cycles.samples, scene.cycles.use_denoising = "CPU", 24, True
    scene.view_settings.view_transform = "AgX"
    scene.render.resolution_x, scene.render.resolution_y = 1600, 1100
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = str(output)
    bpy.ops.render.render(write_still=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--preview", action="store_true")
    args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:])
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    manifest = {"status": "failed", "pipeline_version": 1, "target_height_m": TARGET_HEIGHT,
                "blender_version": bpy.app.version_string}
    try:
        require(bpy.app.version >= (5, 2, 0), "Character preparation requires Blender 5.2 LTS or newer.")
        manifest["source_sha256"] = preflight(args.input)
        with tempfile.TemporaryDirectory(prefix="mokaid-custom-", dir=output) as temporary:
            staging = Path(temporary)
            rig, repaired, bind_height = prepare_rig(args.input.resolve(), staging)
            actions, metrics = bake(rig)
            report = {"height_m": rig.height, "bind_height_m": bind_height, "clips": metrics,
                      "cup_offset_m": list(rig.cup_offset / (rig.height / TARGET_HEIGHT))}
            (staging / "report.json").write_text(json.dumps({"avatar_custom": report}))
            model = staging / "avatar_custom.glb"
            BASE["export_avatar"](rig.arm, rig.meshes, model)
            if args.preview:
                preview(rig, actions, staging / "contact-sheet.png")
            validator = runpy.run_path(str(SCRIPTS / "validate-avatar-life.py"))
            original_argv = sys.argv
            try:
                sys.argv = ["validate-avatar-life.py", "--", str(staging)]
                validator["main"]()
            finally:
                sys.argv = original_argv
            validation = json.loads((staging / "validation.json").read_text())["avatar_custom"]
            portrait_info = portrait(staging / "portrait.png")
            manifest.update(status="ready", animation_clips=list(LIFE["DURATIONS"]),
                            non_loop_clips=sorted(LIFE["NON_LOOP"]),
                            sockets=["cup_socket", "phone_socket", "phone_dock_socket"],
                            quality=validation, clips=metrics, portrait=portrait_info,
                            normalized_weight_vertices=repaired,
                            model_sha256=hashlib.sha256(model.read_bytes()).hexdigest())
            model.replace(output / "model.glb")
            (staging / "portrait.png").replace(output / "portrait.png")
            if args.preview:
                (staging / "contact-sheet.png").replace(output / "contact-sheet.png")
        manifest["elapsed_seconds"] = round(time.monotonic() - started, 3)
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print("PREPARED", json.dumps({k: manifest[k] for k in ("status", "elapsed_seconds", "model_sha256")}), flush=True)
    except Exception as error:
        # Partial output is never usable. A retry cannot pick up a stale model
        # while the manifest says this attempt failed.
        for name in ("model.glb", "portrait.png", "contact-sheet.png"):
            (output / name).unlink(missing_ok=True)
        manifest.update(status="failed", error="Character could not be prepared for office activities: " + str(error),
                        elapsed_seconds=round(time.monotonic() - started, 3))
        (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        traceback.print_exc()
        raise SystemExit(1)


if __name__ == "__main__":
    main()
