"""Shape verification driver; compilation, timeout or failed assertions stay red."""
from pathlib import Path
import argparse
import os
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
RUN = ROOT / 'outflow/diagnostics'


def _invoke(command: list[str], timeout: float) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, cwd=ROOT, capture_output=True, text=True,
                              encoding='utf-8', errors='replace', timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or b''
        if isinstance(output, bytes):
            output = output.decode('utf-8', errors='replace')
        return subprocess.CompletedProcess(command, 124, output,
                                           f'timed out after {timeout:g}s\n')
    except OSError as exc:
        return subprocess.CompletedProcess(command, 2, '', str(exc) + '\n')


def run_tb(name: str, extra_sources: list[str] = []) -> subprocess.CompletedProcess[str]:
    path = Path(name)
    if path.suffix != '.v':
        path = ROOT / 'sim/algo' / (name + '.v')
    elif not path.is_absolute():
        path = ROOT / path
    if not path.is_file():
        return subprocess.CompletedProcess([name], 2, '', f'missing testbench: {path}\n')
    try:
        timeout = float(os.environ.get('SHAPE_TEST_TIMEOUT', '120'))
        if timeout <= 0:
            raise ValueError('non-positive timeout')
    except ValueError:
        return subprocess.CompletedProcess([name], 2, '', 'invalid test timeout\n')
    bin_dir = Path(os.environ.get('ALG_OSS_BIN', r'C:\iverilog\bin'))
    RUN.mkdir(parents=True, exist_ok=True)
    output = RUN / (path.stem + '.vvp')
    sources = [path, *sorted((ROOT / 'rtl/algo').glob('*.v')),
               ROOT / 'rtl/simple_dual_port_ram.v', ROOT / 'rtl/true_dual_port_ram.v']
    sources += [ROOT / 'rtl' / filename for filename in
                ('uart_rx.v', 'uart_tx.v', 'alg_cfg_uart.v',
                 'alg_cfg_sync.v', 'alg_cfg_telemetry.v')]
    sources += [Path(filename) for filename in extra_sources]
    compile_result = _invoke([str(bin_dir / 'iverilog.exe'), '-g2012', '-s', path.stem,
                              '-o', str(output), *map(str, dict.fromkeys(sources))], timeout)
    if compile_result.returncode:
        return subprocess.CompletedProcess(compile_result.args, compile_result.returncode,
                                           compile_result.stdout,
                                           'compile failed: ' + compile_result.stderr)
    result = _invoke([str(bin_dir / 'vvp.exe'), str(output), '-none'], timeout)
    transcript = result.stdout + result.stderr
    if result.returncode == 0 and re.search(r'\b(?:FAIL|ERROR)\b', transcript, re.I):
        return subprocess.CompletedProcess(result.args, 1, result.stdout,
                                           result.stderr + 'failed assertion in transcript\n')
    if result.returncode == 0 and 'SHAPE_TEST_PASS' not in transcript:
        return subprocess.CompletedProcess(result.args, 1, result.stdout,
                                           result.stderr + 'no success assertion marker\n')
    return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl', required=True, help='Testbench name or .v path')
    args = parser.parse_args(argv)
    result = run_tb(args.rtl)
    print(result.stdout, end='')
    print(result.stderr, end='', file=sys.stderr)
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
