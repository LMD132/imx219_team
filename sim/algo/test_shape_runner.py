"""Real subprocess tests: a failed/silent simulation must never become PASS."""
from pathlib import Path
from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import os
import subprocess
import sys
import unittest
from unittest import mock

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

    def all_case(self, fixture, model_rc=0, timeout='120'):
        spec = importlib.util.spec_from_file_location('shape_driver_all_test', DRIVER)
        assert spec is not None and spec.loader is not None
        driver = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(driver)
        output = io.StringIO()
        with mock.patch.object(driver, 'ALL_RTL', (str(fixture),), create=True), \
             mock.patch.object(driver, 'run_model_gate', return_value=model_rc, create=True), \
             mock.patch.dict(os.environ, ALG_OSS_BIN=r'C:\iverilog\bin',
                             SHAPE_TEST_TIMEOUT=timeout, PYTHONDONTWRITEBYTECODE='1'), \
             redirect_stdout(output), redirect_stderr(output):
            try:
                code = driver.main(['--all'])
            except SystemExit as exc:
                code = exc.code
        return code, output.getvalue()

    def test_all_success_requires_real_assertion(self):
        code, output = self.all_case(FIXTURES / 'tb_runner_pass.v')
        self.assertEqual(code, 0, output)
        self.assertIn('ALL PASS', output)

    def test_all_propagates_model_failure(self):
        code, output = self.all_case(FIXTURES / 'tb_runner_pass.v', model_rc=1)
        self.assertNotEqual(code, 0)
        self.assertIn('MODEL GATE FAIL', output)
        self.assertNotIn('ALL PASS', output)

    def test_all_propagates_each_real_runner_failure(self):
        for name, needle, timeout in (
            ('tb_runner_missing.v', 'missing testbench', '120'),
            ('tb_runner_compile_error.v', 'compile failed', '120'),
            ('tb_runner_fail.v', 'FAIL intended assertion', '120'),
            ('tb_runner_false_pass.v', 'failed assertion in transcript', '120'),
            ('tb_runner_silent.v', 'no success assertion marker', '120'),
            ('tb_runner_timeout.v', 'timed out', '0.25'),
        ):
            with self.subTest(name=name):
                code, output = self.all_case(FIXTURES / name, timeout=timeout)
                self.assertNotEqual(code, 0)
                self.assertIn(needle, output)
                self.assertNotIn('ALL PASS', output)


if __name__ == '__main__':
    unittest.main()
