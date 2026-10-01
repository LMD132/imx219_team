"""Deterministic raster edges. Ground truth never enters either classifier."""
from dataclasses import dataclass
import math
import cv2
import numpy as np


@dataclass
class ShapeCase:
    kind: str
    expected_cls: int
    runs: list[tuple[int, int, int]]
    contours: list[np.ndarray]
    bounds: tuple[int, int, int, int]


def case_from_edge(edge, offset=(0, 0), kind='diagnostic', expected_cls=0):
    ox, oy = offset
    runs = []
    for row in np.flatnonzero(np.any(edge, axis=1)):
        transitions = np.diff(np.pad((edge[row] != 0).astype(np.int8), (1, 1)))
        for left, right in zip(np.flatnonzero(transitions == 1), np.flatnonzero(transitions == -1)):
            runs.append((int(row + oy), int(left + ox), int(right - 1 + ox)))
    contours, _ = cv2.findContours(edge.copy(), cv2.RETR_TREE, cv2.CHAIN_APPROX_NONE)
    contours = [c.astype(np.int64) + np.array([[[ox, oy]]]) for c in contours]
    bounds = (min((r[1] for r in runs), default=0), min((r[0] for r in runs), default=0),
              max((r[2] for r in runs), default=0), max((r[0] for r in runs), default=0))
    return ShapeCase(kind, expected_cls, runs, contours, bounds)


def make_case(kind: str, angle_deg: int, size: int, aspect: float,
              center: tuple[int, int], phase: tuple[float, float]) -> ShapeCase:
    radius = size / 2
    pad = size + 8
    edge_size = pad * 2 + 1
    mask = np.zeros((edge_size, edge_size), dtype=np.uint8)
    origin = np.array([pad + phase[0], pad + phase[1]])
    if kind in ('circle', 'ring'):
        yy, xx = np.indices(mask.shape)
        distance2 = (xx - origin[0]) ** 2 + (yy - origin[1]) ** 2
        mask[distance2 <= radius ** 2] = 255
        if kind == 'ring':
            mask[distance2 < (radius * 0.6) ** 2] = 0
    else:
        if kind in ('square', 'rectangle'):
            half_height = radius / aspect
            points = [(-radius, -half_height), (radius, -half_height),
                      (radius, half_height), (-radius, half_height)]
        elif kind == 'parallelogram':
            # Long parallel sides, visibly non-right adjacent sides.
            points = [(-radius, -radius), (radius * 0.25, -radius),
                      (radius, radius), (-radius * 0.25, radius)]
        elif kind in ('triangle', 'pentagon', 'star'):
            n = {'triangle': 3, 'pentagon': 5, 'star': 10}[kind]
            points = [(radius * (0.42 if kind == 'star' and i % 2 else 1) * math.cos(-math.pi/2 + i*2*math.pi/n),
                       radius * (0.42 if kind == 'star' and i % 2 else 1) * math.sin(-math.pi/2 + i*2*math.pi/n))
                      for i in range(n)]
        elif kind == 'cross':
            arm = radius * aspect
            points = [(-arm, -radius), (arm, -radius), (arm, -arm), (radius, -arm),
                      (radius, arm), (arm, arm), (arm, radius), (-arm, radius),
                      (-arm, arm), (-radius, arm), (-radius, -arm), (-arm, -arm)]
        elif kind == 'line':
            points = [(-radius, -1), (radius, -1), (radius, 1), (-radius, 1)]
        else:
            raise ValueError(f'unsupported fixture kind {kind}')
        angle = math.radians(angle_deg)
        rotation = np.array([[math.cos(angle), -math.sin(angle)],
                             [math.sin(angle), math.cos(angle)]])
        vertices = np.array(points) @ rotation.T + origin
        cv2.fillPoly(mask, [np.rint(vertices * 256).astype(np.int32)], 255, shift=8)
    # One-pixel internal boundary includes the ring's inner edge; both consumers
    # receive this same sampled edge, not ideal analytic vertices.
    edge = cv2.subtract(mask, cv2.erode(mask, np.ones((3, 3), np.uint8)))
    return case_from_edge(edge, (center[0] - pad, center[1] - pad), kind,
                          {'ring': 1, 'circle': 1, 'triangle': 3, 'square': 2, 'rectangle': 2}.get(kind, 0))


