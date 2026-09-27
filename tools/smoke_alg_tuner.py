"""Offline smoke test of the tuner GUI: feed it status lines, no serial port.

Checks the parsing, the 板端 readback column and the red/green match colouring
without touching hardware.  Run it before blaming the board.

usage:  python smoke_alg_tuner.py
"""
import os
import importlib.util
import tkinter as tk

spec = importlib.util.spec_from_file_location(
    "alg_tuner", os.path.join(os.path.dirname(os.path.abspath(__file__)), "alg_tuner.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

root = tk.Tk()
root.withdraw()
t = m.Tuner(root)

t._on_line("M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1")
print("default line ->", {k: v.cget("text") for k, v in t.board_labels.items()})
print("status        ->", t.status.get())
print("colors        ->", {k: v.cget("foreground") for k, v in t.board_labels.items()})

t._on_line("M2 T0100 LO0005 HI0900 MED1 GAU1 ISO0 DSP2 OVC0")
print("after change  ->", {k: v.cget("text") for k, v in t.board_labels.items()})
print("status        ->", t.status.get())
print("counts        ->", t.count_lbl.cget("text"))

t._on_line("TI60 UART OK")
print("garbage line  -> status:", t.status.get()[:40])

t.vars["t"].set(100)
t._on_line("M2 T0100 LO0005 HI0900 MED1 GAU1 ISO0 DSP2 OVC0")
print("aligned       -> t label color:", t.board_labels["t"].cget("foreground"),
      "| status:", t.status.get())

# 60 字节的新状态行 (末尾带 CAM 字段): 解析、显示、以及"组号对得上才高亮"
t._on_line("M2 T0100 LO0005 HI0900 MED1 GAU1 ISO0 DSP2 OVC0 CAM0077=C0")
print("cam default   ->", t.cam_lbl.cget("text"),
      "color:", t.cam_lbl.cget("foreground"), "(spinbox=77 -> 应该高亮)")
t.cam_grp_var.set("75")
t._on_line("M2 T0100 LO0005 HI0900 MED1 GAU1 ISO0 DSP2 OVC0 CAM0077=C0")
print("cam stale     ->", t.cam_lbl.cget("text"),
      "color:", t.cam_lbl.cget("foreground"), "(spinbox=75 -> 不应该高亮)")
t._on_line("M0 T0100 LO0005 HI0900 MED1 GAU1 ISO0 DSP2 OVC0 CAM0075=04")
print("cam fresh     ->", t.cam_lbl.cget("text"),
      "color:", t.cam_lbl.cget("foreground"), "(应该高亮)")
print("counts w/ cam ->", t.count_lbl.cget("text"))
root.destroy()
print("SMOKE OK")
