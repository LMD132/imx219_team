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

LEGACY_SHAPE_LINE = (
    "M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1 EPS0 EPF2 "
    "GF0400 BRG2 CAM0000=FF SHP1 SZ024 FL875 BX4 AR050")
OLD_SHAPE_LINE = LEGACY_SHAPE_LINE + " CNT005 OV000A F1"
NEW_SHAPE_LINE = OLD_SHAPE_LINE + " R5"
LOAD_SHAPE_LINE = NEW_SHAPE_LINE + " S00000010 Q00000020"
assert m.parse_shape_diag(LOAD_SHAPE_LINE) == (5, 10, "1", 5)
assert m.parse_shape_load(LOAD_SHAPE_LINE) == (16, 32)
assert m.parse_shape_load(NEW_SHAPE_LINE) is None
assert m.parse_shape_load(LOAD_SHAPE_LINE[:-1]) is None
assert m.parse_shape_load(LOAD_SHAPE_LINE + " extra") is None
assert m.parse_shape_diag(NEW_SHAPE_LINE) == (5, 10, "1", 5)
assert m.parse_shape_diag(OLD_SHAPE_LINE) == (5, 10, "1", None)
assert m.parse_shape_diag(LEGACY_SHAPE_LINE) is None
assert m.parse_shape_diag(NEW_SHAPE_LINE[:-1]) is None
assert m.parse_shape_diag("CNT005 OV000A F1") is None
assert m.parse_shape_diag(NEW_SHAPE_LINE + " garbage") is None

root = tk.Tk()
root.withdraw()
t = m.Tuner(root)
assert set(t.diag_labels) == {"cnt", "ov", "fault", "reason", "slot", "queue"}
assert all(label.cget("text").endswith("--") for label in t.diag_labels.values())

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

# New read-only diagnostics and old-bitstream fallback.
t._on_line(NEW_SHAPE_LINE)
assert "005" in t.diag_labels["cnt"].cget("text")
assert "000A" in t.diag_labels["ov"].cget("text")
assert "整帧故障" in t.diag_labels["fault"].cget("text")
assert "槽位不足" in t.diag_labels["reason"].cget("text")
assert "帧处理追不上" in t.diag_labels["reason"].cget("text")
t._on_line(NEW_SHAPE_LINE.replace("OV000A", "OV000C"))
assert "+2" in t.diag_labels["ov"].cget("text")
t._on_line(NEW_SHAPE_LINE.replace("CNT005 OV000A F1 R5", "CNT000 OV000C F0 R0"))
assert "无合格目标" in t.diag_labels["cnt"].cget("text")
assert "正常" in t.diag_labels["fault"].cget("text")
assert "无故障来源" in t.diag_labels["reason"].cget("text")
t._on_line(NEW_SHAPE_LINE.replace("CNT005 OV000A F1 R5", "CNT000 OVFFFF F? R?"))
assert "饱和" in t.diag_labels["ov"].cget("text")
assert "+" not in t.diag_labels["ov"].cget("text")
assert "等待" in t.diag_labels["fault"].cget("text")
t._on_line(OLD_SHAPE_LINE)
assert "旧位流" in t.diag_labels["reason"].cget("text")
t._on_line(LEGACY_SHAPE_LINE)
assert all(label.cget("text").endswith("--") for label in t.diag_labels.values())

# Read-only cumulative S/Q: deltas require two fresh, monotonic samples in
# one connection. Old/partial/F? lines must hide both counts and rebase.
_real_monotonic = m.time.monotonic
_clock = [100.0]
m.time.monotonic = lambda: _clock[0]
try:
    t._on_line(LOAD_SHAPE_LINE)
    assert "00000010" in t.diag_labels["slot"].cget("text")
    assert "00000020" in t.diag_labels["queue"].cget("text")
    assert "+" not in t.diag_labels["slot"].cget("text")
    _clock[0] = 101.0
    t._on_line(NEW_SHAPE_LINE + " S00000013 Q00000022")
    assert "+3" in t.diag_labels["slot"].cget("text")
    assert "+2" in t.diag_labels["queue"].cget("text")
    _clock[0] = 107.0
    t._on_line(NEW_SHAPE_LINE + " S00000014 Q00000023")
    assert "+" not in t.diag_labels["slot"].cget("text")
    assert "+" not in t.diag_labels["queue"].cget("text")
    _clock[0] = 108.0
    t._on_line(NEW_SHAPE_LINE + " S00000005 Q00000001")
    assert "+" not in t.diag_labels["slot"].cget("text")
    assert "+" not in t.diag_labels["queue"].cget("text")
    _clock[0] = 109.0
    t._on_line(NEW_SHAPE_LINE + " S00000006 Q00000002")
    assert "+1" in t.diag_labels["slot"].cget("text")
    assert "+1" in t.diag_labels["queue"].cget("text")
    t._on_line(NEW_SHAPE_LINE.replace("F1 R5", "F? R?") + " S00000007 Q00000003")
    assert t.diag_labels["slot"].cget("text").endswith("--")
    assert t.diag_labels["queue"].cget("text").endswith("--")
    t._on_line(LOAD_SHAPE_LINE[:-1])
    assert t.diag_labels["slot"].cget("text").endswith("--")
    t._on_line(NEW_SHAPE_LINE)
    assert t.diag_labels["slot"].cget("text").endswith("--")
finally:
    m.time.monotonic = _real_monotonic

