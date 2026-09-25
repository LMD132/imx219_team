# UART remote control of the edge stage (T / S / D / E / K)

Why: a parameter sweep should not need a person sitting at the board pressing
KEY1/KEY2/KEY3 and reporting what the panel looks like. The board now accepts
commands on its UART and answers with a status line, so the host can drive a
sweep and read back what the board actually latched.

Pin map, baud rate and the transmit side are in `uart_bringup.md`. This file is
the command channel that was added on top.

## Wiring

| Signal | Package pin | Net (schematic) | Note |
|---|---|---|---|
| `o_uart_txd` | R14 / GPIOR_28 | UART_RX_3V3 | already used by the telemetry |
| `i_uart_rxd` | R4 / GPIOL_02 | UART_TX_3V3 | added with this feature, weak pull-up |

Host port **COM5** = FT4232H channel C, 115200 8N1. COM6 (channel D) is not
wired to the FPGA and stays silent, which is a useful negative control.

## Protocol

One ASCII line per command, terminated by LF. CR is ignored, and any other
character inside a line is a separator, so `T=16`, `T 16` and `T16` are the
same thing.

| Line | Field | Range | Clamp |
|---|---|---|---|
| `T<nnn>` | threshold floor | 0..255 | 255 |
| `S<n>` | adaptive weight (shift) | 0..8 | 8 |
| `D<n>` | despeckle neighbours | 0..5 | 5 |
| `E<n>` | denoise stages | 0..2 | 2 |
| `K` | hand control back to the keys | - | - |

The value is a *saturating* accumulate of every digit in the line, so a typo
such as `T300` becomes 255 instead of wrapping. `T1625` also becomes 255 - the
format wants one line per command.

The first `T`/`S`/`D`/`E` line latches `o_override`, and from then on the keys
are ignored, otherwise a KEY3 long press would silently fight the host. `K`
releases it and the key-controlled value takes over again; telemetry says which
side is in charge with `SRC=U` (host) or `SRC=K` (keys).

## Telemetry

One 41 byte status line, continuously:

    THR=016 SH=1 DS=3 EN=2 SRC=K PIX=921600\r\n

`PIX` counts pixels written per frame and is a cheap way to see that the video
path is still healthy: at 720p it must stay 921600. A `T`/`S`/`D`/`E`/`K` line
also pushes an immediate line, so a sweep can be checked without waiting for
the next telemetry tick.

## Host tools

    # listen
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\uart_listen.ps1 -Ports COM5 -Seconds 5
    # send, and print the reply lines
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\uart_send.ps1 -Commands T16,E2 -Port COM5 -Seconds 3

`uart_send.ps1` splits its argument on commas and whitespace itself, because
`powershell -File script.ps1 -Commands T16,E2` does **not** parse the comma:
the whole `T16,E2` arrives as one array element. Before that was fixed the
board received the single line `T16,S2,D5,E0` in one go and, being a
saturating accumulate, latched `THR=255` while `SH`/`DS`/`EN` never changed.
That looked like the newline was wrong; it was not.

## Traps that cost real debugging time

1. **Efinity inferred an implicit wire as one bit.** In `rtl/uart_cmd.v` the
   digit decode was written as `wire digit = i_data - "0";`. The synthesiser
   gave `digit` a width of one bit, so every digit collapsed to its LSB and the
   board latched `T1..T9 -> 1,0,1,0,1,0,1,0,1`, `T16 -> 10`, `T13 -> 11`,
   `T99 -> 11`, `T40 -> 0`. The `is_digit` comparison was fine all along,
   because a comparison is one bit wide anyway, so 0x30..0x39 was still
   recognised and only the *value* was wrong. Fixed by writing the width and a
   hex literal explicitly: `wire [7:0] digit = i_data - 8'h30;`. Keep explicit
   sizes on anything that feeds arithmetic.

2. **`-File` invocation does not split a comma separated argument** (see the
   host tools section above).

3. **`String.Split("||")` is not a string split on Windows PowerShell 5.1.**
   `tools\live_sweep.ps1` plans a run as flat `"<label>||<setting>"` strings and
   pulled the two halves out with `$step.Split("||")`. On PowerShell 7 that
   resolves to `String.Split(string)` and returns two fields; on the 5.1 that
   `powershell -File` actually launches the argument is coerced to `char[]`, so
   the string is cut on *every* `|` and `"ab_e2_t16||E2_T16"` comes back as
   **three** fields `("ab_e2_t16", "", "E2_T16")`. The label was still right, so
   the run looked healthy while `$cmds` was empty: four clips were captured with
   the UART never touched, and the first/last reference pair agreed perfectly
   (0.0 % drift) because nothing had changed. Use a regex split,
   `$step -split '\|\|'`, which behaves the same on both versions. The give-away
   is `.Count`: probe the shape of a parsed value instead of trusting that the
   first field looks right.

