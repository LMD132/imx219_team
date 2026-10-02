"""Offline observations for this capture, not a detector or correctness test.

ROIs are manually selected for this recording only. They are not production
shape-location assumptions. No device, serial port, or UI is opened.
"""
import csv
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np


ROOT = Path(__file__).resolve().parent
VIDEO = ROOT / "capture.mkv"
ROIS = {
    "ring": (648, 60, 797, 360),
    "triangle": (805, 45, 974, 350),
    "rectangle": (983, 45, 1130, 325),
}


def runs(values):
    result = []
    start = 0
    for end in range(1, len(values) + 1):
        if end == len(values) or values[end] != values[start]:
            result.append({"start": start, "end": end - 1,
                           "visible": bool(values[start]), "frames": end - start})
            start = end
    return result


def main():
    cap = cv2.VideoCapture(str(VIDEO))
    if not cap.isOpened():
        raise RuntimeError("Cannot read recorded clip")
    fps = cap.get(cv2.CAP_PROP_FPS)
    rows, hashes, first, last = [], [], None, None
    previous_edges = {}
    contact = []
    index = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        assert frame.shape == (720, 1280, 3), frame.shape
        if first is None:
            first = frame.copy()
        last = frame
        hashes.append(hashlib.sha256(frame.tobytes()).hexdigest())
        hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
        row = {"frame": index, "timestamp_ms": cap.get(cv2.CAP_PROP_POS_MSEC)}
        for name, (x0, y0, x1, y1) in ROIS.items():
            roi = frame[y0:y1, x0:x1].astype(np.int16)
            hr = hsv[y0:y1, x0:x1]
            hue = hr[:, :, 0]
            hue_ok = {"ring": (hue >= 20) & (hue <= 40),
                      "triangle": (hue >= 135) & (hue <= 170),
                      "rectangle": (hue >= 75) & (hue <= 105)}[name]
            color = hue_ok & (hr[:, :, 1] >= 120) & (hr[:, :, 2] >= 100)
            white = (roi.min(axis=2) >= 160) & (np.ptp(roi, axis=2) < 55)
            # Label/line presence, NOT proof that a complete box is rendered.
            row[name + "_color_pixels"] = int(color.sum())
            row[name + "_annotation_visible"] = int(color.sum() >= 15)
            row[name + "_white_pixels"] = int(white.sum())
            # Exclude every color-overlay pixel and its immediate neighbors.
            any_color = (hr[:, :, 1] >= 80) & (hr[:, :, 2] >= 80)
            color_near = cv2.dilate(any_color.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
            white &= ~color_near
            row[name + "_white_excluding_color"] = int(white.sum())
            if name in previous_edges:
                prev_white, prev_color = previous_edges[name]
                valid = ~(prev_color | color_near)
                a, b = prev_white & valid, white & valid
                row[name + "_unaligned_flip_ratio"] = float(np.logical_xor(a, b).sum() / max(1, (a | b).sum()))
            else:
                row[name + "_unaligned_flip_ratio"] = 0.0
            previous_edges[name] = white, color_near
        rows.append(row)
        if index % 30 == 0:
            tile = cv2.resize(frame, (640, 360))
            cv2.putText(tile, f"frame {index} / {row['timestamp_ms']/1000:.3f}s", (8, 24),
                        cv2.FONT_HERSHEY_SIMPLEX, .62, (0, 0, 255), 2)
            contact.append(tile)
        index += 1
    cap.release()
    if len(rows) != 360:
        raise RuntimeError(f"Expected 360 frames, read {len(rows)}")
    summary = {
        "source": VIDEO.name,
        "source_sha256": hashlib.sha256(VIDEO.read_bytes()).hexdigest(),
        "decoded_frames": len(rows), "nominal_fps": fps,
        "first_timestamp_ms": rows[0]["timestamp_ms"],
        "last_timestamp_ms": rows[-1]["timestamp_ms"],
        "identical_decoded_adjacent_frames": sum(a == b for a, b in zip(hashes, hashes[1:])),
        "unique_decoded_frames": len(set(hashes)),
        "rois_xyxy": ROIS,
        "limitations": [
            "MJPEG USB capture is not the raw FPGA edge bitmap.",
            "Color presence measures an annotation, not full box completeness or accuracy.",
            "Flip ratio is unaligned, so motion and intensity threshold crossings are confounders.",
            "No synchronized F/R/S/Q telemetry was captured; no unique root cause is established.",
            "Capture frames and detector commit frames need not have a one-to-one correspondence.",
        ],
        "shapes": {},
    }
    for name in ROIS:
        states = [r[name + "_annotation_visible"] for r in rows]
        intervals = runs(states)
        whites = [r[name + "_white_pixels"] for r in rows]
        summary["shapes"][name] = {
            "annotated_frames": sum(states),
            "absent_frames": len(states) - sum(states),
            "visible_to_absent_events": sum(a and not b for a, b in zip(states, states[1:])),
            "longest_absence_frames": max([r["frames"] for r in intervals if not r["visible"]] or [0]),
            "white_pixels_min_median_max": [min(whites), float(np.median(whites)), max(whites)],
            "intervals": intervals,
        }
    with (ROOT / "frame_metrics.csv").open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    (ROOT / "metrics.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    cv2.imwrite(str(ROOT / "first_frame.png"), first)
    cv2.imwrite(str(ROOT / "last_frame.png"), last)
    cv2.imwrite(str(ROOT / "contact_sheet.jpg"), np.vstack([np.hstack(contact[j:j+3]) for j in range(0, 12, 3)]))
    print(json.dumps({**summary, "shapes": {k: {p: v for p, v in s.items() if p != "intervals"}
                                           for k, s in summary["shapes"].items()}}, indent=2))


if __name__ == "__main__":
    main()
