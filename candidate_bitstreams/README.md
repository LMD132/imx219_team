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
| `uart_banner.bit` | +UART banner | `11'd24` floor + shift 1 | `eab9c0a` | `uart-bringup` | `1A6682E1CA2D3CFFDE6FF4B23763B66703FE1952BDFC59439020C1C9FEA78313` | flashed |
| `keys_threshold.bit` | +runtime keys +UART telemetry | `11'd24` floor, shift 1, both live | `7e7e6e1` | `uart-bringup` | `92F2E33DC0DFD2DF173F0E9E43876A6A5E6491652188D904754DE96E32534DFC` | flashed |
| `overlay_box.bit` | +despeckle +target box | `11'd24` floor, shift 1, despeckle 3, all live | `7903df0` | `uart-bringup` | `0A0355FC6624CD3107454CC5C5858FE6C1FF41D549EF38A10623B628B921FD88` | flashed |

## keys_threshold.bit

Same edge-detection RTL as `uart_banner.bit`, but the threshold is now driven
from the board keys instead of being a compile-time parameter, and the UART
prints the live values so the picture can be correlated with a number.

New RTL:

- `rtl/key_debounce.v` - two-flop synchroniser + 20 ms counter, emits one pulse
  per debounced press. Keys are active low (external pull-ups).
- `rtl/threshold_ctrl.v` - holds the floor (0..255, step 8) and the adaptive
  weight, cycled by KEY3 through `{off, /8, /4, /2, /1}`.
- `rtl/uart_telemetry.v` - emits `"TI60 UART OK\r\n"` once after reset, then
  `"THR=nnn SH=n\r\n"` every 500 ms and immediately on any key press.

Changed RTL:

- `rtl/edge_display_720p.v` - `EDGE_THRESHOLD` and `EDGE_THRESHOLD_SHIFT` are
  now input ports (`i_threshold`, `i_threshold_shift`) instead of parameters.
- `rtl/ti60f225_oob_top.v` - three debounced key inputs, the control block, a
  2-FF re-sample of the two values into the HDMI pixel clock domain, plus the
  `design_file` entries in `ti60f225_oob.xml` and the pin constraints in
  `ti60f225_oob.peri.xml`.

Keys: KEY1 `GPIOR_22` (P14) floor up, KEY2 `GPIOR_21` (N14) floor down,
KEY3 `GPIOL_03` (A3) adaptive weight. KEY0 is `GPIOL_07` and is already the
reset input. See `docs/key_threshold_control.md`.

Result: compiled clean (0 errors, 0 warnings), all timing slack positive
(worst 0.471 ns), and the pin report lists `A3 / N14 / P14` as inputs with a
weak pullup.

Key control and telemetry are confirmed on hardware. A 90 s listen on `COM5`
captured 2590 bytes (28.8 B/s = 14 B/line x 2 lines/s, so the 500 ms period is
exact) and every key press showed up as a single step:

    THR=024 SH=1   baseline after reset
    THR=032        KEY1 pressed once (+8)
    THR=024        KEY2 (-8)
    THR=016        KEY2 (-8)
    THR=024        KEY1 (+8)
    SH=0           KEY3 (shift 1 -> 0)
    SH=8           KEY3 (shift 0 -> 8, wrapped)
    THR=016/024/032 more KEY2/KEY1 presses

No missed presses and no double steps, so the debouncer behaves. The picture on
the monitor was not described by the board holder, so the threshold values are
verified but the visual effect of each step is not.

## overlay_box.bit

Adds a post-processing stage between the split-screen stage and the DVI encoder:
`rtl/edge_overlay_720p.v`. Two features, both on the binary right half.

1. **Despeckle by neighbour count.** A textbook 3x3 erosion (9-input AND) is
   wrong here: Sobel edges are 1-2 pixels wide and a one-pixel-wide line has
   exactly three set pixels inside its own 3x3 window, so a 9-input AND would
   erase the whole edge map. The rule used instead is "keep the centre pixel
   when the centre is set and at least `i_despeckle_min` of its eight
   neighbours are set".

   | pattern | set pixels in the 3x3 | min=2 | min=3 (default) | min=5 |
   |---|---|---|---|---|
   | isolated speck | 1 | removed | removed | removed |
   | two-pixel speck | 2 | kept | removed | removed |
   | one-pixel-wide line | 3 | kept | kept | removed |

   `i_despeckle_min = 0` bypasses the filter, which is the A/B reference arm.

2. **Target bounding box** (competition task 6). Min/max of the despeckled edge
   pixels over one frame, latched at the frame boundary and drawn in red over
   the next frame, so no extra frame buffer is needed.

   Honest limitation: a plain min/max over all edge pixels expands to the whole
   frame as soon as the background carries any texture. It is only meaningful
   for a mostly uniform scene. If the box always fills the panel, the fix is a
   row/column projection with a relative threshold, not a different min/max.

New RTL: `rtl/edge_overlay_720p.v` (327 SRL8 = two 1280-bit binary line stores,
no BRAM). Changed RTL: `key_debounce.v` gained `o_level`, `threshold_ctrl.v`
gained the despeckle table and the KEY3 short/long split, `uart_telemetry.v`
gained the `DS` field, `ti60f225_oob_top.v` wires the stage in and re-times the
stream by one pixel clock.

Key map is now: KEY1 floor +8, KEY2 floor -8, KEY3 **short press** next adaptive
weight, KEY3 **hold >= 1 s** next despeckle window `{3,5,0,2}`. The short action
fires on release and only when the hold was short, so a long hold cannot also
step the threshold. See `docs/edge_overlay.md`.

Telemetry changed from `"THR=nnn SH=n\r\n"` to `"THR=nnn SH=n DS=k\r\n"`, so the
serial log records which filter setting a picture was taken with.

Result: compiled clean, all timing slack positive (worst **0.408 ns**), and
flashed as `Device ID read from JTAG: 0x10660A79`. A 5 s listen on COM5 read
171 bytes of

    THR=024 SH=1 DS=3

matching the reset defaults (floor 24, shift 1, despeckle 3). The picture itself
has not been described by the board holder yet, so the despeckle and box are
**not visually accepted** - flash `keys_threshold.bit` to go back to the
previous behaviour.

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

Result: confirmed. `COM5` reads `TI60 UART OK\r\n` every 100 ms (~138 bytes/s,
clean `0D 0A`), `COM6` stays silent, and a 6 s baseline before flashing read
0 bytes on both ports. See `docs/uart_bringup.md`.

The first build of this candidate (`d679b53`,
SHA256 `A313E617...E9AAC164`) sent only the even message indices
(`T 6 sp A T O CR`) because the banner pacer re-fired during the two clocks
before `uart_tx.o_busy` went high. `eab9c0a` fixes the pacer; the archived file
above is the fixed build that was verified on the board.

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
