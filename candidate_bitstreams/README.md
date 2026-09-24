# Candidate bitstreams

These files are **build candidates**, not validated images. Only
`known_good/edge_detect_720p_verified.bit` is the verified recovery
bitstream. Never overwrite that file.

Status legend:

- `built` - compiled and timing clean, not yet flashed
- `flashed` - downloaded over JTAG and looked at on the monitor
- `accepted` - board holder confirmed the picture, safe to merge upstream

| File | Feature | EDGE_THRESHOLD | Source commit | Branch | SHA256 | Status |
|---|---|---|---|---|---|---|
| `median_thr090.bit` | median filter | `11'd90` | `fdf3b5f` | `median-threshold-sweep` | `FABEE8D1C353A262FFAF0674ABB222EFCF9659760FEF17DA89F3C8D5875552BB` | built |
| `median_adaptive.bit` | median filter | `11'd24` floor + shift 1 | `14daf58` | `median-threshold-sweep` | `78CB73BA88A0BAC8793CB64A2CFCE3C56A7422874A3CCEF4BA183B3442A39AC4` | flashed |
| `uart_banner.bit` | +UART banner | `11'd24` floor + shift 1 | `_pending_` | `uart-bringup` | `A313E617F1D012E1320B1EC171787D7C050F4198DFE25AFB807BC6CCE9AAC164` | built |

## uart_banner.bit

Same edge-detection RTL as `median_adaptive.bit`, plus a minimal UART
banner transmitter so the host PC can see board state as text instead of
relying on someone describing the picture.

New RTL:

- `rtl/uart_tx.v` - 8N1 byte transmitter, `DIV = round(CLK_HZ / BAUD)`.
- `rtl/uart_status_tx.v` - emits `"TI60 UART OK\r\n"` every 100 ms.

Wiring: `o_uart_txd -> GPIOR_28` (pin R14, BR bank, 3.3 V LVCMOS), clocked
from the 25 MHz `CLK_25M` gclk input, so the effective baud is
25000000 / 217 = 115207 (+0.006 %).

Purpose: in one flash, confirm the pin assignment, the baud generator, the
FT4232H channel mapping (channel C, expected on `COM5`) and that the channel
is usable for later numeric telemetry.

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
