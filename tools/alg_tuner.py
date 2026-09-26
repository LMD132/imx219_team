#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""赛题4 边缘检测流水线 - 运行期调参台 (PC 端).

每一行参数配一个滑块, 拖动即通过 USB 串口把命令下发给 FPGA; FPGA 里这些参数
本来就是寄存器端口(rtl/algo/alg_top.v 的 cfg_*), 所以改完立刻生效, 不需要
重新编译、也不需要重新烧录位流。

板子每 500ms 回一行状态, 收到命令后还会立刻回一行:

    M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1

界面右边"板端"那一列显示的就是这行回读值, 也就是 FPGA 里真正生效的值。
如果它和滑块不一致(比如串口没接好), 会变成红色并在状态栏提示。

命令表 (详见 rtl/alg_cfg_uart.v):
    M<n>  工作模式 0=SOBEL单阈值 1=SOBEL双阈值 2=CANNY
    T<n>  阈值(Sobel 单阈值档)  0..2047  (该档比较全量程梯度, 量程 0..2040)
    L<n>  迟滞低阈值 LO          0..255   (CANNY 档比较 NMS 结果 0..255;
    H<n>  迟滞高阈值 HI          0..255    SOBEL 双阈值档量程 0..2040)
    N<n>  3x3 中值滤波           0/1
    G<n>  5x5 高斯               0/1
    I<n>  去孤点                 0/1
    D<n>  显示模式               0..3
    C<n>  边缘彩色叠加           0/1
    R     全部恢复上电默认值

