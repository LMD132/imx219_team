"""Probe a UVC capture device format by format and report what actually arrives.

The point is to separate "the card cannot be opened" from "the card opens but
hands out black frames" - two failures that look identical in a screenshot but
need completely different fixes.

Usage:
    python tools\\probe_uvc.py                       # scan every index, default format
    python tools\\probe_uvc.py --device 1 --formats  # try the usual formats, dump PNGs

Notes learned the hard way:
  * Windows' Camera app takes the device exclusively; while it is open every
    open() from another process fails. Close it first.
  * A card with no locked HDMI input often still reports 1280x720/1920x1080 and
    happily opens - it just returns black (or its own logo) frames.
"""

from __future__ import annotations

import argparse
import os
import time

import cv2

FORMATS = [
    ("MJPG", 1280, 720, 60),
    ("YUY2", 1280, 720, 60),
    ("MJPG", 1920, 1080, 30),
    (None, 640, 480, 30),
]


def open_with_retry(index: int, fourcc: str | None, width: int, height: int, fps: int,
                    tries: int = 15, delay: float = 0.3) -> cv2.VideoCapture | None:
    cap = cv2.VideoCapture(index, cv2.CAP_DSHOW)
    if not cap.isOpened():
        return None
    if fourcc:
        cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*fourcc))
    cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
    cap.set(cv2.CAP_PROP_FPS, fps)
    for _ in range(tries):
        ok, frame = cap.read()
        if ok and frame is not None:
            return cap
        time.sleep(delay)
    cap.release()
    return None


def scan(max_index: int) -> None:
    for index in range(max_index):
        cap = cv2.VideoCapture(index, cv2.CAP_DSHOW)
        if not cap.isOpened():
            cap.release()
            continue
        ok, frame = cap.read()
        shape = None if frame is None else frame.shape
        print("index %d: read=%s shape=%s" % (index, ok, shape))
        cap.release()


def probe(index: int, out_dir: str, frames: int) -> None:
    os.makedirs(out_dir, exist_ok=True)
    for fourcc, width, height, fps in FORMATS:
        tag = "%s_%dx%d" % (fourcc or "default", width, height)
        cap = open_with_retry(index, fourcc, width, height, fps)
        if cap is None:
            print("%s: OPEN/READ FAILED" % tag)
            continue
        means = []
        start = time.time()
        for k in range(frames):
            ok, frame = cap.read()
            if not ok or frame is None:
                continue
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            means.append(float(gray.mean()))
            if k in (0, frames // 3, 2 * frames // 3, frames - 1):
                path = os.path.join(out_dir, "%s_%02d.png" % (tag, k))
                cv2.imwrite(path, frame)
                print("  frame %02d mean=%6.2f sd=%6.2f -> %s"
                      % (k, gray.mean(), gray.std(), path))
        elapsed = max(time.time() - start, 1e-6)
        print("%s: %d frames in %.1fs -> %.1f fps, mean of means %.2f"
              % (tag, len(means), elapsed, len(means) / elapsed,
                 sum(means) / max(len(means), 1)))
        cap.release()
        time.sleep(1.0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--device", type=int, default=None)
    parser.add_argument("--formats", action="store_true",
                        help="try each usual format and dump PNGs instead of scanning")
    parser.add_argument("--frames", type=int, default=40)
    parser.add_argument("--out", default=r"work\capture\probe_uvc")
    args = parser.parse_args()

    if args.formats:
        if args.device is None:
            raise SystemExit("--formats needs --device N")
        probe(args.device, args.out, args.frames)
    else:
        scan(8)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
