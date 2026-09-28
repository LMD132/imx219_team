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

# --- EPS (NMS 容差) 字段: 新的 65 字节行必须解析出来, 旧的 60 字节行显示 "--" ---
t._on_line("M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1 EPS3 CAM0077=C0")
assert t.board_labels["nms_eps"].cget("text") == "3", \
    t.board_labels["nms_eps"].cget("text")
print("eps field     ->", t.board_labels["nms_eps"].cget("text"),
      "| counts:", t.count_lbl.cget("text"))

t._on_line("M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1")
assert t.board_labels["nms_eps"].cget("text") == "--"
print("old 60B line  -> eps shows", t.board_labels["nms_eps"].cget("text"),
      "(旧位流没有该字段, 只提示不报错)")

t._on_line("M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1 EPS0 CAM0077=C0")
assert t.board_labels["nms_eps"].cget("text") == "0"
print("eps back to 0 ->", t.board_labels["nms_eps"].cget("text"))

# --- EPF / GF eps 字段: 77 字节行; 缺字段的旧行显示 "--" ---
t._on_line("M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1 EPS0 EPF2 GF0400 CAM0077=C0")
assert t.board_labels["epf"].cget("text") == "2"
assert t.board_labels["gf_eps"].cget("text") == "400"
print("epf/gf fields ->", t.board_labels["epf"].cget("text"),
      t.board_labels["gf_eps"].cget("text"), "| counts:", t.count_lbl.cget("text"))

t.vars["gf_eps"].set(400)
t.vars["epf"].set(2)
t._on_line("M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1 EPS0 EPF2 GF0400 CAM0077=C0")
print("epf/gf match  -> colors:", t.board_labels["epf"].cget("foreground"),
      t.board_labels["gf_eps"].cget("foreground"), "| status:", t.status.get())

t._on_line("M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1 EPS0 CAM0077=C0")
assert t.board_labels["epf"].cget("text") == "--"
assert t.board_labels["gf_eps"].cget("text") == "--"
print("old 65B line  -> epf/gf show", t.board_labels["epf"].cget("text"),
      "(旧位流没有该字段, 只提示不报错)")

# 命令下发: 记录写进假串口, 确认滑块拖出来的就是 "P2" / "F400"
class _FakeSer(object):
    def __init__(self):
        self.written = []
    def write(self, b):
        self.written.append(b.decode("ascii").strip())

# --- TEMP 字段: 83 字节行; 缺字段的旧行显示 "--" (兼容旧位流) ---
t._on_line("M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1 EPS0 EPF2 GF0400 TMP35 CAM0077=C0")
assert t.board_labels["temp"].cget("text") == "35", t.board_labels["temp"].cget("text")
print("tmp field     ->", t.board_labels["temp"].cget("text"))
print("old 77B line  -> tmp shows", end=" ")
t._on_line("M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1 EPS0 EPF2 GF0400 CAM0077=C0")
assert t.board_labels["temp"].cget("text") == "--", t.board_labels["temp"].cget("text")
print(t.board_labels["temp"].cget("text"), "(旧位流没有该字段, 只提示不报错)")

t.ser = _FakeSer()
t.vars["epf"].set(1)
t.vars["gf_eps"].set(650)
t.vars["temp"].set(45)
t.dirty = {"epf": 1, "gf_eps": 650, "temp": 45}
t._flush()
print("cmds          ->", t.ser.written)
assert "P1" in t.ser.written and "F650" in t.ser.written and "A45" in t.ser.written, t.ser.written
t.ser = None
root.destroy()
print("SMOKE OK")
