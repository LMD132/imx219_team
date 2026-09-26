"""Hardware check of the runtime tuning channel on the board UART.

Reads the idle status line, then sends each command and checks that the reply
line carries the clamped value the RTL is supposed to latch.  Nothing here is a
simulation: this talks to the FPGA over the FT4232H port.

usage:  python link_test.py [COM5]
"""
import sys
import time

import serial

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM5"


def read_lines(ser, seconds):
    end = time.time() + seconds
    buf = b""
    out = []
    while time.time() < end:
        data = ser.read(256)
        if not data:
            continue
        buf += data
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            out.append(line.strip(b"\r").decode("ascii", "replace"))
    return out


TESTS = [
    ("T200", "T0200"),
    ("T=16", "T0016"),
    ("m0", "M0"),
    ("D1", "DSP1"),
    ("T9999", "T2047"),
    ("H3000", "HI2047"),
    ("n0", "MED0"),
    ("T7 L8 H9", "T0007"),
    ("R", "T0024"),
]

with serial.Serial(PORT, 115200, timeout=0.2) as ser:
    print("== %s idle, 2 s ==" % PORT)
    idle = read_lines(ser, 2.0)
    for line in idle:
        print("RX  %s" % line)
    if not idle:
        print("no idle telemetry: wrong port or the board is not running this bitstream")
        sys.exit(3)

    ok = 0
    for cmd, expect in TESTS:
        while ser.in_waiting:
            ser.read(ser.in_waiting)
        ser.write((cmd + "\n").encode("ascii"))
        time.sleep(0.30)
        lines = read_lines(ser, 0.6)
        hit = any(expect in l for l in lines)
        ok += 1 if hit else 0
        print("%-10s want %-7s -> %-58s %s"
              % (cmd, expect, lines[-1] if lines else "(no reply)",
                 "OK" if hit else "MISS"))

    print("RESULT %d/%d" % (ok, len(TESTS)))
    sys.exit(0 if ok == len(TESTS) else 1)
