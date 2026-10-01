"""Full ordered exterior-contour oracle, independent of compact support data."""
from dataclasses import dataclass
import cv2
import numpy as np


@dataclass(frozen=True)
class ShapeResult:
    cls: int
    valid: bool
    reason: str


def classify_contour(contours: list[np.ndarray], params: dict) -> ShapeResult:
    reject = lambda reason: ShapeResult(0, False, reason)
    if not contours:
        return reject('empty contour')
    contours = [np.asarray(c, dtype=np.int32) for c in contours]
    outer = max(contours, key=cv2.contourArea)
    area = cv2.contourArea(outer)
    if area <= 0 or len(outer) < 5:
        return reject('degenerate')
    # Nested ring edges are not separate targets. Disjoint exteriors are not
    # silently dropped by selecting the biggest one.
    for contour in contours:
        if cv2.pointPolygonTest(outer, tuple(map(float, contour[0, 0])), False) < 0:
            return reject('disjoint exterior')
    hull_area = cv2.contourArea(cv2.convexHull(outer))
    if area * 1000 < hull_area * params['oracle_solidity_per_1000']:
        return reject('concave exterior')
    x, y, w, h = cv2.boundingRect(outer)
    scale = max(w - 1, h - 1)
    if min(w - 1, h - 1) * 100 < scale * params['min_aspect_per_100']:
        return reject('line/aspect')
    polygon = cv2.approxPolyDP(outer, scale * params['corner_epsilon_pct'] / 100, True).reshape(-1, 2)
    sides = np.roll(polygon, -1, axis=0).astype(float) - polygon
    lengths2 = np.sum(sides * sides, axis=1)
    # A short segment in a many-sided curve approximation is not a short
    # polygon side. Apply this bound only to the polygon classes.
    if len(polygon) in (3, 4) and np.min(lengths2) < params['min_side_pixels'] ** 2:
        return reject('tiny side')
    if len(polygon) == 3:
        return ShapeResult(3, True, 'three straight sides')
    if len(polygon) == 4:
        for i in range(4):
            a, b = sides[i], sides[(i + 1) % 4]
            if float(np.dot(a, b)) ** 2 * 10000 > lengths2[i] * lengths2[(i + 1) % 4] * params['perpendicular_cos2_per_10000']:
                return reject('non-rectangular quad')
            c = sides[(i + 2) % 4]
            if (a[0] * c[1] - a[1] * c[0]) ** 2 * 10000 > lengths2[i] * lengths2[(i + 2) % 4] * params['parallel_sin2_per_10000']:
                return reject('non-parallel quad')
        return ShapeResult(2, True, 'four rectangular sides')
    (cx, cy), (dx, dy), angle = cv2.fitEllipse(outer)
    if min(dx, dy) <= 0 or max(dx, dy) * 100 > min(dx, dy) * params['max_ellipse_aspect_per_100']:
        return reject('ellipse aspect')
    theta = np.deg2rad(angle)
    p = outer.reshape(-1, 2).astype(float) - (cx, cy)
    u = p[:, 0] * np.cos(theta) + p[:, 1] * np.sin(theta)
    v = -p[:, 0] * np.sin(theta) + p[:, 1] * np.cos(theta)
    residual = np.abs((2 * u / dx) ** 2 + (2 * v / dy) ** 2 - 1)
    if np.max(residual) * 100 > params['radial_error_pct']:
        return reject('curve residual')
    return ShapeResult(1, True, 'ellipse exterior fit')
