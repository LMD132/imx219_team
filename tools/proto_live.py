# -*- coding: utf-8 -*-
"""
proto_live.py - PC-side prototype of the Ti60F225 board's edge pipeline.

Purpose
-------
The board implements a streaming pixel pipeline in Verilog.  Tuning it means
recompiling + JTAG + watching the panel, which is slow.  This tool mirrors the
*exact* algorithm of the current bitstream (tone-curve + hysteresis) in Python
so every knob can be tuned live on a webcam, then re-mirrored into Verilog.

Mirror map (RTL -> this file)
-----------------------------
  gray (BT.601 (77R+150G+29B)>>8, shift+add)     -> to_gray()
  median_filter_3x3_720p.v (3x3 median)          -> median stage
  gauss3_720p.v  x2 (binomial 1-2-1, /16)        -> gauss_stage(), E selects 0..2
  tone_curve_lut.v (modes 0..3, shift+add)       -> tone_curve()
  edge_display_720p.v 3x3 Sobel |Gx|+|Gy|        -> sobel()
  edge_display_720p.v threshold                  -> active = max(center>>S, T)
  edge_display_720p.v strong = mag >= 2*active   -> strong map
  edge_overlay_720p.v hysteresis (local form)    -> keep = edge & any strong nbr
  edge_overlay_720p.v despeckle (nbr>=D, counts
      neighbours of the RAW edge map, not of keep) -> despeckle()
  edge_overlay_720p.v bbox (min/max of prev frame,
      drawn on NEXT frame, red 2px, right half only) -> bbox
  edge_display_720p.v split (left=den2 gray,
      x==640 white, right=edges)                 -> canvas()

Fidelity notes
--------------
* Borders: the RTL gates the 3x3 window to x>=2 && y>=2 and passes the centre
  tap through outside it.  This file does the same (valid = x>=2 & y>=2).
* Bbox is drawn from the PREVIOUS frame's edge map (RTL latches at frame start).
* nbr_cnt counts the raw binary edge (before hysteresis), exactly like the RTL.
* This is for ALGORITHM tuning.  The webcam auto-exposes and has different
  noise from the IMX219 (fixed exposure).  Always re-tune on real board frames
  (--frames) before moving parameters into Verilog.

Usage
-----
  python tools\\proto_live.py --cam 0                 # live webcam
  python tools\\proto_live.py --frames <dir>          # replay real captures
  python tools\\proto_live.py --cam 0 --single --out work\\proto_live\\x.png
                                                      # headless self test
Keys (mirror the board's UART knobs)
  1/2   T -8 / +8          (noise floor)
  3/4   S -1 / +1  (0..8, 8 = adaptive term off)
  5/6   D -1 / +1  (despeckle neighbour min, 0 = off)
  7/8   E -1 / +1  (gauss stages 0..2)
  9/0   C -1 / +1  (tone curve mode 0..3)
  h     toggle hysteresis H
  s     save current frame + params to --out
  p     pause
  q/ESC quit
"""

import argparse, os, sys, time, json
import numpy as np
import cv2

# ---------------------------------------------------------------- stages

def to_gray(bgr):
    """BT.601: Y = (77R + 150G + 29B) >> 8  (shift-and-add in the RTL)."""
    r = bgr[:, :, 2].astype(np.int32)
    g = bgr[:, :, 1].astype(np.int32)
    b = bgr[:, :, 0].astype(np.int32)
    return np.clip(((r * 77) + (g * 150) + (b * 29)) >> 8, 0, 255).astype(np.uint8)


def median3x3(gray):
    return cv2.medianBlur(gray, 3)


def conv3(gray, k00, k01, k02, k10, k11, k12, k20, k21, k22):
    """3x3 integer convolution, zero padding.  Returns int32.

    The zero padding mirrors the RTL's zero-initialised line stores; the valid
    window (x>=2 && y>=2) is applied by the caller, exactly like the RTL gates
    window_valid.
    """
    pad = np.pad(gray, 1, mode="constant").astype(np.int32)
    return (pad[0:-2, 0:-2] * k00 + pad[0:-2, 1:-1] * k01 + pad[0:-2, 2:] * k02 +
            pad[1:-1, 0:-2] * k10 + pad[1:-1, 1:-1] * k11 + pad[1:-1, 2:] * k12 +
            pad[2:, 0:-2] * k20 + pad[2:, 1:-1] * k21 + pad[2:, 2:] * k22)


def gauss_stage(gray):
    """One binomial stage: gsum >> 4.  Border (x<2 or y<2) passes centre tap."""
    s = conv3(gray, 1, 2, 1, 2, 4, 2, 1, 2, 1)
    out = np.clip(s >> 4, 0, 255).astype(np.uint8)
    # RTL: outside the valid window (x>=2 && y>=2) the centre tap goes through.
    valid = np.zeros_like(gray, dtype=bool)
    valid[2:, 2:] = True
    return np.where(valid, out, gray)


