"""Shape verification driver; compilation, timeout or failed assertions stay red."""
from pathlib import Path
import argparse
import os
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
RUN = ROOT / 'outflow/diagnostics'


def prepare_summary_vectors():
    sys.path.insert(0, str(ROOT / 'sim/algo'))
    from model.shape_cases import make_case
    from model.shape_fixed import summarize_runs
    a = make_case('triangle', 35, 48, 1, (240, 180), (0.5, 0.5)).runs
    b = make_case('ring', 0, 80, 1, (640, 360), (0, 0)).runs
    span = lambda slot, runs: [(1, slot, 0, y, left, right) for y, left, right in runs]
    phases = [[], [(0, 0, 0, 0, 0, 0)] + span(0, [(3,20,25),(4,22,27),(5,21,26),(719,0,1279)]),
              [(0,1,0,0,0,0)] + span(1,a), [(2,0,1,0,0,0)],
              [(0,2,0,0,0,0)] + span(2,list(reversed(a))),
              [(0,0,0,0,0,0)] + span(0,b), [(2,2,0,0,0,0)],
              [(0,0,0,0,0,0),(2,0,2,0,0,0)],
              [(0,3,0,0,0,0),(1,3,0,4,1279,1280),(2,0,3,0,0,0),(0,3,0,0,0,0)],
              [(3,0,0,200,10,20)], [(0,0,0,0,0,0)] + span(0,a)]
    slots = [[] for _ in range(8)]
    lines = [str(len(phases))]
    for commands in phases:
        for op, slot, other, y, left, right in commands:
            if op == 0: slots[slot] = []
            elif op == 1: slots[slot].append((y,left,right))
            elif op == 2: slots[slot] += slots[other]
            elif op == 3: slots = [[] for _ in range(8)]
        summaries = [summarize_runs(runs) for runs in slots]
        lines.append(f'{len(commands)} {sum(int(s.bad) << i for i,s in enumerate(summaries))}')
        lines += [' '.join(map(str, command)) for command in commands]
        for summary in summaries:
            words = [(int(v) << 25) | (y << 12) | x for v,x,y in summary.support]
            words += [(int(v) << 24) | (left << 12) | right for v,left,right in summary.strips]
            lines += [f'{word:07x}' for word in words]
    RUN.mkdir(parents=True, exist_ok=True)
    (RUN / 'shape_summary_vectors.txt').write_text('\n'.join(lines) + '\n', encoding='ascii')


def prepare_geometry_vectors():
    sys.path.insert(0, str(ROOT / 'sim/algo'))
    from model.shape_cases import make_case
    from model.shape_fixed import summarize_runs, classify_summary, PARAMS
    full = os.environ.get('SHAPE_GEOMETRY_FULL') == '1'
    angles = range(0, 360, 5) if full else (0, 15, 30, 40, 45, 60, 90, 135)
    cases = []
    for kind, aspect in (('ring', 1.0), ('circle', 1.0), ('triangle', 1.0),
                         ('square', 1.0), ('rectangle', 1.5), ('rectangle', 2.0),
                         ('cross', 0.15), ('cross', 0.3), ('cross', 0.5),
                         ('line', 1.0), ('pentagon', 1.0), ('star', 1.0)):
        for angle in angles:
            for size in (48, 80, 160):
                for center in (((240, 180), (640, 360), (1000, 500)) if full and
                               kind in ('ring', 'circle', 'triangle', 'square', 'rectangle')
                               else ((640, 360),)):
                    for phase in ((0.0, 0.0), (0.5, 0.5)):
                        cases.append((kind, angle, size, aspect, center, phase))
    cases.append(('flat_apex', 0, 0, 1.0, (640, 360), (0.0, 0.0)))
    lines = [str(len(cases))]
    for kind, angle, size, aspect, center, phase in cases:
        if kind == 'flat_apex':
            runs = []
            for y in range(500, 601):
                lx = 200 - ((y - 500) * 80) // 100
                rx = 200 + ((y - 500) * 80) // 100
                xs = [x for x in range(115, 285)
                      if abs(x-lx) <= 2 or abs(x-rx) <= 2 or
                      (y >= 598 and abs(x-200) <= 80)]
                a = b = xs[0]
                for x in xs[1:]:
                    if x > b + 1:
                        runs.append((y, a, b))
                        a = x
                    b = x
                runs.append((y, a, b))
            summary = summarize_runs(runs)
            expected = 3
        else:
            case = make_case(kind, angle, size, aspect, center, phase)
            summary = summarize_runs(case.runs)
            expected = case.expected_cls
        result = classify_summary(summary, PARAMS)
        if (result.cls if result.valid else 0) != expected:
            raise AssertionError(f'software geometry gate failed for {kind} {angle}')
        x0, y0, x1, y1 = summary.bounds
        lines.append(f'{expected} {x0} {x1} {y0} {y1} {int(summary.bad)}')
        lines.extend(f'{((int(v)<<25)|(y<<12)|x):07x}' for v, x, y in summary.support)
        lines.extend(f'{((int(v)<<24)|(left<<12)|right):07x}'
                     for v, left, right in summary.strips)
    RUN.mkdir(parents=True, exist_ok=True)
    vector_path = RUN / ('shape_geometry_vectors_full.txt' if full else 'shape_geometry_vectors.txt')
    vector_path.write_text('\n'.join(lines) + '\n', encoding='ascii')
    return vector_path


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
    if path.stem == 'tb_shp_summary':
        prepare_summary_vectors()
    geometry_vectors = prepare_geometry_vectors() if path.stem == 'tb_shp_geometry' else None
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
    sim_args = [str(bin_dir / 'vvp.exe'), str(output), '-none']
    if geometry_vectors is not None:
        sim_args.append('+VECTORS=' + str(geometry_vectors))
    result = _invoke(sim_args, timeout)
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
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument('--rtl', help='Testbench name or .v path')
    modes.add_argument('--model', action='store_true', help='Run the complete software acceptance gate')
    args = parser.parse_args(argv)
    if args.model:
        import unittest
        sys.path.insert(0, str(ROOT / 'sim/algo'))
        suite = unittest.defaultTestLoader.discover(str(ROOT / 'sim/algo'), pattern='test_shape_model.py')
        result = unittest.TextTestRunner(verbosity=2).run(suite)
        if not result.wasSuccessful():
            print('MODEL GATE FAIL')
            return 1
        from model.shape_cases import diagnostic_report
        import json
        params = json.loads((Path(__file__).parent / 'shape_params.json').read_text(encoding='utf-8'))
        diagnostic_report(params)
        print('MODEL GATE PASS')
        return 0
    result = run_tb(args.rtl)
    print(result.stdout, end='')
    print(result.stderr, end='', file=sys.stderr)
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
