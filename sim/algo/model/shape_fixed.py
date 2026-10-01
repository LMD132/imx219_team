"""Integer-only compact model: no analytic contour or OpenCV in classification."""
from dataclasses import dataclass
import json
from pathlib import Path

import numpy as np
from .shape_geometry import ShapeResult

PARAMS = json.loads(Path(__file__).with_name('shape_params.json').read_text(encoding='utf-8'))


@dataclass
class ShapeSummary:
    support: list[tuple[bool, int, int]]
    strips: list[tuple[bool, int, int]]
    bounds: tuple[int, int, int, int]
    bad: bool


def summarize_runs(runs: list[tuple[int, int, int]], width=1280, height=720) -> ShapeSummary:
    strips = [(False, 0, 0) for _ in range((height + 3) // 4)]
    support = [(False, 0, 0)] * 32
    bounds = (0, 0, 0, 0)
    bad = False
    points = []
    for y, x0, x1 in runs:
        if not (0 <= y < height and 0 <= x0 <= x1 < width):
            bad = True
            continue
        points.extend(((x0, y), (x1, y)))
        valid, left, right = strips[y // 4]
        strips[y // 4] = (True, min(left, x0) if valid else x0, max(right, x1) if valid else x1)
    if points:
        # Lexicographic presort + stable argmax implements the declared tie rule.
        ordered = sorted(set(points), key=lambda p: (p[1], p[0]))
        pts = np.array(ordered, dtype=np.int64)
        directions = np.array(PARAMS['directions_q8'], dtype=np.int64)
        scores = pts @ directions.T
        support = [(True, int(pts[i, 0]), int(pts[i, 1])) for i in np.argmax(scores, axis=0)]
        bounds = (int(pts[:, 0].min()), int(pts[:, 1].min()), int(pts[:, 0].max()), int(pts[:, 1].max()))
    return ShapeSummary(support, strips, bounds, bad)


def cross(a, b, c):
    return (b[0]-a[0])*(c[1]-a[1]) - (b[1]-a[1])*(c[0]-a[0])


def hull_points(points):
    pts = sorted(set(points))
    if len(pts) < 3:
        return pts
    lo, hi = [], []
    for stack, seq in ((lo, pts), (hi, reversed(pts))):
        for point in seq:
            while len(stack) >= 2 and cross(stack[-2], stack[-1], point) <= 0:
                stack.pop()
            stack.append(point)
    return lo[:-1] + hi[:-1]


def simplify_hull(hull, scale, params):
    poly = list(hull)
    epsilon = max(1, scale * params['corner_epsilon_pct'] // 100)
    while len(poly) > 3:
        best, best_num, best_den = -1, 0, 1
        for i, point in enumerate(poly):
            a, b = poly[i-1], poly[(i+1) % len(poly)]
            numerator = cross(a, b, point) ** 2
            denominator = (b[0]-a[0])**2 + (b[1]-a[1])**2
            if denominator and (best < 0 or numerator * best_den < best_num * denominator):
                best, best_num, best_den = i, numerator, denominator
        if best < 0 or best_num > epsilon * epsilon * best_den:
            break
        poly.pop(best)
    return poly


def hull_strip_range(hull, low, high):
    xs = []
    for i, a in enumerate(hull):
        b = hull[(i+1) % len(hull)]
        if low <= a[1] <= high:
            xs.append(a[0])
        if a[1] == b[1]:
            continue
        for y in (low, high):
            if min(a[1], b[1]) <= y <= max(a[1], b[1]):
                xs.append(a[0] + (y-a[1])*(b[0]-a[0]) // (b[1]-a[1]))
    return (min(xs), max(xs)) if xs else None


def classify_summary(summary: ShapeSummary, params: dict) -> ShapeResult:
    reject = lambda reason: ShapeResult(0, False, reason)
    if summary.bad:
        return reject('invalid runs')
    points = [(x, y) for valid, x, y in summary.support if valid]
    hull = hull_points(points)
    if len(hull) < 3:
        return reject('empty/degenerate')
    x0, y0, x1, y1 = summary.bounds
    width, height = x1-x0, y1-y0
    scale = max(width, height)
    if min(width, height) * 100 < scale * params['min_aspect_per_100']:
        return reject('line/aspect')
    tolerance = params['profile_error_pixels'] + scale * params['profile_error_pct'] // 100
    for k in range(y0 // 4, y1 // 4 + 1):
        valid, left, right = summary.strips[k]
        low, high = max(y0, k*4), min(y1, k*4+3)
        expected = hull_strip_range(hull, low, high)
        if not valid or expected is None:
            return reject('missing strip')
        # Support hull is an INSCRIBED polygon. At a flat raster extremum the
        # (y,x) tie keeps one endpoint, so real boundary can lie outside it.
        # Concavity is boundary lying too far INSIDE, not that sampling loss.
        if max(left-expected[0], expected[1]-right) > tolerance:
            return reject('concavity/profile')
    poly = simplify_hull(hull, scale, params)
    if len(poly) == 4:
        lengths = [((poly[(i+1) % 4][0]-poly[i][0])**2 +
                    (poly[(i+1) % 4][1]-poly[i][1])**2) for i in range(4)]
        short = [i for i, length in enumerate(lengths)
                 if length < params['min_side_pixels'] ** 2]
        if len(short) == 1:
            i = short[0]
            a, b = poly[i], poly[(i+1) % 4]
            midpoint = ((a[0]+b[0]) // 2, (a[1]+b[1]) // 2)
            poly = [midpoint, poly[(i+2) % 4], poly[(i+3) % 4]]
    # Every support point must lie near its simplified outline, not merely
    # survive a locally greedy corner removal.
    line_tolerance = max(1, scale * params['line_error_pct'] // 100)
    if len(poly) in (3, 4):
        for point in hull:
            if all(cross(poly[i], poly[(i+1) % len(poly)], point)**2 > line_tolerance**2 *
                   ((poly[(i+1) % len(poly)][0]-poly[i][0])**2 + (poly[(i+1) % len(poly)][1]-poly[i][1])**2)
                   for i in range(len(poly))):
                return reject('straight-edge residual')
        sides = [(poly[(i+1) % len(poly)][0]-a[0], poly[(i+1) % len(poly)][1]-a[1])
                 for i, a in enumerate(poly)]
        lens = [dx*dx+dy*dy for dx, dy in sides]
        if min(lens) < params['min_side_pixels'] ** 2:
            return reject('tiny side')
        if len(poly) == 3:
            return ShapeResult(3, True, 'three straight sides')
        for i, (ax, ay) in enumerate(sides):
            bx, by = sides[(i+1) % 4]
            cx, cy = sides[(i+2) % 4]
            if (ax*bx+ay*by)**2 * 10000 > lens[i]*lens[(i+1) % 4]*params['perpendicular_cos2_per_10000']:
                return reject('non-rectangular quad')
            if (ax*cy-ay*cx)**2 * 10000 > lens[i]*lens[(i+2) % 4]*params['parallel_sin2_per_10000']:
                return reject('non-parallel quad')
        return ShapeResult(2, True, 'four rectangular sides')
    if scale * 100 > min(width, height) * params['max_ellipse_aspect_per_100']:
        return reject('ellipse aspect')
    target = width*width*height*height
    residual_limit = target * params['radial_error_pct'] // 100
    for x, y in hull:
        radial = (2*x-x0-x1)**2*height*height + (2*y-y0-y1)**2*width*width
        if abs(radial-target) > residual_limit:
            return reject('support curve residual')
    for k in range(y0 // 4, y1 // 4 + 1):
        _, left, right = summary.strips[k]
        low, high = max(y0, k*4), min(y1, k*4+3)
        ys = [(2*y-y0-y1)**2 for y in range(low, high+1)]
        for x in (left, right):
            base = (2*x-x0-x1)**2*height*height
            if base+min(ys)*width*width > target+residual_limit or base+max(ys)*width*width < target-residual_limit:
                return reject('strip curve residual')
    return ShapeResult(1, True, 'ellipse exterior fit')
