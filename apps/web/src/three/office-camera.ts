import { Matrix } from "@babylonjs/core/Maths/math.vector";

/** Bounds of the static office in camera-space x/z and y/z, independent of aspect. */
export interface OfficeCameraFootprint {
  minX: number;
  maxX: number;
  minY: number;
  maxY: number;
}

/** Fit and center the visible geometry, keeping the authored view and depth intact. */
export function fitOfficeProjection(
  projection: Matrix,
  footprint: OfficeCameraFootprint,
  edgeMargin = 0.06,
): Matrix {
  const original = projection.m;
  const minX = footprint.minX * original[0];
  const maxX = footprint.maxX * original[0];
  const minY = footprint.minY * original[5];
  const maxY = footprint.maxY * original[5];
  const span = Math.max(maxX - minX, maxY - minY);
  if (!Number.isFinite(span) || span <= 0) return projection.clone();

  const scale = (2 * (1 - 2 * edgeMargin)) / span;
  const centerX = (minX + maxX) / 2;
  const centerY = (minY + maxY) / 2;
  const fitted = Array.from(original);
  for (let column = 0; column < 4; column += 1) {
    const i = column * 4;
    fitted[i] = scale * (original[i] - centerX * original[i + 3]);
    fitted[i + 1] = scale * (original[i + 1] - centerY * original[i + 3]);
  }
  return Matrix.FromArray(fitted);
}
