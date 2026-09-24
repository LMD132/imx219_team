#!/usr/bin/env python3
"""Grab frames from an HDMI capture stick so the picture can be analysed offline.

The board drives a 1280 x 720 HDMI output. An HDMI-to-USB capture stick shows up
as a DirectShow video device, and this script records a few seconds of it,
keeping both a video file and a set of still PNGs. The stills are what
tools/analyze_capture.py works on, so a capture is always reproducible.

Typical use:

    python tools/capture_hdmi.py --list                     # find the device
    python tools/capture_hdmi.py --device 1 --seconds 6 --label dark_target

Captures land in work/capture/<label>/ unless --out is given.

Why not ffmpeg: it is not installed on this machine, while OpenCV is, and
OpenCV can read DirectShow devices directly.
"""

from __future__ import annotations

import argparse
import os
import sys
import time

import cv2
import numpy as np

try:  # probing a device that is not there is expected, so keep the log quiet
    cv2.utils.logging.setLogLevel(cv2.utils.logging.LOG_LEVEL_SILENT)
except Exception:
    pass


def list_devices(max_index: int = 8) -> list[dict]:
    """Probe DShow indices and report what each one offers."""
    found: list[dict] = []
    for index in range(max_index):
        cap = cv2.VideoCapture(index, cv2.CAP_DSHOW)
        if not cap.isOpened():
            cap.release()
            continue
        ok, frame = cap.read()
        info = {
            "index": index,
            "width": int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)),
            "height": int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)),
            "fps": cap.get(cv2.CAP_PROP_FPS),
            "grabbed": bool(ok),
        }
        if ok and frame is not None:
            info["frame_shape"] = tuple(frame.shape)
        cap.release()
        found.append(info)
    return found


def pick_device(preferred: int | None, want: tuple[int, int] = (1280, 720)) -> int:
    """Choose the capture device: the one that reports the board's resolution."""
    devices = list_devices()
    if not devices:
        raise SystemExit("no DirectShow video device found - is the capture stick plugged in?")
    if preferred is not None:
        return preferred
    for dev in devices:
        shape = dev.get("frame_shape")
        if shape and (shape[1], shape[0]) == want:
            return dev["index"]
    if len(devices) == 1:
        return devices[0]["index"]
    raise SystemExit(
        "no device reported %dx%d; pick one with --device (see --list)" % want
    )


def open_capture(index: int, width: int, height: int, fps: int) -> cv2.VideoCapture:
    """Open the device, preferring an uncompressed format for honest edges."""
    for fourcc_text in ("YUY2", "MJPG", None):
        cap = cv2.VideoCapture(index, cv2.CAP_DSHOW)
        if not cap.isOpened():
            cap.release()
            continue
        if fourcc_text:
            cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*fourcc_text))
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
        cap.set(cv2.CAP_PROP_FPS, fps)
        ok, _ = cap.read()
        if ok:
            print(
                "device %d open: %dx%d @ %.1f fps, fourcc %s"
                % (
                    index,
                    int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)),
                    int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)),
                    cap.get(cv2.CAP_PROP_FPS),
                    fourcc_text or "driver default",
                )
            )
            return cap
        cap.release()
    raise SystemExit("could not open device %d in any format" % index)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--list", action="store_true", help="probe devices and exit")
    parser.add_argument("--device", type=int, default=None, help="DirectShow index")
    parser.add_argument("--seconds", type=float, default=6.0)
    parser.add_argument("--label", default="capture", help="name of the output folder")
    parser.add_argument("--out", default=None, help="output folder (overrides --label)")
    parser.add_argument("--stills", type=int, default=12, help="how many PNGs to keep")
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--fps", type=int, default=60)
    parser.add_argument("--note", default="", help="free text stored next to the capture")
    args = parser.parse_args()

    if args.list:
        for dev in list_devices():
            print(dev)
        return 0

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_dir = args.out or os.path.join(repo_root, "work", "capture", args.label)
    os.makedirs(out_dir, exist_ok=True)

    index = pick_device(args.device, (args.width, args.height))
    cap = open_capture(index, args.width, args.height, args.fps)

    video_path = os.path.join(out_dir, "clip.avi")
    writer = cv2.VideoWriter(
        video_path,
        cv2.VideoWriter_fourcc(*"MJPG"),
        float(args.fps),
        (args.width, args.height),
    )

    frames: list[np.ndarray] = []
    read_error = 0
    started = time.time()
    while time.time() - started < args.seconds:
        ok, frame = cap.read()
        if not ok or frame is None:
            read_error += 1
            if read_error > 30:
                break
            time.sleep(0.02)
            continue
        read_error = 0
        if writer.isOpened():
            writer.write(frame)
        frames.append(frame)

    elapsed = time.time() - started
    cap.release()
    if writer.isOpened():
        writer.release()

    if not frames:
        raise SystemExit("no frames arrived - check the HDMI cable and the capture device")

    step = max(1, len(frames) // max(1, args.stills))
    still_paths = []
    for n, frame in enumerate(frames[::step][: args.stills]):
        path = os.path.join(out_dir, "frame_%02d.png" % n)
        cv2.imwrite(path, frame)
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        still_paths.append((os.path.basename(path), float(gray.mean()), float(gray.std())))

    print("wrote %s" % video_path)
    print(
        "frames %d in %.1f s -> %.1f fps effective (device asked for %d)"
        % (len(frames), elapsed, len(frames) / max(elapsed, 1e-6), args.fps)
    )
    for name, mean, std in still_paths:
        print("  %s  mean %6.2f  std %6.2f" % (name, mean, std))

    meta_path = os.path.join(out_dir, "capture.txt")
    with open(meta_path, "w", encoding="utf-8") as handle:
        handle.write("device index : %d\n" % index)
        handle.write("resolution   : %dx%d @ %d\n" % (args.width, args.height, args.fps))
        handle.write("seconds      : %.1f\n" % args.seconds)
        handle.write("frames       : %d (%.1f fps effective)\n" % (len(frames), len(frames) / max(elapsed, 1e-6)))
        handle.write("still frames : %s\n" % ", ".join(name for name, _, _ in still_paths))
        if args.note:
            handle.write("note         : %s\n" % args.note)
    print("wrote %s" % meta_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
