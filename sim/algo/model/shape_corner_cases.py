"""Deterministic clipped-corner regression fixtures, with literal shape labels.

This is test data only: no classifier output selects or labels a fixture.
Quarter turns/mirrors exercise every cyclic support-index position exactly.
"""
import cv2
import numpy as np

from .shape_cases import case_from_edge, diagnostic_cases, make_case


def transformed(case, turns, mirror, center):
    points = np.array([(x - 640, y - 360) for y, a, b in case.runs
                       for x in range(a, b + 1)], dtype=np.int32)
    if mirror:
        points[:, 0] *= -1
    for _ in range(turns):
        points = np.column_stack((-points[:, 1], points[:, 0]))
    points += np.array(center)
    x0, y0 = points.min(axis=0)
    x1, y1 = points.max(axis=0)
    edge = np.zeros((y1-y0+1, x1-x0+1), dtype=np.uint8)
    edge[points[:, 1]-y0, points[:, 0]-x0] = 255
    return case_from_edge(edge, (int(x0), int(y0)), case.kind, case.expected_cls)


def clipped_corner_cases():
    """144 small defects in two rectangle aspects, eight orientations, 3 positions.

    gap1/3/5 are the existing top-three-row excisions, not guaranteed physical
    breaks of that many pixels. The undamaged underlying object is a rectangle.
    """
    for defect, case in diagnostic_cases():
        if case.kind not in ('rectangle:1.5', 'rectangle:2') or not defect.startswith('gap'):
            continue
        for turns in range(4):
            for mirror in (False, True):
                for center in ((240, 180), (640, 360), (1000, 500)):
                    name = f'{case.kind}:{defect}:turn{turns}:mirror{int(mirror)}:at{center}'
                    yield name, transformed(case, turns, mirror, center)


def polygon_case(points, label):
    mask = np.zeros((180, 180), dtype=np.uint8)
    cv2.fillPoly(mask, [np.array(points, np.int32) + 90], 255)
    edge = cv2.subtract(mask, cv2.erode(mask, np.ones((3, 3), np.uint8)))
    return case_from_edge(edge, (550, 270), label, 0)


def corner_negative_cases():
    """A substantial bevel or a nonrectangular quad must not become a rectangle."""
    # All coordinates describe intentionally unsupported polygons. The short
    # fifth side alone is not enough: a skewed quadrilateral must still fail.
    shapes = {
        'large_bevel_pentagon': [(-60,-40),(40,-40),(60,-20),(60,40),(-60,40)],
        'short_bevel_skew_quad': [(-58,-40),(16,-40),(24,-36),(60,40),(-20,40)],
        'line_failure_skew_pentagon': [(-28,-20),(4,-20),(12,-15),(30,20),(-10,20)],
        'two_short_edges_pentagon': [(-30,-20),(20,-20),(28,-14),(30,-5),(-30,20)],
        'multiple_bevels_polygon': [(-55,-40),(55,-40),(60,-35),(60,40),(-55,40),(-60,35),(-60,-35)],
    }
    for kind, points in shapes.items():
        base = polygon_case(points, kind)
        for turns in range(4):
            for mirror in (False, True):
                yield f'{kind}:turn{turns}:mirror{int(mirror)}', transformed(base, turns, mirror, (640, 360))


def curve_fallback_summary():
    """Controlled interface summary: failed quad recovery must retain curve fit.

    This deliberately sparse support is NOT produced by the 32-direction
    sampler. Its five points lie on a circle; real raster strips/bounds remain
    from that circle. It tests the classifier's fallback computations only.
    """
    from .shape_fixed import summarize_runs
    summary = summarize_runs(make_case('circle', 0, 100, 1, (640, 360), (0, 0)).runs)
    summary.support = [(True, 690, 360), (True, 689, 369), (True, 640, 410),
                       (True, 590, 360), (True, 640, 310)] + [(False, 0, 0)] * 27
    return summary
