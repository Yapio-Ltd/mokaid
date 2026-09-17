"""Render the final cooked pack through Metal; capture deterministic activities."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "artifacts/office-life"
ASSETS = ROOT / "apps/desktop/build/assets"
BUILD = ROOT / "apps/desktop/build/macos-debug/renderer"
cases = [
    ("final-desk", 1807, 835, 11, "working"),
    ("final-chat", 1110, 835, 14.2, "working"),
    ("final-social", 1807, 835, 90, "idle"),
]
report = {
    "manifestSha256": hashlib.sha256((ASSETS / "manifest.json").read_bytes()).hexdigest(),
    "note": "Offscreen Debug build with Metal API Validation; nine real avatars. Not a full-app FPS guarantee.",
    "cases": [],
}
for name, width, height, seconds, status in cases:
    command = [str(BUILD / "mokaid_metal_smoke"), str(ASSETS), str(BUILD / "shaders"),
               str(OUT / f"{name}.png"), "9", str(width), str(height), str(seconds), status]
    result = subprocess.run(command, capture_output=True, text=True, env=os.environ | {"MTL_DEBUG_LAYER": "1"})
    log = result.stdout + result.stderr
    (OUT / f"{name}.log").write_text(log)
    if result.returncode:
        raise RuntimeError(f"{name} failed: {log}")
    assert "12 unretained command buffers, in-flight resize and renderer destruction passed" in log
    stats = re.search(r"CPU encode mean ([\d.]+) ms; GPU ([\d.]+) ms mean", log)
    geometry = re.search(r"Metal GPU: (.*); (\d+) draws; (\d+) triangles;", log)
    assert stats and geometry, log
    row = dict(name=name, viewport=[width, height], simulationSeconds=seconds, status=status,
               gpu=geometry[1], drawCalls=int(geometry[2]), triangles=int(geometry[3]),
               cpuEncodeMeanMs=float(stats[1]), gpuMeanMs=float(stats[2]), passed=True)
    report["cases"].append(row)
    print(json.dumps(row), flush=True)
(OUT / "native-final-render-validation.json").write_text(json.dumps(report, indent=2) + "\n")
