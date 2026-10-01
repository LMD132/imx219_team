"""Rotation acceptance is about labels, not resemblance to a chosen template."""
import json
import math
from collections import Counter
from pathlib import Path
import unittest

import numpy as np

try:
    from model.shape_cases import make_case, diagnostic_cases
    from model.shape_geometry import classify_contour
    from model.shape_fixed import summarize_runs, classify_summary
except ImportError as exc:
    MODEL_IMPORT_ERROR = str(exc)
else:
    MODEL_IMPORT_ERROR = None

PARAM_PATH = Path(__file__).parent / 'model/shape_params.json'
KINDS = [('ring', 1.0), ('circle', 1.0), ('triangle', 1.0),
         ('square', 1.0), ('rectangle', 1.5), ('rectangle', 2.0)]


class ShapeModelTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNone(MODEL_IMPORT_ERROR, 'models not implemented: ' + str(MODEL_IMPORT_ERROR))
        self.params = json.loads(PARAM_PATH.read_text(encoding='utf-8'))

    def results(self, case):
        return [('contour', classify_contour(case.contours, self.params)),
                ('fixed', classify_summary(summarize_runs(case.runs), self.params))]

    def test_clean_rotation_matrix(self):
        failures, count, totals = [], 0, Counter()
        for kind, aspect in KINDS:
            for angle in range(0, 360, 5):
                for size in (48, 80, 160):
                    for center in ((240, 180), (640, 360), (1000, 500)):
                        for phase in ((0.0, 0.0), (0.5, 0.5)):
                            case = make_case(kind, angle, size, aspect, center, phase)
                            count += 1
                            for name, result in self.results(case):
                                outcome = 'correct' if result.valid and result.cls == case.expected_cls else ('reject' if not result.valid else 'wrong')
                                totals[(name, kind, aspect, outcome)] += 1
                                if not result.valid or result.cls != case.expected_cls:
                                    failures.append((name, kind, aspect, angle, size, center, phase,
                                                     result.cls, result.reason))
        self.assertEqual(count, 7776)
        for key, total in sorted(totals.items()):
            print('MODEL COUNTS', key, total, flush=True)
        self.assertEqual(failures, [], f'{len(failures)} misclassifications; first: {failures[:12]}')

    def test_cross_rejected_all_angles(self):
        failures = []
        for ratio in (0.15, 0.3, 0.5):
            for angle in range(0, 360, 5):
                for size in (48, 80, 160):
                    case = make_case('cross', angle, size, ratio, (640, 360), (0.5, 0.5))
                    for name, result in self.results(case):
                        if result.valid or result.cls != 0:
                            failures.append((name, ratio, angle, size, result.cls, result.reason))
        self.assertEqual(failures, [], f'{len(failures)} false positives; first: {failures[:12]}')

    def test_other_negative_shapes(self):
        for kind in ('line', 'pentagon', 'star'):
            for angle in range(0, 360, 5):
                for size in (48, 80, 160):
                    case = make_case(kind, angle, size, 1, (640, 360), (0, 0))
                    for name, result in self.results(case):
                        with self.subTest(kind=kind, angle=angle, size=size, model=name):
                            self.assertFalse(result.valid, result)
                            self.assertEqual(result.cls, 0)

    def test_ring_hole_is_not_concavity(self):
        case = make_case('ring', 45, 80, 1, (640, 360), (0, 0))
        self.assertGreater(len(case.contours), 1)
        for name, result in self.results(case):
            with self.subTest(model=name):
                self.assertTrue(result.valid, result)
                self.assertEqual(result.cls, 1)

    def test_translation_and_mirror_equivalence(self):
        for kind, aspect in KINDS:
            case = make_case(kind, 35, 80, aspect, (640, 360), (0.5, 0.5))
            variants = [case.runs, [(y, 1279 - right, 1279 - left) for y, left, right in case.runs],
                        [(y + 7, left + 31, right + 31) for y, left, right in case.runs]]
            for runs in variants:
                result = classify_summary(summarize_runs(runs), self.params)
                self.assertEqual((result.valid, result.cls), (True, case.expected_cls), result)
            mirrored = [contour * np.array([[[-1, 1]]]) + np.array([[[1279, 0]]])
                        for contour in case.contours]
            moved = [contour + np.array([[[31, 7]]]) for contour in case.contours]
            for contours in (case.contours, mirrored, moved):
                result = classify_contour(contours, self.params)
                self.assertEqual((result.valid, result.cls), (True, case.expected_cls), result)

    def test_summary_projection_tie_and_strip_boundaries(self):
        summary = summarize_runs([(3, 20, 25), (4, 22, 27), (5, 21, 26)])
        self.assertEqual(len(summary.support), 32)
        self.assertEqual(len(summary.strips), 180)
        self.assertEqual(summary.support[0], (True, 27, 4))
        self.assertEqual(summary.support[8], (True, 21, 5))
        self.assertEqual(summary.support[16], (True, 20, 3))
        self.assertEqual(summary.strips[0], (True, 20, 25))
        self.assertEqual(summary.strips[1], (True, 21, 27))
        self.assertEqual(summary.bounds, (20, 3, 27, 5))

    def test_empty_and_invalid_runs_rejected(self):
        for runs in ([], [(-1, 3, 7)], [(3, -1, 2)], [(719, 1279, 1280)], [(3, 9, 8)]):
            result = classify_summary(summarize_runs(runs), self.params)
            self.assertEqual((result.cls, result.valid), (0, False))

    def test_q8_directions_match_declared_sampling(self):
        expected = [[round(256 * math.cos(2 * math.pi * k / 32)),
                     round(256 * math.sin(2 * math.pi * k / 32))] for k in range(32)]
        self.assertEqual(self.params['directions_q8'], expected)
        self.assertEqual(self.params['word_bits']['projection_signed'], 24)

    def test_diagnostics_are_deterministic_and_cover_boundaries(self):
        first, second = list(diagnostic_cases()), list(diagnostic_cases())
        self.assertEqual([(name, c.runs) for name, c in first], [(name, c.runs) for name, c in second])
        self.assertEqual(len(first), 66)
        self.assertEqual(set(name for name, _ in first),
                         {'gap1', 'gap3', 'gap5', 'noise2', 'noise8', 'noise16',
                          'clip10pct', 'perspective5pct', 'perspective15pct',
                          'perspective30pct', 'decorative'})


if __name__ == '__main__':
    unittest.main()
