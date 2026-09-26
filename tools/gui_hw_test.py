"""Drive tools/alg_tuner.py against the real board, with the window hidden.

This exercises the code path the sliders use: connect() -> send_all() -> the
reader thread -> _on_line() -> the 板端 column.  A drag is simulated by calling
the same callback the Scale widget calls, so what is tested is the GUI's own
serial code, not a re-implementation of it.

usage:  python gui_hw_test.py [COM5]
"""
import importlib.util
import os
import sys
import time
import tkinter as tk

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM5"
GUI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "alg_tuner.py")

spec = importlib.util.spec_from_file_location("alg_tuner", GUI)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

root = tk.Tk()
root.withdraw()
tuner = mod.Tuner(root)

tuner.port_map[PORT] = PORT
tuner.port_var.set(PORT)
tuner.connect()


def pump(seconds):
    end = time.time() + seconds
    while time.time() < end:
        root.update()
        time.sleep(0.02)


fail = 0

# connect() queues send_all() 250 ms later, so this also proves that path.
pump(1.5)
print("status after connect : %s" % tuner.status.get())
print("板端 column          : %s"
      % {k: v.cget("text") for k, v in tuner.board_labels.items()})
if any(v.cget("text") == "--" for v in tuner.board_labels.values()):
    print("FAIL: some 板端 fields never filled")
    fail += 1

# Simulate dragging the threshold slider (this is the callback tk.Scale calls).
tuner.vars["t"].set(150)
tuner._on_drag("t", 150)
pump(1.5)
got = tuner.board_labels["t"].cget("text")
print("after drag t=150     : 板端 t = %s" % got)
if got != "150":
    print("FAIL: board did not latch 150")
    fail += 1

# ... and the display-mode slider.
tuner.vars["disp_mode"].set(1)
tuner._on_drag("disp_mode", 1)
pump(1.5)
got = tuner.board_labels["disp_mode"].cget("text")
print("after drag DSP=1     : 板端 DSP = %s" % got)
if got != "1":
    print("FAIL: board did not latch display mode 1")
    fail += 1

# back to the tuned defaults
tuner.send_reset()
pump(1.5)
got = tuner.board_labels["t"].cget("text")
print("after 恢复默认       : 板端 t = %s" % got)
if got != "24":
    print("FAIL: reset did not restore the default threshold")
    fail += 1

print("log tail:")
raw = tuner.log.get("1.0", "end").strip().splitlines()
for line in raw[-8:]:
    print("   " + line)

tuner.disconnect()
root.destroy()
print("RESULT %s" % ("PASS" if fail == 0 else "FAIL"))
sys.exit(1 if fail else 0)
