# -*- coding: utf-8 -*-
"""Median network equivalence check for rtl/median_filter_3x3_720p.v.

PROBLEM
    The production 3x3 median is a nine-phase odd-even transposition network:
    the generate loop at rtl/median_filter_3x3_720p.v:164-184 runs 9 phases over
    the 9 window registers and the result is tapped at sort_stage[9][4].
    "Nine phases sort nine elements" is standard, but standard is not evidence,
    so this tool reproduces the network bit-exactly and measures it.

PART A  bit-exact port of the generate loop, checked
          - exhaustively over all 4^9 windows,
          - on random 8-bit windows,
          - on the adversarial window that breaks the published "3-cycle
            median" code (it takes min-of-row-mins / med-of-row-meds /
            max-of-row-maxes, i.e. the mirror image of the right answer),
          - for every phase count 1..9, to show the depth is not padded.
        Also checks the five-step comparator tree from the "median filter in
        FPGA" write-up, which is the correct fast method.

PART B  the same network driven in raster order over a real image (a captured
        HDMI frame if present, else a reference-video frame, else synthetic),
        compared pixel by pixel against cv2.medianBlur at the offset that the
        line buffer plus register pipeline implies. This also pins down the
        one-pixel spatial offset of the median stream against the gray stream.

Exit code 0 when every check passes.
"""

import os
import sys
import glob

import numpy as np

try:
    import cv2
except ImportError:  # pragma: no cover
    cv2 = None

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
N_PHASE = 9
N_ELEM = 9
TAP = 4  # sort_stage[9][4] is the median tap in the RTL


# --------------------------------------------------------------------------
# bit-exact port of the RTL generate loop (median_filter_3x3_720p.v:164-184)
# --------------------------------------------------------------------------
def rtl_network(a, phases=N_PHASE):
    """a is (..., 9); returns the (..., 9) network state after `phases` phases."""
    cur = np.asarray(a, dtype=np.int16).copy()
    for phase in range(phases):
        nxt = cur.copy()
        for index in range(N_ELEM):
            if index < N_ELEM - 1 and (index + phase) % 2 == 0:
                nxt[..., index] = np.minimum(cur[..., index], cur[..., index + 1])
            elif index > 0 and (index - 1 + phase) % 2 == 0:
                nxt[..., index] = np.maximum(cur[..., index - 1], cur[..., index])
        cur = nxt
    return cur


def _sorted_rows(w):
    """(N, 9) -> (N, 3, 3) with every row sorted ascending."""
    return np.sort(np.asarray(w, dtype=np.int16).reshape(-1, 3, 3), axis=-1)


def article3_formula(w):
    """min-of-mins / med-of-meds / max-of-maxes, then the median of those three.

    This is what the published "3-cycle median" Verilog actually computes; the
    comparator that should take the three row maxima is wired to the row minima.
    """
    r = _sorted_rows(w)
    three = np.stack([r[:, :, 0].min(axis=-1),
                      np.median(r[:, :, 1], axis=-1),
                      r[:, :, 2].max(axis=-1)], axis=-1)
    return np.sort(three, axis=-1)[:, 1].astype(np.int16)


def article4_tree(w):
    """five-step comparator tree: max(mins), med(meds), min(maxes) -> median."""
    r = _sorted_rows(w)
    three = np.stack([r[:, :, 0].max(axis=-1),
                      np.median(r[:, :, 1], axis=-1),
                      r[:, :, 2].min(axis=-1)], axis=-1)
    return np.sort(three, axis=-1)[:, 1].astype(np.int16)


def part_a():
    print("PART A  network equivalence (bit-exact port of the RTL generate loop)")
    ok = True

    # exhaustive over all 4^9 windows: enough values to expose any swap error
    import itertools
    vals = np.array(list(itertools.product(range(4), repeat=N_ELEM)), dtype=np.int16)
    out = rtl_network(vals)[:, TAP]
    exp_vals = np.sort(vals, axis=1)[:, TAP]
    bad = int(np.count_nonzero(out != exp_vals))
    print("  exhaustive 4^9 windows : {:>7} windows, {} mismatch".format(len(vals), bad))
    ok &= bad == 0

    # random full-range (unsigned 8-bit) windows
    rng = np.random.default_rng(20260926)
    rnd = rng.integers(0, 256, size=(400000, N_ELEM), dtype=np.int16)
    out = rtl_network(rnd)[:, TAP]
    exp_rnd = np.sort(rnd, axis=1)[:, TAP]
    bad = int(np.count_nonzero(out != exp_rnd))
    print("  random 8-bit windows   : {:>7} windows, {} mismatch".format(len(rnd), bad))
    ok &= bad == 0

    # adversarial window from the "3-cycle median" write-up
    adv = np.array([[1, 2, 100, 3, 4, 101, 102, 103, 104]], dtype=np.int16)
    got = int(rtl_network(adv)[0, TAP])
    print("  adversarial window     : RTL median = {}, true median = 100".format(got))
    ok &= got == 100

    # how much depth is actually needed
    print("  phase needed           :", end="")
    for p in range(1, N_PHASE + 1):
        bad = int(np.count_nonzero(rtl_network(vals, p)[:, TAP] != exp_vals))
        print(" {}{}".format(p, "" if bad == 0 else "(x{})".format(bad)), end="")
    print()
    eight = int(np.count_nonzero(rtl_network(vals, N_PHASE - 1)[:, TAP] != exp_vals))
    print("  => 8 phases wrong on {}, 9 phases exact: depth is not padded".format(eight))
    ok &= eight > 0

    # published formulas
    bad3 = int(np.count_nonzero(article3_formula(vals) != exp_vals))
    bad4 = int(np.count_nonzero(article4_tree(vals) != exp_vals))
    print("  write-up A (min/min/max): {} mismatch on 4^9  -> mirror image, broken".format(bad3))
    print("  write-up B (5-step tree): {} mismatch on 4^9  -> correct".format(bad4))
    ok &= bad4 == 0
    return ok