用法:  python tools/alg_tuner.py
依赖:  pip install pyserial   (标准库自带 tkinter)
"""

import queue
import argparse
import re
import sys
import threading
import time

try:
    import tkinter as tk
    from tkinter import messagebox, ttk
except Exception as exc:                                    # pragma: no cover
    sys.exit("需要 tkinter: %s" % exc)

try:
    import serial
    from serial.tools import list_ports
except Exception:                                           # pragma: no cover
    serial = None
    list_ports = None

BAUD = 115200
SEND_INTERVAL_MS = 60          # 拖动时两次下发之间的最小间隔
READBACK_TIMEOUT = 1.5         # 超过这么久没有回读就认为链路不通

# key, 命令字母, 中文名, 最小, 最大, 默认值, 说明(值->文字)
PARAMS = [
    dict(key="mode", cmd="M", name="工作模式", lo=0, hi=2, init=2,
         names={0: "0 = SOBEL 单阈值", 1: "1 = SOBEL 双阈值", 2: "2 = CANNY 全链路"}),
    dict(key="t", cmd="T", name="阈值 t", lo=0, hi=2047, init=24,
         note="只 SOBEL 单阈值档用, 该档量程 0..2040"),
    dict(key="lo", cmd="L", name="迟滞低阈值 LO", lo=0, hi=255, init=21,
         note="CANNY 档量程 0..255; SOBEL 双阈值档 0..2040"),
    dict(key="hi", cmd="H", name="迟滞高阈值 HI", lo=0, hi=255, init=58,
         note="CANNY 档量程 0..255; SOBEL 双阈值档 0..2040"),
    dict(key="median_en", cmd="N", name="3x3 中值", lo=0, hi=1, init=1,
         note="0=关 1=开"),
    dict(key="gauss_en", cmd="G", name="5x5 高斯", lo=0, hi=1, init=0,
         note="CANNY 档强制开启, 其它档看这个开关"),
    dict(key="isol_en", cmd="I", name="去孤点", lo=0, hi=1, init=1,
         note="0=关 1=开"),
    dict(key="disp_mode", cmd="D", name="显示模式", lo=0, hi=3, init=0,
         names={0: "0 = 左右分屏(灰度|边缘)", 1: "1 = 彩色+红边叠加",
                2: "2 = 左右 1:1", 3: "3 = 纯边缘"}),
    dict(key="ov_color", cmd="C", name="边缘彩色叠加", lo=0, hi=1, init=1,
         note="只对显示模式 1 有效"),
]

TELEM_RE = re.compile(
    r"M(?P<mode>\d+)\s+T(?P<t>\d+)\s+LO(?P<lo>\d+)\s+HI(?P<hi>\d+)"
    r"\s+MED(?P<median_en>\d+)\s+GAU(?P<gauss_en>\d+)\s+ISO(?P<isol_en>\d+)"
    r"\s+DSP(?P<disp_mode>\d+)\s+OVC(?P<ov_color>\d+)")


class Tuner:
    def __init__(self, root):
        self.root = root
        root.title("赛题4 边缘检测 - 运行期调参台")
        root.minsize(880, 620)

        self.ser = None
        self.reader = None
        self.reader_stop = threading.Event()
        self.rx_queue = queue.Queue()
        self.last_readback = 0.0
        self.last_line = ""
        self.port_map = {}

        self.vars = {}
        self.value_labels = {}
        self.board_labels = {}
        self.dirty = {}
        self.send_job = None
        self.last_send = 0.0

        self._build_top()
        self._build_rows()
        self._build_bottom()
        self.refresh_ports()
        self.root.after(50, self._poll)
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    # ------------------------------------------------------------------ 界面
    def _build_top(self):
        bar = ttk.Frame(self.root, padding=(10, 8, 10, 4))
        bar.pack(fill="x")

        ttk.Label(bar, text="串口:").pack(side="left")
        self.port_var = tk.StringVar()
        self.port_box = ttk.Combobox(bar, textvariable=self.port_var, width=22,
                                     state="readonly", values=[])
        self.port_box.pack(side="left", padx=(4, 6))
        ttk.Button(bar, text="刷新", width=6,
                   command=self.refresh_ports).pack(side="left")
        self.conn_btn = ttk.Button(bar, text="连接", width=8, command=self.toggle)
        self.conn_btn.pack(side="left", padx=6)
        ttk.Label(bar, text="115200 8N1").pack(side="left", padx=(6, 0))

        self.status = tk.StringVar(value="未连接")
        self.status_lbl = ttk.Label(bar, textvariable=self.status)
        self.status_lbl.pack(side="right")

        tip = ("拖动滑块立即生效: 参数在 FPGA 内部是寄存器, 不需要重新编译/烧录。"
               "右边「板端」= 板子回读的真实值。")
        ttk.Label(self.root, text=tip, foreground="#0a5", padding=(12, 0, 12, 6),
                  wraplength=860, justify="left").pack(fill="x")

    def _build_rows(self):
        frame = ttk.Frame(self.root, padding=(10, 0, 10, 0))
        frame.pack(fill="both", expand=True)
        for col, (text, width) in enumerate(
                (("参数", 20), ("滑块", 46), ("本机", 8), ("板端", 8), ("说明", 30))):
            ttk.Label(frame, text=text, width=width,
                      font=("", 9, "bold")).grid(row=0, column=col,
                                                 sticky="w", padx=2, pady=(0, 4))

        for i, p in enumerate(PARAMS, start=1):
            ttk.Label(frame, text="%s  (%s)" % (p["name"], p["cmd"])).grid(
                row=i, column=0, sticky="w", padx=2, pady=3)

            var = tk.IntVar(value=p["init"])
            self.vars[p["key"]] = var
            scale = tk.Scale(frame, from_=p["lo"], to=p["hi"], orient="horizontal",
                             resolution=1, showvalue=0, length=330,
                             command=lambda v, k=p["key"]: self._on_drag(k, v))
            scale.set(p["init"])
            scale.grid(row=i, column=1, sticky="we", padx=4)

            vlab = ttk.Label(frame, text=str(p["init"]), width=6, anchor="e")
            vlab.grid(row=i, column=2, sticky="w", padx=2)
            self.value_labels[p["key"]] = vlab

            blab = ttk.Label(frame, text="--", width=6, anchor="e")
            blab.grid(row=i, column=3, sticky="w", padx=2)
            self.board_labels[p["key"]] = blab

            if "names" in p:
                desc = "  ".join(p["names"][v] for v in sorted(p["names"]))
            else:
                desc = p.get("note", "")
            if p["key"] in ("mode", "disp_mode"):
                var.trace_add("write", lambda *a, k=p["key"]: self._desc(k))
            ttk.Label(frame, text=desc, foreground="#555").grid(
                row=i, column=4, sticky="w", padx=2)

        frame.columnconfigure(1, weight=1)

    def _build_bottom(self):
        bar = ttk.Frame(self.root, padding=(10, 6, 10, 6))
        bar.pack(fill="x")
        ttk.Button(bar, text="全部下发", width=10,
                   command=self.send_all).pack(side="left")
        ttk.Button(bar, text="恢复默认 (R)", width=14,
                   command=self.send_reset).pack(side="left", padx=6)
        ttk.Button(bar, text="清空日志", width=10,
                   command=self._clear_log).pack(side="left")
        self.count_lbl = ttk.Label(bar, text="")
        self.count_lbl.pack(side="right")

        box = ttk.Frame(self.root, padding=(10, 0, 10, 10))
        box.pack(fill="both", expand=True)
        self.log = tk.Text(box, height=9, wrap="none", font=("Consolas", 9))
        self.log.pack(side="left", fill="both", expand=True)
        sb = ttk.Scrollbar(box, orient="vertical", command=self.log.yview)
        sb.pack(side="right", fill="y")
        self.log.configure(yscrollcommand=sb.set, state="disabled")

    # ------------------------------------------------------------------ 逻辑
    def _log(self, text):
        self.log.configure(state="normal")
        self.log.insert("end", "%s  %s\n" % (time.strftime("%H:%M:%S"), text))
        if int(self.log.index("end-1c").split(".")[0]) > 500:
            self.log.delete("1.0", "100.0")
        self.log.see("end")
        self.log.configure(state="disabled")

    def _clear_log(self):
        self.log.configure(state="normal")
        self.log.delete("1.0", "end")
        self.log.configure(state="disabled")

    def refresh_ports(self):
        if list_ports is None:
            self.port_box["values"] = []
            self._log("没有安装 pyserial: 请先 pip install pyserial")
            return
        ports = list(list_ports.comports())
        self.port_map = {}
        names = []
        for pt in ports:
            label = "%s  %s" % (pt.device, pt.description or "")
            names.append(label)
            self.port_map[label] = pt.device
        self.port_box["values"] = names
        if names and not self.port_var.get():
            for label in names:
                if "USB Serial" in label or "FT" in label:
                    self.port_var.set(label)
                    break
            else:
                self.port_var.set(names[0])
        self._log("发现串口: %s" % (", ".join(p.device for p in ports) or "无"))

    def select_port(self, port):
        """Point the combobox at `port`, e.g. "COM5", preferring the friendly
        label from list_ports when one exists.  Falls back to the bare name, so
        this works even before pyserial enumerated anything."""
        for label, dev in self.port_map.items():
            if dev.upper() == port.upper():
                self.port_var.set(label)
                return
        self.port_var.set(port)

    def toggle(self):
        if self.ser is not None:
            self.disconnect()
        else:
            self.connect()

    def connect(self):
        if serial is None:
            messagebox.showerror("缺少依赖", "没有安装 pyserial\n请运行: pip install pyserial")
            return
        label = self.port_var.get()
        port = self.port_map.get(label, label)
        if not port:
            messagebox.showwarning("选择串口", "请先选择一个串口")
            return
        try:
            self.ser = serial.Serial(port, BAUD, timeout=0.2)
        except Exception as exc:
            messagebox.showerror("打开失败", "%s\n%s" % (port, exc))
            self._log("打开 %s 失败: %s" % (port, exc))
            self.ser = None
            return
        self.reader_stop.clear()
        self.reader = threading.Thread(target=self._read_loop, daemon=True)
        self.reader.start()
        self.conn_btn.configure(text="断开")
        self.status.set("已连接 %s, 等待板子回读..." % port)
        self._log("已打开 %s" % port)
        self.root.after(250, self.send_all)      # 上电先与滑块对齐一次

    def disconnect(self):
        self.reader_stop.set()
        if self.ser is not None:
            try:
                self.ser.close()
            except Exception:
                pass
        self.ser = None
        self.reader = None
        self.conn_btn.configure(text="连接")
        self.status.set("未连接")

    def _read_loop(self):
        buf = b""
        while not self.reader_stop.is_set():
            try:
                data = self.ser.read(256)
            except Exception as exc:
                self.rx_queue.put(("ERR", str(exc)))
                break
            if not data:
                continue
            buf += data
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                self.rx_queue.put(("LINE", line.strip(b"\r").decode("ascii", "replace")))
        self.rx_queue.put(("CLOSED", ""))

    def _poll(self):
        drained = 0
        try:
            while drained < 60:
                kind, payload = self.rx_queue.get_nowait()
                drained += 1
                if kind == "LINE":
                    self._on_line(payload)
                elif kind == "ERR":
                    self._log("读串口出错: %s" % payload)
                elif kind == "CLOSED":
                    self._log("串口读线程结束")
        except queue.Empty:
            pass

        if self.ser is not None and self.last_readback:
            if time.time() - self.last_readback > READBACK_TIMEOUT:
                self.status.set("已连接但没有回读 (串口选错了? 板子没跑这个位流?)")
        self.root.after(50, self._poll)

    def _on_line(self, line):
        self.last_line = line
        self.last_readback = time.time()
        m = TELEM_RE.search(line)
        if not m:
            self._log("RX  %s" % line)
            return
        vals = {k: int(v) for k, v in m.groupdict().items()}
        bad = []
        for p in PARAMS:
            k = p["key"]
            got = vals[k]
            lab = self.board_labels[k]
            lab.configure(text=str(got))
            mine = self.vars[k].get()
            if got != mine:
                lab.configure(foreground="#c00")
                bad.append("%s: 本机%d/板端%d" % (p["name"], mine, got))
            else:
                lab.configure(foreground="#080")
        if bad:
            self.status.set("回读与滑块不一致 -> " + "; ".join(bad[:3]))
        else:
            self.status.set("已连接, 板端与滑块一致 (%s)" % time.strftime("%H:%M:%S"))
        self.count_lbl.configure(text="最近回读: " + " ".join(
            "%s%d" % (p["cmd"], vals[p["key"]]) for p in PARAMS))

    # -------------------------------------------------------------- 下发命令
    def _on_drag(self, key, value):
        value = int(float(value))
        self.value_labels[key].configure(text=str(value))
        self.dirty[key] = value
        if self.send_job is None:
            wait = max(0, SEND_INTERVAL_MS - int((time.time() - self.last_send) * 1000))
            self.send_job = self.root.after(wait, self._flush)

    def _flush(self):
        self.send_job = None
        if self.ser is None:
            self.dirty.clear()
            return
        cmds = []
        for p in PARAMS:
            if p["key"] in self.dirty:
                cmds.append("%s%d" % (p["cmd"], self.dirty[p["key"]]))
        self.dirty.clear()
        for c in cmds:
            self._send(c)
        self.last_send = time.time()

    def _send(self, cmd):
        if self.ser is None:
            return
        try:
            self.ser.write((cmd + "\n").encode("ascii"))
            self._log("TX  %s" % cmd)
        except Exception as exc:
            self._log("发送失败: %s" % exc)

    def send_all(self):
        if self.ser is None:
            messagebox.showinfo("未连接", "先点「连接」")
            return
        for p in PARAMS:
            self._send("%s%d" % (p["cmd"], self.vars[p["key"]].get()))

    def send_reset(self):
        if self.ser is None:
            messagebox.showinfo("未连接", "先点「连接」")
            return
        self._send("R")
        for p in PARAMS:
            self.vars[p["key"]].set(p["init"])
            self.value_labels[p["key"]].configure(text=str(p["init"]))

    def _desc(self, key):
        pass

    def _on_close(self):
        self.disconnect()
        self.root.destroy()


def main():
    ap = argparse.ArgumentParser(
        description="Runtime tuner for the contest-4 edge pipeline over the "
                    "board UART.  e.g.  python alg_tuner.py --port COM5 --connect")
    ap.add_argument("--port", "-p", default=None,
                    help="serial port, e.g. COM5 (default: auto-pick an FTDI port)")
    ap.add_argument("--connect", action="store_true",
                    help="connect immediately instead of waiting for a click")
    args = ap.parse_args()

    root = tk.Tk()
    try:
        ttk.Style().theme_use("vista")
    except Exception:
        pass
    tuner = Tuner(root)
    if args.port:
        tuner.select_port(args.port)
        if args.connect:
            root.after(150, tuner.connect)
    root.mainloop()


if __name__ == "__main__":
    main()