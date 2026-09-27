"""Generate the alg_blend.v LUT and the testbench golden vectors.

Single source of truth: the tuning behaviour of the Python reference
`live_tune.py` (same repo, `FPGA-Python-main`), lines 166-168:

    # 时间域滤波: TEMP>0 时 alpha=1-temp/100 (temp=30 -> alpha=0.7 保留70%当前帧)
    alpha = 1.0 - temp_val / 100.0 if temp_val > 0 else 0.0
    gray_t = temporal_blend(prev_gray_n, gray_n, alpha)

and `edge_pipeline.py:338`:

    def temporal_blend(prev, cur, alpha):
        if prev is None or alpha <= 0:
            return cur
        return np.clip(alpha * cur.astype(np.float32)
                       + (1 - alpha) * prev.astype(np.float32), 0, 255).astype(np.uint8)

Two things come out of here:

  1. the TEMP -> alpha(Q8) table that alg_blend.v embeds verbatim, printed to stdout;
  2. sim/algo/blend_golden.txt, the float32 reference output for a sampled set of
     (cur, prev) pairs at every TEMP value, which tb_alg_blend.v compares against.

Usage:
    python gen_blend_golden.py [out.txt]   # default out: stdout only
                                         # writes the golden vectors to out.txt
                                         # and prints the Verilog case table
"""

import os
import sys

import numpy as np

TEMP_MAX = 90          # live_tune.py: cv2.createTrackbar(TRACK_TEMP, WINDOW, 0, 90, ...)
Q = 8                  # fractional bits of the fixed point alpha


def alpha_q8(temp):
    """The Q8 fixed point alpha alg_blend.v uses: round((100-TEMP)*256/100)."""
    if temp <= 0:
        return 0
    return max(0, min(255, int(round((100 - temp) * (1 << Q) / 100.0))))


def py_ref(temp, cur, prev):
    """The Python reference, verbatim semantics (float32, then a truncating cast)."""
    if temp <= 0:
        return cur
    a = 1.0 - temp / 100.0
    v = a * cur.astype(np.float32) + (1.0 - a) * prev.astype(np.float32)
    return np.clip(v, 0, 255).astype(np.uint8)


def sample_pairs():
    """All-0..255 diagonal, all-0..255 anti-diagonal, and a fixed random draw."""
    k = np.arange(256, dtype=np.uint8)
    pairs = [(k, k), (k, np.uint8(255) - k)]
    rng = np.random.RandomState(20260927)
    pairs.append((rng.randint(0, 256, 256).astype(np.uint8),
                  rng.randint(0, 256, 256).astype(np.uint8)))
    cur = np.concatenate([p[0] for p in pairs])
    prev = np.concatenate([p[1] for p in pairs])
    return cur, prev


def verilog_lut():
    lines = []
    for t in range(0, TEMP_MAX + 1, 5):
        row = " ".join("7'd%2d: alpha_q8 = 8'd%3d;" % (t + i, alpha_q8(t + i))
                       for i in range(5) if t + i <= TEMP_MAX)
        lines.append("                " + row)
    return lines


def main(argv):
    out = argv[1] if len(argv) > 1 else None

    cur, prev = sample_pairs()
    n = 0
    if out:
        with open(out, "w", newline="\n") as fh:
            for temp in range(0, TEMP_MAX + 1):
                ref = py_ref(temp, cur, prev)
                a8 = alpha_q8(temp)
                for i in range(cur.size):
                    fh.write("%d %d %d %d %d\n"
                             % (temp, a8, int(cur[i]), int(prev[i]), int(ref[i])))
                    n += 1
        print("// golden vectors: %d lines -> %s" % (n, out))
    print("// TEMP -> alpha(Q8):")
    for line in verilog_lut():
        print(line)

    # The exhaustive fidelity statement, over every (cur, prev) pair.
    cc, pp = np.meshgrid(np.arange(256, dtype=np.uint8), np.arange(256, dtype=np.uint8),
                         indexing="ij")
    exact, worst = [], 0
    for temp in range(0, TEMP_MAX + 1):
        a8 = alpha_q8(temp)
        if a8 <= 0:
            rtl = cc
        else:
            rtl = ((np.uint16(a8) * cc.astype(np.uint16)
                    + np.uint16(256 - a8) * pp.astype(np.uint16)) >> Q).astype(np.uint8)
        d = np.abs(py_ref(temp, cc, pp).astype(int) - rtl.astype(int))
        worst = max(worst, int(d.max()))
        if d.max() == 0:
            exact.append(temp)
    print("// exhaustive 0..90 x 256 x 256: max|RTL - python| = %d LSB" % worst)
    print("// bit exact at TEMP = %s" % exact)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
