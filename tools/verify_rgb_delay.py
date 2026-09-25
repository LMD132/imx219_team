r"""Verify rtl/rgb_delay_720p.v without the board.

Part A - cycle-accurate model of the RTL.
    A transliteration of rgb_delay_720p.v driven with synthetic 720p frames.
    It asserts the two things the module promises:
      1. the output pixel is the input pixel DELAY_PIX active pixels earlier,
         for every pixel of every frame (no special case in the picture);
      2. the first DELAY_PIX active pixels of every frame are black, and the
         rest of the frame is never black.
    And one readable extra: a marker at (row, col) comes out at
    (row + LINE_DELAY, col + PIXEL_DELAY).

Part B - what the board actually showed (informational, needs a capture).
    The existing bitstream has no colour overlay yet, but it does show the grey
    picture in the left half and the binary edge map in the right half of the
    same frame. Both halves are the same scene rows, so a horizontal feature
    (table edge, wall/floor line) must land on the same y in both halves. This
    measures that offset by correlating the two row profiles, which is the only
    ground truth available while the board is off the desk. It is reported, not
    asserted: a capture without a horizontal feature simply has no answer.

Usage:
    python tools/verify_rgb_delay.py
    python tools/verify_rgb_delay.py --capture work/capture/ab3_b1
"""

import argparse
import os
import re
import sys

import numpy as np

RTL = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "rtl", "rgb_delay_720p.v")


def read_params(path=RTL):
    """Pull the three parameter defaults out of the RTL so the model and the
    hardware cannot drift apart silently."""
    text = open(path, "r", encoding="utf-8").read()
    out = {}
    for name in ("IMAGE_WIDTH", "LINE_DELAY", "PIXEL_DELAY"):
        m = re.search(r"parameter\s+integer\s+%s\s*=\s*(\d+)" % name, text)
        if not m:
            raise SystemExit("cannot find parameter %s in %s" % (name, path))
        out[name] = int(m.group(1))
    m = re.search(r"localparam\s+integer\s+REG_STAGES\s*=\s*(\d+)", text)
    if not m:
        raise SystemExit("cannot find REG_STAGES in %s" % path)
    out["REG_STAGES"] = int(m.group(1))
    return out


class RgbDelay:
    """One-to-one transliteration of rgb_delay_720p.v, one call = one clock.

    Every assignment uses the value the register had at the start of the
    cycle, which is what non-blocking assignment does in the RTL.
    """

    def __init__(self, image_width, line_delay, pixel_delay, reg_stages):
        self.width = image_width
        self.delay_pix = line_delay * image_width + pixel_delay
        self.reg_stages = reg_stages
        self.depth = self.delay_pix - self.reg_stages
        # Plain tuples in a flat list: this runs a few million cycles, and
        # element-wise numpy is far slower than a tuple compare.
        self.store = [(0, 0, 0)] * self.depth
        self.read_rgb = (0, 0, 0)
        self.prev_de = 0
        self.prev_vs = 0
        self.filled = 0
        self.filled_d1 = 0
        self.filled_d2 = 0
        self.waddr = 0
        self.out_rgb = (0, 0, 0)
        self.out_de = 0

    def step(self, in_vs, in_de, rgb):
        # --- what the sequential blocks latch at the end of this cycle ---
        frame_start = 1 if (in_vs and not self.prev_vs) else 0
        read_rgb_next = self.store[self.waddr]          # read before write
        filled_next, waddr_next = self.filled, self.waddr
        if frame_start:
            filled_next, waddr_next = 0, 0
        elif in_de:
            if self.waddr == self.depth - 1:
                filled_next, waddr_next = 1, 0
            else:
                filled_next, waddr_next = self.filled, self.waddr + 1
        if in_de:
            self.store[self.waddr] = rgb
        out_rgb_next = self.read_rgb if self.filled_d1 else (0, 0, 0)

        self.prev_de, self.prev_vs = in_de, in_vs
        self.filled_d1 = self.filled          # old value, before this cycle
        self.filled, self.waddr = filled_next, waddr_next
        self.read_rgb = read_rgb_next
        self.out_rgb, self.out_de = out_rgb_next, in_de
        return self.out_de, self.out_rgb


