# Candidate bitstreams

These files are **build candidates**, not validated images. Only
`known_good/edge_detect_720p_verified.bit` is the verified recovery
bitstream. Never overwrite that file.

Status legend:

- `built` - compiled and timing clean, not yet flashed
- `flashed` - downloaded over JTAG and looked at on the monitor
- `accepted` - board holder confirmed the picture, safe to merge upstream

| File | EDGE_THRESHOLD | Source commit | Branch | SHA256 | Status |
|---|---|---|---|---|---|
| `median_thr090.bit` | `11'd90` | `fdf3b5f` | `median-threshold-sweep` | `FABEE8D1C353A262FFAF0674ABB222EFCF9659760FEF17DA89F3C8D5875552BB` | built |

## median_thr090.bit

Same RTL as `median-experiment` (3x3 median filter feeding the Sobel
stage), but with `EDGE_THRESHOLD` lowered from `11'd180` to `11'd90`.

Why: the 180 value was tuned against the unfiltered grayscale path. A 3x3
median filter smooths the image, which lowers Sobel gradient magnitudes, so
on hardware the right half of the split screen lost most of its edges. 90 is
a first guess at a threshold for the filtered path.

What to look for when flashing: does the right half show edges again, and is
the noise level still acceptable. If edges return but the picture is noisy,
the right value is between 90 and 180. If edges are still missing, the
threshold is not the problem.

Reminder: `outflow/` is gitignored, so switching branches does not switch
bitstreams. This pinned copy is the artifact for this candidate.

## Flashing

    ftdi_pgm.bat candidate_bitstreams\median_thr090.bit -m jtag -b "Generic Board Profile Using FT4232H" --jtag_clock_freq 6000000

JTAG download is volatile: power cycling loses it. Do not press CRESET_N.