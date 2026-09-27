"""Find which COM port is the board UART.

The FT4232H channel number is NOT stable: the same board came up as COM5/COM6 on
the first bring-up and as COM7/COM8 after a later USB re-enumeration, and the
stale pair stays behind in Device Manager as dead "Unknown" entries.  So a
hard-coded port silently stops working and guessing wastes an afternoon.

This probes the candidate ports directly: open each one at 115200 8N1 on a
*read-only* basis, listen for a moment, report which one emits the status line.
Channel D is the useful negative control - it never transmits, so silence there
proves the data is really coming from the board rather than from a stray device.

usage:
    python find_uart.py                 probe FTDI / USB Serial ports (default)
    python find_uart.py --all           probe every port, bluetooth included
    python find_uart.py COM7 COM8       probe exactly these, in this order
    python find_uart.py --seconds 3     listen longer per port
"""

import re
import sys
import time

import serial
from serial.tools import list_ports

BAUD = 115200
WAIT = 1.5                      # seconds of listening per port
# The status line looks like:  M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1
STATUS = re.compile(rb"M\d+\s+T\d+\s+LO\d+\s+HI\d+")
FTDI_HINT = ("USB Serial", "USB-SERIAL", "FTDI")


class _Fallback(object):
    """A port the user named that pyserial has not enumerated yet."""

    def __init__(self, device, description):
        self.device = device
        self.description = description


def pick_ports(argv):
    ports = list(list_ports.comports())
    named = [a.upper() for a in argv if not a.startswith("-")]
    if named:
        out = [p for p in ports if p.device.upper() in named]
        known = set(p.device.upper() for p in out)
        for want in named:
            if want not in known:
                out.append(_Fallback(want, "(not enumerated)"))
        return out
    if "--all" in argv:
        return ports
    return [p for p in ports
            if "VID_0403" in (p.hwid or "").upper()
            or any(h in (p.description or "") for h in FTDI_HINT)]


def seconds(argv):
    if "--seconds" in argv:
        i = argv.index("--seconds")
        if i + 1 < len(argv):
            try:
                return max(0.2, float(argv[i + 1]))
            except ValueError:
                pass
    return WAIT


def main():
    argv = sys.argv[1:]
    wait = seconds(argv)
    ports = pick_ports(argv)
    if not ports:
        print("no candidate serial ports found; plug the board in, or pass --all")
        return 2

    print("probing %d port(s) at %d 8N1, %.2f s each" % (len(ports), BAUD, wait))
    winner = None
    for port in ports:
        dev = port.device
        desc = (getattr(port, "description", "") or "")[:30]
        try:
            with serial.Serial(dev, BAUD, timeout=0.2) as ser:
                time.sleep(wait)
                data = ser.read(8192)
        except Exception as exc:
            print("  %-6s %-30s OPEN FAILED: %s" % (dev, desc, exc))
            continue
        if not data:
            print("  %-6s %-30s silent (0 bytes)" % (dev, desc))
            continue
        if STATUS.search(data):
            winner = dev
            print("  %-6s %-30s <== BOARD UART" % (dev, desc))
        else:
            print("  %-6s %-30s %d bytes, no status line:"
                  % (dev, desc, len(data)))
        print("         %r" % data.split(b"\n")[0][:110])

    print()
    if winner:
        print("use it:")
        print("    python tools\\link_test.py %s" % winner)
        print("    python tools\\alg_tuner.py --port %s --connect" % winner)
        return 0
    print("no port emitted the status line.  most likely, in this order:")
    print("  1. the tuner bitstream is not running - re-flash it:")
    print("       tools\\flash_candidate.bat candidate_bitstreams\\"
          "algo_uart_tuner_splitonly_20260926_2037.bit")
    print("  2. another program is holding the port (a stray pythonw.exe /"
          " a serial terminal)")
    print("  3. the board is not powered, or the USB cable is charge-only")
    return 3


if __name__ == "__main__":
    sys.exit(main())
