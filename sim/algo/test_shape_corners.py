"""Small corner loss must not send an otherwise rectangular outline to ellipse fitting."""
import unittest

from model.shape_corner_cases import clipped_corner_cases, corner_negative_cases, curve_fallback_summary
from model.shape_fixed import PARAMS, classify_summary, summarize_runs


class ClippedCornerTests(unittest.TestCase):
    def test_failed_rectangle_hypothesis_preserves_curve_fit(self):
        result = classify_summary(curve_fallback_summary(), PARAMS)
        self.assertEqual((result.valid, result.cls), (True, 1), result)

    def test_clipped_rectangle_corners_keep_rectangle_class(self):
        # Removing short-fifth-edge recovery must fail these real classifier calls.
        failures = []
        for name, case in clipped_corner_cases():
            result = classify_summary(summarize_runs(case.runs), PARAMS)
            if (result.valid, result.cls) != (True, 2):
                failures.append((name, result))
        self.assertEqual(failures, [], f'{len(failures)} failures; first {failures[:6]}')

    def test_bevel_does_not_bypass_rectangle_geometry(self):
        # Accepting any five-sided polygon, or skipping side-angle tests, is wrong.
        for name, case in corner_negative_cases():
            result = classify_summary(summarize_runs(case.runs), PARAMS)
            with self.subTest(case=name):
                self.assertEqual((result.valid, result.cls), (False, 0), result)


if __name__ == '__main__':
    unittest.main()