def tone_curve(gray, mode):
    """tone_curve_lut.v.  Integer, shift-and-add semantics preserved.

    mode 0: y = x
    mode 1: x < 64 -> 2x ; else -> 128 + (171*(x-64)) >> 8
    mode 2: x < 96 -> 2x ; else -> 192 + (102*(x-96)) >> 8
    mode 3: x < 96 -> x + (x>>1) ; else -> 144 + (179*(x-96)) >> 8
    """
    x = gray.astype(np.int32)
    if mode == 0:
        return gray
    if mode == 1:
        d = x - 64
        lo = x * 2
        hi = 128 + ((171 * d) >> 8)
        return np.clip(np.where(x < 64, lo, hi), 0, 255).astype(np.uint8)
    if mode == 2:
        d = x - 96
        lo = x * 2
        hi = 192 + ((102 * d) >> 8)
        return np.clip(np.where(x < 96, lo, hi), 0, 255).astype(np.uint8)
    d = x - 96
    lo = x + (x >> 1)
    hi = 144 + ((179 * d) >> 8)
    return np.clip(np.where(x < 96, lo, hi), 0, 255).astype(np.uint8)


def sobel(gray):
    gx = conv3(gray, -1, 0, 1, -2, 0, 2, -1, 0, 1)
    gy = conv3(gray, -1, -2, -1, 0, 0, 0, 1, 2, 1)
    return (np.abs(gx) + np.abs(gy))


def valid_mask(shape):
    m = np.zeros(shape, dtype=bool)
    m[2:, 2:] = True
    return m


def threshold_maps(mag, center, floor, shift):
    """edge = valid & (mag >= max(center>>S, T));  strong = mag >= 2*active."""
    local = center >> shift
    active = np.maximum(local, np.full_like(center, floor, dtype=np.int32))
    edge = mag >= active
    strong = mag >= (active << 1)
    return edge, strong, active