# 命令下发: 记录写进假串口, 确认滑块拖出来的就是 "P2" / "F400"
class _FakeSer(object):
    def __init__(self):
        self.written = []
    def write(self, b):
        self.written.append(b.decode("ascii").strip())

t.ser = _FakeSer()
t.vars["epf"].set(1)
t.vars["gf_eps"].set(650)
t.dirty = {"epf": 1, "gf_eps": 650}
t._flush()
print("cmds          ->", t.ser.written)
assert "P1" in t.ser.written and "F650" in t.ser.written, t.ser.written
t.ser = None

# --- 手动输入框: 键入数字 / 每次 ±1 / 与滑块双向同步 / 超量程夹取 / 非法输入还原 ---
from tkinter import ttk as _ttk
assert isinstance(t.value_labels["lo"], m.NumEntry), "value_labels 应为 NumEntry"
assert isinstance(t.value_labels["lo"].box, _ttk.Spinbox), "输入框应是 Spinbox"
assert isinstance(t.scales["lo"], tk.Scale), "拖动滑块必须保留"
assert t.dirty == {}, "构建完成后不应残留待下发命令: %r" % (t.dirty,)

t.ser = _FakeSer()

# 1) 键入数字 -> 回车生效, 滑块跟着跳到同一个值
t.value_labels["hi"].set("230")
t._on_entry("hi")
assert t.vars["hi"].get() == 230, t.vars["hi"].get()
assert t.scales["hi"].get() == 230, t.scales["hi"].get()
print("typed 230     -> var/scale/box =", t.vars["hi"].get(),
      t.scales["hi"].get(), t.value_labels["hi"].get())

# 2) 每次 ±1: 大范围参数(T 0..2047)也只动 1
t.value_labels["t"].set("1000")
t._on_entry("t")
t._step("t", +1)
t._step("t", +1)
t._step("t", -1)
assert t.vars["t"].get() == 1001, t.vars["t"].get()
assert t.scales["t"].get() == 1001
assert t.value_labels["t"].get() == 1001
print("1000 +1+1-1   -> T =", t.vars["t"].get(), "(滑块量程 0..2047 也只动 1)")

# 3) 超量程 -> 夹到上限; 非法输入 -> 还原
t.value_labels["lo"].set("9999")
t._on_entry("lo")
assert t.vars["lo"].get() == 255, t.vars["lo"].get()
t.value_labels["lo"].set("abc")
t._on_entry("lo")
assert t.vars["lo"].get() == 255 and t.value_labels["lo"].get() == 255
print("clamp/invalid -> LO =", t.vars["lo"].get(), "(非法输入已还原)")

# 4) 拖滑块 -> 输入框跟着变
t._on_drag("mode", 1)
assert t.value_labels["mode"].get() == 1, t.value_labels["mode"].get()
print("slider->box   -> M box =", t.value_labels["mode"].get())

# 4b) 「-1」「+1」按钮 = 每次恰好 1
_btns = {w.cget("text"): w for w in t.value_labels["hi"].frame.winfo_children()
         if isinstance(w, _ttk.Button)}
assert set(_btns) == {"-1", "+1"}, sorted(_btns)
t.value_labels["hi"].set("100")
t._on_entry("hi")
_btns["+1"].invoke()
_after_plus = t.vars["hi"].get()
_btns["-1"].invoke()
_btns["-1"].invoke()
_after_minus = t.vars["hi"].get()
assert (_after_plus, _after_minus) == (101, 99), (_after_plus, _after_minus)
print("buttons ±1    -> 100 ->", _after_plus, "->", _after_minus)
t.value_labels["hi"].set("230")          # 复原, 免得影响下面第 5 步
t._on_entry("hi")

# 5) 下发内容: 键入的值原样发出去
t._flush()
print("cmds after edit ->", t.ser.written)
assert "T1001" in t.ser.written and "H230" in t.ser.written, t.ser.written
assert "L255" in t.ser.written and "M1" in t.ser.written, t.ser.written
t.ser = None
t._on_line(LOAD_SHAPE_LINE)
old_epoch = t._connection_epoch
t.disconnect()
assert all(label.cget("text").endswith("--") for label in t.diag_labels.values())
# A queued line from the prior serial session must not repopulate diagnostics.
t.rx_queue.put(("LINE", NEW_SHAPE_LINE, old_epoch))
from types import SimpleNamespace
m.serial = SimpleNamespace(Serial=lambda *args, **kwargs: _FakeSer())
t.port_var.set("COM_TEST")
t.port_map["COM_TEST"] = "COM_TEST"
t._read_loop = lambda *args: None
t.connect()
t._poll()
assert all(label.cget("text").endswith("--") for label in t.diag_labels.values())
t._on_line(LOAD_SHAPE_LINE)
assert "005" in t.diag_labels["cnt"].cget("text")
assert "+" not in t.diag_labels["slot"].cget("text")
failed_epoch = t._connection_epoch
t.rx_queue.put(("ERR", "unplugged", failed_epoch))
t.rx_queue.put(("LINE", NEW_SHAPE_LINE, failed_epoch))
t._poll()
assert t.ser is None and t._connection_epoch > failed_epoch
assert all(label.cget("text").endswith("--") for label in t.diag_labels.values())
t.connect()
t._on_line(NEW_SHAPE_LINE)
closed_epoch = t._connection_epoch
t.rx_queue.put(("CLOSED", "", closed_epoch))
t._poll()
assert t.ser is None and t._connection_epoch > closed_epoch
assert all(label.cget("text").endswith("--") for label in t.diag_labels.values())
t.disconnect()
root.destroy()
print("SMOKE OK")