def pixel_of(index, frame):
    """A value that is unique per (index, frame) inside one frame, so a wrong
    tap cannot look right by accident."""
    return ((index * 3 + frame * 11) % 251,
            (index * 7 + frame * 29) % 241,
            (index // 256 + frame * 5) % 239)


def part_a(params, frames=3):
    w = params["IMAGE_WIDTH"]
    h = 720
    model = RgbDelay(w, params["LINE_DELAY"], params["PIXEL_DELAY"],
                     params["REG_STAGES"])
    delay = model.delay_pix
    hist, mismatches, black_ok, first_nonblack = [], 0, True, {}
    out_idx = 0
    for frame in range(frames):
        # vs pulse in the blanking interval, then the active lines
        model.step(1, 0, (0, 0, 0))
        model.step(0, 0, (0, 0, 0))
        for k in range(w * h):
            rgb = pixel_of(k, frame)
            hist.append(rgb)
            _, got = model.step(0, 1, rgb)
            if k < delay:
                if got != (0, 0, 0):
                    black_ok = False
            else:
                first_nonblack.setdefault(frame, k)
                want = hist[out_idx - delay]
                if got != want:
                    mismatches += 1
                    if mismatches <= 3:
                        print("  mismatch: frame %d k %d got %s want %s"
                              % (frame, k, got, want))
            out_idx += 1

    # marker test on a fresh model: one bright pixel, no other content
    model = RgbDelay(w, params["LINE_DELAY"], params["PIXEL_DELAY"],
                     params["REG_STAGES"])
    row, col = 100, 300
    model.step(1, 0, (0, 0, 0))
    model.step(0, 0, (0, 0, 0))
    seen = []
    for k in range(w * h):
        rgb = (0, 0, 0) if (k // w, k % w) != (row, col) else (255, 255, 255)
        _, got = model.step(0, 1, rgb)
        if got != (0, 0, 0):
            seen.append((k // w, k % w, got))

    print("Part A - cycle-accurate model of rtl/rgb_delay_720p.v")
    print("  parameters      : IMAGE_WIDTH=%d LINE_DELAY=%d PIXEL_DELAY=%d"
          % (w, params["LINE_DELAY"], params["PIXEL_DELAY"]))
    print("  DELAY_PIX       : %d  (store depth %d + %d registers)"
          % (delay, model.depth, params["REG_STAGES"]))
    print("  frames simulated: %d  (%d active pixels, %d output pixels)"
          % (frames, w * h * frames, out_idx))
    print("  black border    : %s, opened at k=%s in every frame"
          % ("exactly k < DELAY_PIX" if black_ok else "WRONG",
             ",".join(str(first_nonblack.get(f)) for f in range(frames))))
    print("  content errors  : %d" % mismatches)
    marker = "no marker came out" if not seen else \
        "marker (%d,%d) -> (%d,%d)" % (row, col, seen[0][0], seen[0][1])
    expect = (row + params["LINE_DELAY"], col + params["PIXEL_DELAY"])
    ok = (mismatches == 0 and black_ok and seen
          and (seen[0][0], seen[0][1]) == expect)
    print("  marker          : %s (expected %s)" % (marker, expect))
    print("  PART A          : %s" % ("PASS" if ok else "FAIL"))
    return ok


def part_b(capture_dir, max_shift=24):
    import cv2
    print("\nPart B - row alignment measured on a real capture")
    print("  capture         : %s" % capture_dir)
    frames = sorted(f for f in os.listdir(capture_dir) if f.endswith(".png"))
    if not frames:
        print("  no PNG in that directory, skipped")
        return None
    best = None
    for name in frames[:3]:
        img = cv2.imread(os.path.join(capture_dir, name), cv2.IMREAD_COLOR)
        if img is None:
            continue
        h, w = img.shape[:2]
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(np.float64)
        half = w // 2
        left = gray[:, 8:half - 8]
        right = gray[:, half + 8:w - 8]
        # left: row-to-row difference is the grey picture's row profile; rows
        # 1..h-1 so that both profiles have the same length
        lp = np.abs(np.diff(left, axis=0)).mean(axis=1)
        # right: the binary map's edge density per row
        rp = (right > 127).mean(axis=1)[1:]
        lp = (lp - lp.mean()) / (lp.std() + 1e-9)
        rp = (rp - rp.mean()) / (rp.std() + 1e-9)
        shifts = range(-max_shift, max_shift + 1)
        scores = []
        for s in shifts:
            if s >= 0:
                a, b = lp[s:], rp[:len(rp) - s]
            else:
                a, b = lp[:len(lp) + s], rp[-s:]
            scores.append(float((a * b).mean()))
        scores = np.array(scores)
        i = int(np.argmax(scores))
        best_shift = list(shifts)[i]
        peak = scores[i]
        second = np.max(np.delete(scores, i))
        if best is None or peak > best[2]:
            best = (name, best_shift, peak, second)
    if best is None:
        print("  no readable frame, skipped")
        return None
    name, shift, peak, second = best
    print("  best frame      : %s" % name)
    print("  best shift      : %+d rows (left grey relative to right edges)"
          % shift)
    print("  corr peak       : %.3f  (runner-up %.3f)" % (peak, second))
    if peak < 0.15 or peak - second < 0.03:
        print("  verdict         : no reliable horizontal feature in this "
              "capture - measure it again on a frame with the table edge or "
              "the wall/floor line across the whole picture")
    else:
        print("  verdict         : measured, see docs/tuning_findings.md. This "
              "is the pre-overlay bitstream: it says how the two halves of the "
              "current picture sit relative to each other, which is the "
              "convention every 3x3 level in the chain follows.")
    return shift


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--capture", default="work/capture/ab3_b1",
                    help="directory of board frames (default work/capture/ab3_b1)")
    ap.add_argument("--skip-b", action="store_true")
    args = ap.parse_args()
    params = read_params()
    ok = part_a(params)
    if not args.skip_b and os.path.isdir(args.capture):
        part_b(args.capture)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