# --------------------------------------------------------------------------
# PART B: drive the network in raster order, exactly as the RTL registers do
# --------------------------------------------------------------------------
def raster_windows(gray):
    """(H, W, 9) window set in the RTL register order.

    RTL order is top_left, top_center, top_now, mid_*, bot_*, current, and the
    register chain makes those columns x-2, x-1, x of rows y-2, y-1, y. The
    window is therefore centred on (x-1, y-1), not on (x, y).
    """
    h, w = gray.shape
    pad = np.zeros((h + 2, w + 2), dtype=np.int16)
    pad[2:, 2:] = gray
    win = np.empty((h, w, N_ELEM), dtype=np.int16)
    idx = 0
    for dy in range(3):
        for dx in range(3):
            win[:, :, idx] = pad[dy:dy + h, dx:dx + w]
            idx += 1
    return win


def pick_source():
    caps = sorted(glob.glob(os.path.join(REPO, "work", "capture", "*", "frame_00.png")))
    if caps:
        return "capture", caps[:5]
    vids = sorted(glob.glob(os.path.join(REPO, "work", "ref_video", "*.mp4")))
    if vids and cv2 is not None:
        return "ref_video", vids[:1]
    return "synthetic", []


def frames_from(kind, paths):
    out = []
    if kind == "capture":
        for p in paths:
            img = cv2.imread(p, cv2.IMREAD_COLOR)
            if img is not None:
                out.append(cv2.cvtColor(img, cv2.COLOR_BGR2GRAY))
    elif kind == "ref_video":
        cap = cv2.VideoCapture(paths[0])
        n = 0
        while n < 5:
            ok, img = cap.read()
            if not ok:
                break
            if n % 30 == 0:
                out.append(cv2.cvtColor(img, cv2.COLOR_BGR2GRAY))
            n += 1
        cap.release()
    if not out:
        h, w = 720, 1280
        yy, xx = np.mgrid[0:h, 0:w]
        base = ((xx * 7 + yy * 3) % 256).astype(np.uint8)
        out.append(base)
        out.append((np.abs(np.sin(xx / 9.0)) * 200 + np.abs(np.cos(yy / 7.0)) * 55).astype(np.uint8))
    return out


def part_b():
    print("PART B  raster-order drive against cv2.medianBlur")
    kind, paths = pick_source()
    frames = frames_from(kind, paths)
    print("  image source           : {} ({} frame(s))".format(kind, len(frames)))
    total = 0
    bad_np = bad_cv = 0
    for f in frames:
        if cv2 is None:
            break
        win = raster_windows(f)
        h, w = f.shape
        ys, xs = np.mgrid[0:h, 0:w]
        mask = (xs >= 2) & (ys >= 2)            # exactly the RTL valid_pipe test
        winv = win[mask]
        out = rtl_network(winv)[:, TAP]
        ref_np = np.median(winv, axis=1).astype(np.int16)
        ref_cv = cv2.medianBlur(f, 3)[ys[mask] - 1, xs[mask] - 1]
        total += len(winv)
        bad_np += int(np.count_nonzero(out != ref_np))
        bad_cv += int(np.count_nonzero(out != ref_cv))
    print("  windows checked        : {:>9}".format(total))
    print("  vs numpy median        : {} mismatch".format(bad_np))
    print("  vs cv2.medianBlur      : {} mismatch  (at (x-1, y-1))".format(bad_cv))
    ok = bad_np == 0 and bad_cv == 0
    if ok:
        print("  => network is a real median, and the median stream sits one pixel")
        print("     up-left of the gray stream it travels with.")
    return ok


def main():
    skip_b = "--skip-b" in sys.argv
    ok_a = part_a()
    ok_b = True
    if not skip_b:
        ok_b = part_b()
    print("\nRESULT: PART A {}, PART B {}".format("PASS" if ok_a else "FAIL",
                                                  "skipped" if skip_b else ("PASS" if ok_b else "FAIL")))
    return 0 if (ok_a and ok_b) else 1


if __name__ == "__main__":
    sys.exit(main())
