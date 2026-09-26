# -*- coding: utf-8 -*-
"""What the real chain does to thin structure and to faint contrast.

The median-filter write-up that prompted this makes one claim that matters for
task 4: a median filter is good against salt-and-pepper noise but "not really
suited to pictures with many points and lines". This tool quantifies exactly
what that costs in THIS chain, off-line, without the board:

PART 1  the hard rule of a 3x3 median. A one-pixel-wide line or dot is erased
        completely, at ANY contrast, because six of the nine window values are
        background and the median is the fifth. Two pixels wide survives
        completely, at any contrast, for the mirror-image reason. Measured with
        the bit-exact port of rtl/median_filter_3x3_720p.v, not with a library.

PART 2  the contrast budget of the whole front end

            median -> gauss3 (x1 or x2) -> Sobel |Gx|+|Gy|

        driven with a one-dimensional step of contrast C. A (1,2,1)/4 stage is
        amplitude preserving for the step as a whole but spreads it over two
        pixels, so the per-pixel slope - and therefore the Sobel response -
        shrinks. This reports the response per unit contrast and the smallest C
        that can still cross each threshold floor the board can run.

PART 3  the same for the median alone: isolated +/-N impulses are removed for
        every N, which is the benefit side of PART 1.

Run:  python tools\\probe_contrast_budget.py
"""

import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_median_network as vmn  # noqa: E402  (the bit-exact RTL median)

BG = 32
FG = 200
W = H = 96


# ---------------------------------------------------------------- primitives
def median_rtl(img):
    """One 3x3 median, RTL timing and RTL out-of-range behaviour."""
    win = vmn.raster_windows(img)
    med = vmn.rtl_network(win)[:, :, 4]
    out = img.astype(np.int16).copy()
    ys, xs = np.mgrid[0:H, 0:W]
    mask = (xs >= 2) & (ys >= 2)          # the RTL valid_pipe test
    out[ys[mask] - 1, xs[mask] - 1] = med[mask]
    return out


def _conv1d(img, k, axis):
    pad = len(k) // 2
    shape = [(pad, pad) if i == axis else (0, 0) for i in range(img.ndim)]
    p = np.pad(img.astype(np.float64), shape, mode="edge")
    out = np.zeros(img.shape, dtype=np.float64)
    for i, kv in enumerate(k):
        sl = [slice(None)] * img.ndim
        sl[axis] = slice(i, i + img.shape[axis])
        out += kv * p[tuple(sl)]
    return out


def gauss_rtl(img, stages):
    """The 1-2-1/4 kernel of rtl/gauss3_720p.v, `stages` times in series."""
    out = img.astype(np.float64)
    k = np.array([0.25, 0.5, 0.25])
    for _ in range(stages):
        out = _conv1d(_conv1d(out, k, 0), k, 1)
    return out


def sobel_abs(img):
    """|Gx| + |Gy| with the weights rtl/edge_display_720p.v uses."""
    p = np.pad(img.astype(np.float64), 1, mode="edge")
    a, b, c = p[0:-2, 0:-2], p[0:-2, 1:-1], p[0:-2, 2:]
    d, e, f = p[1:-1, 0:-2], p[1:-1, 1:-1], p[1:-1, 2:]
    g, h, i = p[2:, 0:-2], p[2:, 1:-1], p[2:, 2:]
    gx = (c - a) + 2 * (f - d) + (i - g)
    gy = (g - a) + 2 * (h - b) + (i - c)
    return np.abs(gx) + np.abs(gy)


# ------------------------------------------------------------------ patterns
def pattern(kind):
    img = np.full((H, W), BG, dtype=np.int16)
    if kind == "line1":
        img[:, W // 2] = FG
    elif kind == "line2":
        img[:, W // 2:W // 2 + 2] = FG
    elif kind == "dot":
        img[H // 2, W // 2] = FG
    elif kind == "step":
        img[:, W // 2:] = FG
    else:
        raise ValueError(kind)
    return img


def peak_contrast(img):
    """Peak contrast away from the border.

    The first two rows and columns of the median output are the un-filtered
    input (the RTL valid_pipe test), and the pattern runs to the frame edge, so
    the border would answer with the raw feature value. Look inside it instead.
    """
    return int(np.asarray(img)[4:-4, 4:-4].max()) - BG


def part1():
    print("PART 1  3x3 median against thin structure (bit-exact RTL network)")
    print("        background %d, feature %d, contrast %d" % (BG, FG, FG - BG))
    print("        %-10s %-22s %-22s %-20s"
          % ("pattern", "after median", "median+gauss x2", "gauss x2 (no median)"))
    ok = True
    for kind, expect_med in (("line1", 0), ("line2", FG - BG), ("dot", 0)):
        raw = pattern(kind)
        with_m = median_rtl(raw)
        without = gauss_rtl(raw, 2)
        got = peak_contrast(with_m)
        print("        %-10s %-22d %-22d %d"
              % (kind, got, peak_contrast(gauss_rtl(with_m, 2)),
                 peak_contrast(without)))
        ok &= got == expect_med
    print("        => a one-pixel line and a one-pixel dot are gone at ANY contrast;")
    print("           two pixels wide passes at full contrast. The rule is width, not")
    print("           contrast: rank inside the window decides, not amplitude.")
    return ok


def part2():
    print("PART 2  contrast budget of median -> gauss xN -> Sobel |Gx|+|Gy|")
    print("        vertical step, peak response measured on the real kernels")
    print("        %-8s %-15s %-15s %-15s" % ("gauss", "C=64", "C=128", "response/C"))
    resp = {}
    for stages in (0, 1, 2):
        vals = {}
        for c in (64, 128):
            img = np.full((H, W), BG, dtype=np.int16)
            img[:, W // 2:] = BG + c
            chained = gauss_rtl(median_rtl(img), stages)
            vals[c] = int(np.round(sobel_abs(chained)[4:-4, 4:-4].max()))
        k = vals[128] / 128.0
        resp[stages] = k
        print("        %-8s %-15d %-15d %.3f" % ("x%d" % stages, vals[64], vals[128], k))
    print("        smallest step contrast that can cross the floor, k = response/C:")
    info = []
    for stages in (0, 1, 2):
        k = resp[stages]
        row = []
        for floor in (16, 20, 24, 32):
            need = int(np.ceil((floor + 1) / k))
            row.append("floor %d -> C >= %d" % (floor, need))
        print("          gauss x%d : %s" % (stages, ", ".join(row)))
        info.append((stages, k))
    loss = info[0][1] / info[2][1]
    print("        => the two denoise stages cost %.2fx of the gradient, so they raise"
          % loss)
    print("           the contrast a step needs by the same %.2fx. The median itself is"
          % loss)
    print("           free in amplitude: it only moves the step by one pixel.")
    ok = loss > 1.0
    return ok


def part3():
    print("PART 3  the benefit side: isolated impulses")
    ok = True
    for n in (16, 32, 64, 100):
        img = np.full((H, W), BG, dtype=np.int16)
        img[20, 20] += n
        img[40, 40] -= n
        after = median_rtl(img)
        left = int(after.max()) - BG, BG - int(after.min())
        print("        impulse +/-%3d -> residue +%d / -%d after the median"
              % (n, left[0], left[1]))
        ok &= left == (0, 0)
    print("        => any isolated spike is removed outright, which is what the")
    print("           despeckle stage relies on.")
    return ok


def main():
    ok = part1()
    print()
    ok &= part2()
    print()
    ok &= part3()
    print("\nRESULT: %s" % ("PASS" if ok else "FAIL"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
