"""Score the clips produced by tools/live_sweep.ps1 and build a comparison sheet.

The board puts raw grey on the left half of every 720p frame and the binary
edge map on the right half, split by a white column at x=640. The red frame
that edge_overlay_720p.v draws is excluded by only counting pixels that are
bright in *all three* channels, which also drops the white separator.

Reported per setting:
  grey      mean of the left half - if two settings disagree here the scene
            moved between clips and the comparison is not fair
  dens%     edge pixels as a share of the right half
  comps     connected components of the edge map (fewer = longer contours)
  specks    components of 2 px or less (isolated noise)
  frags     components of 3..39 px (a contour that keeps breaking)
  biggest   largest single component
  flick%    mean per-pixel disagreement between the stills in one clip
"""
import argparse
import os
import cv2
import numpy as np

SEP_COL = 640


def edge_mask(img):
    b, g, r = img[:, :, 0].astype(int), img[:, :, 1].astype(int), img[:, :, 2].astype(int)
    m = ((r > 140) & (g > 140) & (b > 140)).astype(np.uint8)
    m[:, : SEP_COL + 1] = 0
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default="work/capture")
    ap.add_argument("--labels", required=True, help="comma list of capture labels")
    ap.add_argument("--frames", type=int, default=3, help="stills per clip to use")
    ap.add_argument("--sheet", default="work/analysis/ab_compare.png")
    args = ap.parse_args()

    labels = [x for x in args.labels.split(",") if x]
    rows, panels = [], []
    print(f"{'label':<12} {'grey':>6} {'dens%':>6} {'comps':>6} {'specks':>7} "
          f"{'frags':>6} {'biggest':>8} {'flick%':>7}")
    for lab in labels:
        d = os.path.join(args.root, lab)
        stills = sorted(f for f in os.listdir(d) if f.startswith("frame_") and f.endswith(".png"))
        if not stills:
            print(f"{lab:<12} (no stills)")
            continue
        imgs = [cv2.imread(os.path.join(d, f)) for f in stills[: args.frames]]
        masks = [edge_mask(i) for i in imgs]
        grey = np.mean([cv2.cvtColor(i, cv2.COLOR_BGR2GRAY)[:, :SEP_COL].mean() for i in imgs])
        m = masks[0]
        n = int(m.sum())
        tot = m.shape[1] - SEP_COL - 1
        ncomp, _, stats, _ = cv2.connectedComponentsWithStats(m, 8)
        sizes = stats[1:, 4] if ncomp > 1 else np.array([0])
        specks = int((sizes <= 2).sum())
        frags = int(((sizes > 2) & (sizes < 40)).sum())
        biggest = int(sizes.max()) if len(sizes) else 0
        # flicker: how much a pixel disagrees with the majority across the stills
        stack = np.stack(masks)
        un = stack.max(axis=0)
        denom = max(int(un.sum()), 1)
        flick = float(np.mean([(stack[i] != stack[0]).sum() for i in range(1, len(masks))])) / denom * 100.0
        print(f"{lab:<12} {grey:6.1f} {100.0 * n / (tot * m.shape[0]):6.2f} {ncomp - 1:6d} "
              f"{specks:7d} {frags:6d} {biggest:8d} {flick:7.1f}")
        rows.append((lab, grey, n))
        crop = imgs[0][120:600, SEP_COL + 1:].copy()
        crop = cv2.cvtColor(crop, cv2.COLOR_GRAY2BGR) if crop.ndim == 2 else crop
        cv2.rectangle(crop, (0, 0), (330, 26), (0, 0, 0), -1)
        cv2.putText(crop, f"{lab}  grey={grey:.0f} edge={n}", (8, 19),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1, cv2.LINE_AA)
        panels.append(crop)

    if panels:
        while len(panels) % 2:
            panels.append(np.zeros_like(panels[0]))
        sheet = np.vstack([np.hstack(panels[i:i + 2]) for i in range(0, len(panels), 2)])
        os.makedirs(os.path.dirname(args.sheet), exist_ok=True)
        cv2.imwrite(args.sheet, sheet)
        print(f"\nwrote {args.sheet}")

    if len(rows) > 1:
        greys = [g for _, g, _ in rows]
        if max(greys) - min(greys) > 0.1 * max(greys):
            print(f"WARNING grey differs by more than 10% across clips "
                  f"({min(greys):.1f}..{max(greys):.1f}) - the scene moved, "
                  f"do not trust the ranking")

    # live_sweep.ps1 captures the same reference setting first and last, so the
    # plain difference between those two clips is the scene drift over the whole
    # run. Anything above a few percent means the clips are not comparable.
    refa = next((r for r in rows if r[0].startswith("refa_")), None)
    refz = next((r for r in rows if r[0].startswith("refz_")), None)
    if refa and refz:
        drift = 100.0 * (refz[1] - refa[1]) / max(refa[1], 1e-6)
        verdict = "ok" if abs(drift) <= 5 else "TOO MUCH - ranking not trustworthy"
        print(f"reference drift {refa[0]} -> {refz[0]}: "
              f"grey {refa[1]:.1f} -> {refz[1]:.1f} ({drift:+.1f} %), "
              f"edge {refa[2]} -> {refz[2]}   {verdict}")


if __name__ == "__main__":
    main()