def diagnostic_cases():
    """Not an acceptance threshold tuner: report boundaries without promises.

    Gaps are horizontal excisions at the top boundary; noise is salt pixels
    outside the object; perspective shrinks the top of the ROI by the stated
    fraction. These are 66 named, deterministic diagnostics, not real photos.
    """
    rng = np.random.default_rng(20261001)
    kinds = [('ring', 1), ('circle', 1), ('triangle', 1),
             ('square', 1), ('rectangle', 1.5), ('rectangle', 2)]
    for kind, aspect in kinds:
        case = make_case(kind, 35, 80, aspect, (640, 360), (0.5, 0.5))
        x0, y0, x1, y1 = case.bounds
        offset = (x0 - 8, y0 - 8)
        edge = np.zeros((y1-y0+17, x1-x0+17), np.uint8)
        for y, left, right in case.runs:
            edge[y-offset[1], left-offset[0]:right-offset[0]+1] = 255
        name = f'{kind}:{aspect}'
        first_y, first_x = np.argwhere(edge != 0)[0]
        for gap in (1, 3, 5):
            changed = edge.copy()
            changed[first_y:first_y+3, first_x:first_x+gap] = 0
            yield f'gap{gap}', case_from_edge(changed, offset, name, case.expected_cls)
        empty = np.argwhere(edge == 0)
        for noise in (2, 8, 16):
            changed = edge.copy()
            coordinates = empty[rng.choice(len(empty), noise, replace=False)]
            changed[coordinates[:, 0], coordinates[:, 1]] = 255
            yield f'noise{noise}', case_from_edge(changed, offset, name, case.expected_cls)
        changed = edge.copy()
        cut = 8 + max(1, (x1-x0+1) // 10)
        changed[:, :cut] = 0
        # Place the truncation at source-frame column zero; the absent part
        # is unavailable to the classifier, not passed as out-of-range data.
        changed = changed[:, cut:]
        yield 'clip10pct', case_from_edge(changed, (0, offset[1]), name, case.expected_cls)
        h, w = edge.shape
        source = np.float32([[0, 0], [w-1, 0], [w-1, h-1], [0, h-1]])
        for percent in (5, 15, 30):
            inset = (w-1) * percent / 100
            destination = np.float32([[inset, 0], [w-1-inset, 0], [w-1, h-1], [0, h-1]])
            changed = cv2.warpPerspective(edge, cv2.getPerspectiveTransform(source, destination),
                                          (w, h), flags=cv2.INTER_NEAREST)
            yield f'perspective{percent}pct', case_from_edge(changed, offset, name, case.expected_cls)
        # Semantic decoration cannot be removed by a geometric classifier.
        decorative = make_case('rectangle', 35, 80, 1.5, (640, 360), (0.5, 0.5))
        decorative.kind = 'decorative rectangle'
        yield 'decorative', decorative


def diagnostic_report(params):
    from collections import Counter
    import hashlib
    import json
    import platform
    from pathlib import Path
    from .shape_geometry import classify_contour
    from .shape_fixed import summarize_runs, classify_summary
    counts, details = Counter(), []
    for name, case in diagnostic_cases():
        for model, result in (('contour', classify_contour(case.contours, params)),
                              ('fixed', classify_summary(summarize_runs(case.runs), params))):
            outcome = 'correct' if result.valid and result.cls == case.expected_cls else ('reject' if not result.valid else 'wrong')
            counts[(model, name, outcome)] += 1
            details.append({'model': model, 'case': name, 'shape': case.kind, 'cls': result.cls,
                            'valid': result.valid, 'reason': result.reason})
    report = {'seed': 20261001, 'count': 66,
              'versions': {'python': platform.python_version(), 'numpy': np.__version__, 'opencv': cv2.__version__},
              'params_sha256': hashlib.sha256(Path(__file__).with_name('shape_params.json').read_bytes()).hexdigest(),
              'counts': [{'model': m, 'case': c, 'outcome': o, 'count': n} for (m, c, o), n in sorted(counts.items())],
              'details': details}
    print('MODEL DIAGNOSTICS ' + json.dumps({k: v for k, v in report.items() if k != 'details'}, sort_keys=True))
    return report
