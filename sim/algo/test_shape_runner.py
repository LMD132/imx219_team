"""Real subprocess tests: a failed/silent simulation must never become PASS."""
from pathlib import Path
import os
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
DRIVER = ROOT / 'sim/algo/model/check_shape.py'
FIXTURES = ROOT / 'sim/algo/fixtures/runner'


class RunnerTests(unittest.TestCase):
    def cli(self, fixture, timeout='120'):
        env = dict(os.environ, ALG_OSS_BIN=r'C:\iverilog\bin',
                   SHAPE_TEST_TIMEOUT=timeout, PYTHONDONTWRITEBYTECODE='1')
        return subprocess.run([sys.executable, str(DRIVER), '--rtl', str(fixture)],
                              cwd=ROOT, env=env, capture_output=True, text=True,
                              encoding='utf-8', errors='replace', timeout=10)

    def test_successful_real_assertions_return_zero(self):
        result = self.cli(FIXTURES / 'tb_runner_pass.v')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('SHAPE_TEST_PASS', result.stdout)

    def test_missing_testbench_is_failure(self):
        result = self.cli(FIXTURES / 'tb_runner_missing.v')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing testbench', result.stdout + result.stderr)

    def test_compile_error_is_failure(self):
        result = self.cli(FIXTURES / 'tb_runner_compile_error.v')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('compile failed', result.stdout + result.stderr)

    def test_fatal_simulation_is_failure(self):
        result = self.cli(FIXTURES / 'tb_runner_fail.v')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('FAIL intended assertion', result.stdout + result.stderr)

    def test_printed_failure_with_zero_exit_is_failure(self):
        result = self.cli(FIXTURES / 'tb_runner_false_pass.v')
        self.assertNotEqual(result.returncode, 0)

    def test_silent_zero_exit_is_failure(self):
        result = self.cli(FIXTURES / 'tb_runner_silent.v')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no success assertion marker', result.stdout + result.stderr)

    def test_timeout_is_failure(self):
        result = self.cli(FIXTURES / 'tb_runner_timeout.v', '0.25')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('timed out', result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