def hysteresis(edge, strong):
    """keep = edge & (any of the 3x3 strong taps set).  Local Canny form."""
    strong3 = cv2.dilate(strong.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
    return edge & strong3


def despeckle(keep, raw_edge, dmin):
    """keep & (8-neighbour count of the RAW edge >= D).  D=0 bypasses."""
    if dmin <= 0:
        return keep
    nbr = conv3(raw_edge.astype(np.uint8), 1, 1, 1, 1, 1, 1, 1, 1, 1)
    nbr = nbr - raw_edge.astype(np.int32)          # exclude centre
    return keep & (nbr >= dmin)


def edge_stats(edge):
    """dens%, connected components, specks(<=3px) on the right half."""
    half = edge[:, edge.shape[1] // 2:]
    area = half.size
    dens = 100.0 * half.sum() / area
    n, lab, stats, cent = cv2.connectedComponentsWithStats(half.astype(np.uint8), 8)
    comps = n - 1
    specks = 0
    if comps > 0:
        specks = int((stats[1:, cv2.CC_STAT_AREA] <= 3).sum())
    return dens, comps, specks


def bbox_of(edge, half_x):
    ys, xs = np.nonzero(edge[:, half_x + 1:])
    if xs.size == 0:
        return None
    xs = xs + half_x + 1
    return (int(xs.min()), int(xs.max()), int(ys.min()), int(ys.max()))


def draw_box(canvas, box, half_x, thickness=2):
    if box is None:
        return
    x0, x1, y0, y1 = box
    x0 = max(x0, half_x + 1)
    x1 = min(x1, canvas.shape[1] - 1)
    canvas[y0:y0 + thickness, x0:x1 + 1, 2] = 255   # R channel only = red
    canvas[y1 - thickness + 1:y1 + 1, x0:x1 + 1, 2] = 255
    canvas[y0:y1 + 1, x0:x0 + thickness, 2] = 255
    canvas[y0:y1 + 1, x1 - thickness + 1:x1 + 1, 2] = 255


# ---------------------------------------------------------------- pipeline

def process(bgr, p, prev_edge, prev_box):
    """One frame through the mirror pipeline.  Returns canvas, stats, edge, box."""
    h, w = bgr.shape[:2]
    half_x = w // 2

    gray = to_gray(bgr)
    den1 = median3x3(gray)
    den2 = den1
    for _ in range(p["E"]):
        den2 = gauss_stage(den2)
    tone = tone_curve(den2, p["C"])

    mag = sobel(tone)
    center = tone.astype(np.int32)
    edge, strong, active = threshold_maps(mag, center, p["T"], p["S"])
    vmask = valid_mask(edge.shape)
    edge = edge & vmask
    strong = strong & vmask

    if p["H"]:
        keep = hysteresis(edge, strong)
    else:
        keep = edge
    edge_clean = despeckle(keep, edge, p["D"])
    edge_clean = edge_clean & vmask

    # stats
    dens, comps, specks = edge_stats(edge_clean)
    togg = 0.0
    if prev_edge is not None and prev_edge.shape == edge_clean.shape:
        half_diff = (edge_clean[:, half_x:] != prev_edge[:, half_x:]).mean()
        togg = 100.0 * half_diff

    # canvas: left = den2 gray, separator white, right = binary edges
    canvas = np.zeros((h, w, 3), dtype=np.uint8)
    canvas[:, :half_x] = np.stack([den2] * 3, axis=2)[:, :half_x]
    canvas[:, half_x] = 255
    canvas[:, half_x + 1:] = np.stack([edge_clean[:, half_x + 1:]] * 3, axis=2) * 255
    # red bbox from the PREVIOUS frame (RTL latches at frame boundary)
    if p["box"]:
        draw_box(canvas, prev_box, half_x)

    box = bbox_of(edge_clean, half_x)
    stats = dict(dens=dens, comps=comps, specks=specks, togg=togg)
    return canvas, stats, edge_clean, box


def status_line(p, st):
    return ("THR=%03d SH=%d DS=%d EN=%d CV=%d HY=%d | dens %5.2f%% comps %4d "
            "specks %3d toggle %5.2f%%") % (
        p["T"], p["S"], p["D"], p["E"], p["C"], p["H"],
        st["dens"], st["comps"], st["specks"], st["togg"])


# ---------------------------------------------------------------- io / loop

def iter_frames(cam, frames_dir):
    if frames_dir:
        names = sorted(n for n in os.listdir(frames_dir)
                       if n.lower().endswith((".png", ".jpg", ".jpeg", ".bmp")))
        if not names:
            raise SystemExit("no images in " + frames_dir)
        for n in names:
            yield os.path.join(frames_dir, n)
        return
    cap = cv2.VideoCapture(cam, cv2.CAP_DSHOW)
    if not cap.isOpened():
        raise SystemExit("cannot open camera %d" % cam)
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
    while True:
        ok, fr = cap.read()
        if not ok:
            time.sleep(0.05)
            continue
        yield fr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cam", type=int, default=0)
    ap.add_argument("--frames", type=str, default=None)
    ap.add_argument("--single", action="store_true", help="process one frame, exit")
    ap.add_argument("--out", type=str, default=r"work\proto_live")
    args = ap.parse_args()

    p = dict(T=24, S=8, D=3, E=2, C=1, H=1, box=True)
    prev_edge, prev_box = None, None
    os.makedirs(args.out, exist_ok=True)

    for i, src in enumerate(iter_frames(args.cam, args.frames)):
        if isinstance(src, str):
            bgr = cv2.imread(src)
            if bgr is None:
                continue
        else:
            bgr = src

        canvas, st, edge_clean, box = process(bgr, p, prev_edge, prev_box)
        prev_edge, prev_box = edge_clean, box

        print(status_line(p, st))

        if args.single:
            out = os.path.join(args.out, "proto_%03d.png" % i)
            cv2.imwrite(out, canvas)
            with open(os.path.join(args.out, "params.json"), "w", encoding="utf-8") as f:
                json.dump({"T": p["T"], "S": p["S"], "D": p["D"], "E": p["E"],
                           "C": p["C"], "H": p["H"], "file": str(src), "stats": st},
                          f, ensure_ascii=False, indent=1)
            print("saved", out)
            break

        cv2.imshow("proto_live (mirror of ti60f225_oob)", canvas)
        k = cv2.waitKey(1) & 0xFF
        if k in (27, ord("q")):
            break
        elif k == ord("1"):
            p["T"] = max(0, p["T"] - 8)
        elif k == ord("2"):
            p["T"] = min(255, p["T"] + 8)
        elif k == ord("3"):
            p["S"] = max(0, p["S"] - 1)
        elif k == ord("4"):
            p["S"] = min(8, p["S"] + 1)
        elif k == ord("5"):
            p["D"] = max(0, p["D"] - 1)
        elif k == ord("6"):
            p["D"] = min(6, p["D"] + 1)
        elif k == ord("7"):
            p["E"] = max(0, p["E"] - 1)
        elif k == ord("8"):
            p["E"] = min(2, p["E"] + 1)
        elif k == ord("9"):
            p["C"] = (p["C"] - 1) % 4
        elif k == ord("0"):
            p["C"] = (p["C"] + 1) % 4
        elif k == ord("h"):
            p["H"] = 1 - p["H"]
        elif k == ord("b"):
            p["box"] = not p["box"]
        elif k == ord("s"):
            out = os.path.join(args.out, "frame_%05d.png" % i)
            cv2.imwrite(out, canvas)
            with open(os.path.join(args.out, "params_%05d.json" % i), "w",
                      encoding="utf-8") as f:
                json.dump(p, f, ensure_ascii=False, indent=1)
            print("saved", out, status_line(p, st))

    cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