4. **Do not round-trip a UTF-8 document through PowerShell's default text
   cmdlets.** `Set-Content` / `Add-Content` / `Out-File` without `-Encoding` use
   the ANSI code page on Windows PowerShell 5.1, so reading a UTF-8 Markdown file
   and writing it back turns every Chinese character into `?`. That is not a
   theory: commit `cc88c13` did exactly this to `docs/capture_and_quantify.md`
   and silently replaced 16083 non-ASCII bytes with 5184 question marks, which
   then sat in the repository looking like a normal commit. No error, no
   warning, and the loss is invisible in a normal diff view. Use
   `[System.IO.File]::WriteAllText($path, $text, (New-Object
   System.Text.UTF8Encoding($false)))` for edits, or `Set-Content -Encoding
   utf8`. The damage is only visible by counting: `git cat-file blob
   <rev>:<file>` and counting bytes above 127, per revision.
   `tools/doc_health.py` does that scan across the whole history and exits
   non-zero when a file's non-ASCII count collapsed to zero.

5. **A backtick inside a double-quoted PowerShell string is an escape, not a
   quote.** Writing the text of this very file with `python -c "..."` from a
   PowerShell command line silently ate every backtick that was meant to be a
   Markdown code span, and turned `` `tools/doc_health.py` `` into a literal tab
   followed by `ools/doc_health.py`. Prefer the `apply_patch` tool for edits, or
   a script file with a single-quoted here-string (`@'...'@`, which does not
   interpolate).

Every one of these was diagnosed by observing behaviour - a reply line, a byte
count, a parsed value's shape - not by reading the source and reasoning about
what it *should* do. When a remote-control channel misbehaves, sweep one digit
at a time first.

## Verified on hardware

Second bitstream after the `digit` fix, JTAG loaded, `COM5`:

| Sent | Reply |
|---|---|
| `T1` .. `T9` | `THR=001` .. `THR=009`, one command per line |
| `T200` | `THR=200` |
| `T300` | `THR=255` (clamp) |
| `S9` | `SH=8` (clamp) |
| `D7` | `DS=5` (clamp) |
| `E0` / `E1` / `E2` | `EN=0` / `EN=1` / `EN=2` |
| `K` | `SRC=K`, and `THR` returns to the key-controlled value |
| (idle) | `THR=016 SH=1 DS=3 EN=2 SRC=K PIX=921600` |

The idle line is the power-on default: the floor default was lowered from 24 to
16 because that is where the two stage denoiser lets the contour close up
without picking up noise, see `docs/edge_overlay.md` and
`docs/capture_and_quantify.md`.
## Self-checking sweeps

A sweep is only worth reading if the scene stayed put while it ran. The camera's
auto exposure drifts slowly, and one lit run lost 13 % of its grey mean between
the first and last clip, which quietly flattered whichever setting happened to be
captured last. `tools\live_sweep.ps1` therefore captures one **reference**
setting both first and last (`refa_*`, `refz_*`), and `tools\analyze_sweep.py`
prints the grey and edge counts of that pair plus a verdict: the run is
trustworthy below 5 % drift, above it "TOO MUCH - ranking not trustworthy".
That pair also caught the `String.Split` bug above, because a 0.0 % drift over a
four-clip sweep is too good to be true.

Validated on 2026-09-25, dark scene, `-Settings E2_T16,E2_T20 -Reference E2_T24`:

| label | grey | dens % | comps | specks | frags | biggest |
|---|---|---|---|---|---|---|
| `refa_e2_t24` | 18.7 | 1.41 | 69 | 4 | 21 | 1590 |
| `ab_e2_t16` | 18.8 | 2.26 | 55 | 9 | 11 | 2449 |
| `ab_e2_t20` | 18.9 | 1.90 | 60 | 2 | 11 | 2126 |
| `refz_e2_t24` | 19.0 | 1.42 | 66 | 2 | 21 | 1596 |

Reference drift `+1.7 %` -> ok. The same setting captured 40 s apart reproduced
to within 0.6 % on edge count while the settings in between differ by ~60 % in
density, so the round trip (UART -> stage -> DDR -> HDMI -> capture -> score) is
stable enough to rank settings.

Frames are grabbed in `YUY2` when the capture stick offers it, so these numbers
are not contaminated by motion-JPEG ringing.
