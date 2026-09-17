import { Matrix, Vector3 } from "@babylonjs/core/Maths/math.vector";
import { describe, expect, it } from "vitest";
import { fitOfficeProjection } from "./office-camera";

// An off-center office silhouette, with its four extrema at different depths.
const points = [
  new Vector3(-8, -2, 16),
  new Vector3(12, 3, 20),
  new Vector3(2, -5, 10),
  new Vector3(-2, 8, 20),
];
const footprint = { minX: -0.5, maxX: 0.6, minY: -0.5, maxY: 0.4 };

describe("office camera aspect fit", () => {
  it.each([1440 / 900, 1024 / 768, 760 / 900, 704 / 768, 390 / 844, 2.4])(
    "shows the complete silhouette with six percent edge clearance at aspect %s",
    (aspect) => {
      const original = Matrix.PerspectiveFovLH(0.5, aspect, 0.1, 100);
      const fitted = fitOfficeProjection(original, footprint);
      const projected = points.map((point) => Vector3.TransformCoordinates(point, fitted));
      for (const p of projected) {
        expect(Math.abs(p.x)).toBeLessThanOrEqual(0.880001);
        expect(Math.abs(p.y)).toBeLessThanOrEqual(0.880001);
      }
      const xs = projected.map((p) => p.x);
      const ys = projected.map((p) => p.y);
      expect(Math.min(...xs) + Math.max(...xs)).toBeCloseTo(0, 6);
      expect(Math.min(...ys) + Math.max(...ys)).toBeCloseTo(0, 6);
      expect(Math.max(...projected.map((p) => Math.max(Math.abs(p.x), Math.abs(p.y))))).toBeCloseTo(
        0.88,
        6,
      );

      // Resizing must not change depth clipping, perspective, or shape proportions.
      points.forEach((point, i) => {
        expect(projected[i].z).toBeCloseTo(Vector3.TransformCoordinates(point, original).z, 7);
      });
      const center = Vector3.TransformCoordinates(new Vector3(0, 0, 10), fitted);
      const right = Vector3.TransformCoordinates(new Vector3(1, 0, 10), fitted);
      const up = Vector3.TransformCoordinates(new Vector3(0, 1, 10), fitted);
      expect((right.x - center.x) * aspect).toBeCloseTo(up.y - center.y, 6);
    },
  );

  it("leaves a valid projection unchanged when no visible geometry was imported", () => {
    const original = Matrix.PerspectiveFovLH(0.5, 1.6, 0.1, 100);
    const fitted = fitOfficeProjection(original, {
      minX: Infinity,
      maxX: -Infinity,
      minY: Infinity,
      maxY: -Infinity,
    });
    expect(Array.from(fitted.m)).toEqual(Array.from(original.m));
  });
});
