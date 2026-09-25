# Board UART bring-up (verified on hardware)

Goal: stop describing the picture by hand. Put a text channel from the FPGA to
the host PC so tuning runs can be judged from numbers (`edge ratio = 4.7 %`)
instead of by photographing the panel.

Status: **verified on hardware**. The fixed banner described below was later
replaced by a numeric status line, so `COM5` now carries
`THR=016 SH=1 DS=3 EN=2 SRC=K PIX=921600` continuously. The banner is still
what proved the link; the current protocol is in `docs/uart_remote_control.md`.

## What was verified

| Item | Result |
|---|---|
| Pin | `o_uart_txd -> GPIOR_28` (package pin **R14**, BR bank, 3.3 V LVCMOS) |
| Baud | 115200 8N1 from the 25 MHz `CLK_25M` gclk, `DIV = 217`, +0.006 % |
| Host port | **COM5** = FT4232H channel **C** = board UART |
| Second port | COM6 (channel D) stays silent, so it is not the board UART |
| Baseline | before the banner was flashed both ports read 0 bytes, so the data is ours |

The COM numbers are **not stable**: the FT4232H pair came up as COM5/COM6 on the
first bring-up and as COM7/COM8 after a later USB re-enumeration, with the old
pair left behind as dead `Unknown` entries in Device Manager. Always list the
ports (`[System.IO.Ports.SerialPort]::GetPortNames()`) and use whichever one
prints the status line; the other half of the pair (channel D) never transmits,
which is what makes it a useful negative control.

The pin matches the vendor UART demo (`rxd` R4 / GPIOL_02, `txd` R14 /
GPIOR_28), and the same signals are brought out on header J8 (pin 4 = rx,
pin 6 = tx) if the FT4232H channel is ever needed for something else.

## How to listen

    powershell -NoProfile -ExecutionPolicy Bypass -File tools\uart_listen.ps1 `
        -Ports COM5 -Seconds 5

Add `-Hex` for a raw byte dump; that is how you spot a wrong baud rate, because
the ASCII column looks plausible while the byte pattern does not decode.

## RTL

- `rtl/uart_tx.v` - 8N1 byte transmitter, `DIV = round(CLK_HZ / BAUD)`,
  `i_valid` / `o_busy` handshake, used by the banner today and by the numeric
  telemetry later.
- `rtl/uart_status_tx.v` - pacer plus the fixed message ROM.

## Gotcha worth remembering

`uart_tx.o_busy` is registered, so there are **two** clocks between offering a
byte and busy going high. The first pacer version only tested `!o_busy`, fired
twice inside that window, and advanced the character index twice per frame, so
the board sent only the even message indices (`54 36 20 41 54 4F 0D`, i.e.
`T 6 sp A T O CR`). The pacer now runs
`S_GAP -> S_LOAD -> S_START -> S_SEND` and advances the index once per frame,
after the frame actually finishes.

## Follow-ups (both have since landed)

- `i_uart_rxd` (**R4 / GPIOL_02**) is now wired up and parsed, which turns this
  one-way channel into `T/S/D/E/K` remote control: see
  `docs/uart_remote_control.md`.
- Numeric telemetry is in place - a 41 byte status line carrying the active
  threshold, shift, despeckle, denoise stages, which side owns control, and the
  per-frame pixel count. Same doc.
