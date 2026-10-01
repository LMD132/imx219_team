#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""赛题4 边缘检测流水线 - 运行期调参台 (PC 端).

每一行参数都同时给两种调法(两个控件都在界面上, 随你挑):
  * 拖滑块     -- 粗调、快, 适合先找一个大概合适的区间;
  * 手动输入框 -- 直接键入数字后回车生效, 或按 ▲/▼ 或「-1」「+1」按钮每次精确
                  改变 1 (参数量程多大都只动 1); 改完滑块也跟着跳到同一个值。
两者双向同步, 每行两个控件都在。大范围参数(比如 T 0..2047、F 0..2047)用滑块
很难停在一个确切的数值上, 手动输入框可以一步到位。

不管用哪种方式, 改动都通过 USB 串口立刻下发给 FPGA; FPGA 里这些参数本来就是
寄存器端口(rtl/algo/alg_top.v 的 cfg_*), 所以改完立刻生效, 不需要重新编译、
也不需要重新烧录位流。

板子每 500ms 回一行状态, 收到命令后还会立刻回一行:

    M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1 EPS0 EPF2 GF0400 BRG2 CAM0077=C0 SHP1 SZ024 FL875 BX4 AR050

界面右边"板端"那一列显示的就是这行回读值, 也就是 FPGA 里真正生效的值。
如果它和滑块不一致(比如串口没接好), 会变成红色并在状态栏提示。
末尾的 CAM 是摄像头寄存器读回的结果(见下面的 X 命令), 上电默认 CAM0000=FF。

命令表 (详见 rtl/alg_cfg_uart.v):
    M<n>  工作模式 0=SOBEL单阈值 1=SOBEL双阈值 2=CANNY
    T<n>  阈值(Sobel 单阈值档)  0..2047  (该档比较全量程梯度, 量程 0..2040)
    L<n>  迟滞低阈值 LO          0..255   (CANNY 档比较 NMS 结果 0..255;
    H<n>  迟滞高阈值 HI          0..255    SOBEL 双阈值档量程 0..2040)
    E<n>  NMS 容差 eps           0..8     (只 CANNY 档有效, 超过 8 夹到 8)
          0 = 与参考 Python 算法逐位一致; 调大能压住轮廓线沿线条上下流动的
          抖动(根因是 NMS 在半像素相位处"近等值二选一"被噪声推来推去),
          代价是线宽从 1 像素变成 1.2~1.3 像素。建议从 1 试到 3。
    P<n>  前置滤波 EPF            0..2     (超过 2 夹到 2)
          0 = 关, 1 = 3x3 高斯, 2 = 导向滤波(guided filter, 参考算法默认档)。
          对应参考 live_tune.py 的 EPF 滑条; 只有 EPF=2 会用到下面的 F。
    F<n>  导向滤波 eps           0..2047  (超过 2047 夹到 2047, 参考值 400)
          导向滤波的正则项: 越大画面越平(弱纹理被抹掉), 越小保留的细节越多、
          去噪越弱。仓库 edge_pipeline.py 的 guided_filter 默认 400。
    N<n>  3x3 中值滤波           0/1
    G<n>  5x5 高斯               0/1
    I<n>  去孤点                 0/1
    B<n>  断线桥接 BRG           0..3     (只双阈值档(CANNY/双阈值)有效)
          二值边缘图上的 4 轴方向闭运算: 沿水平/垂直/两条对角线方向, 把被
          1~5 像素空洞截断的同一条边连起来(边缘图闭运算连线, 治"一条线被
          截成几截"+逐帧一亮一暗的流动感)。0 = 关(与未加此模块时逐位一致),
          1/2/3 = 分别填 1/3/5 像素的空洞。单阈值 SOBEL 档自动旁路。
    D<n>  显示模式               0..3
    C<n>  边缘彩色叠加           0/1
    R     全部恢复上电默认值
    X<n>  读回摄像头寄存器组 n (0..78), 结果显示在状态行末尾的 CAM 字段。
          组号 = piv2_720p_7M_2L_reg.mem 里 3 字节一组的序号, 一组是
          [地址高, 地址低, 值], 所以 X77 就是读 0x0157 (AGAIN) 的当前值,
          X75/X76 是曝光 0x015A/0x015B。越界会夹到 78。
    S<n>  形状识别总开关         0/1      (创意拓展⑥, 默认 1 = 开)
           rtl/algo/alg_top.v 里的 shp_detect: 对边缘图做游程/连通域统计,
           符合"圆形/矩形/三角"的块画彩色框 + 16x16 点阵汉字标签。
           S0 = 全关(输出与没加这个模块时逐位一致)。
    Y<n>  形状 最小边长 px       8..255   (默认 24, 越界夹住)
           bbox 任一边小于它就丢弃, 用来滤掉噪点碎块。
    Z<n>  旧版填充率参数       800..990 (默认 875, 越界夹住)
           为兼容旧命令和状态行 FL 字段而保留；新三类几何分类不使用此值。
    W<n>  形状 同时显示框数上限   1..6     (默认 4)
    A<n>  形状 最大面积(占全屏%)  5..100   (默认 50)
           bbox 面积超过全屏该比例就丢弃(滤掉整片背景大块)。

内部 o_ovf 已是饱和的识别处理异常计数（包括游程/FIFO和坏摘要），
新128字节状态行增加最近帧来源码 R；旧125字节行仍可读但没有来源码。
旧108字节串口状态行没有 OVF 字段；本调参台不虚构一个板端回读值。

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
    dict(key="nms_eps", cmd="E", name="NMS 容差 eps", lo=0, hi=8, init=0,
         note="只 CANNY 有效; 0=参考算法, 1~3 治线条流动抖动"),
    dict(key="epf", cmd="P", name="前置滤波 EPF", lo=0, hi=2, init=2,
         names={0: "0 = 关", 1: "1 = 高斯3x3", 2: "2 = 导向滤波(参考)"}),
    dict(key="gf_eps", cmd="F", name="导向滤波 eps", lo=0, hi=2047, init=400,
         note="只 EPF=2 有效; 400=参考值, 越大越平/越糊"),
    dict(key="median_en", cmd="N", name="3x3 中值", lo=0, hi=1, init=1,
         note="0=关 1=开"),
    dict(key="gauss_en", cmd="G", name="5x5 高斯", lo=0, hi=1, init=0,
         note="CANNY 档强制开启, 其它档看这个开关"),
    dict(key="isol_en", cmd="I", name="去孤点", lo=0, hi=1, init=1,
         note="0=关 1=开"),
    dict(key="brg", cmd="B", name="断线桥接 BRG", lo=0, hi=3, init=2,
         note="只双阈值档有效; 0=关 1/2/3=填1/3/5px空洞(边缘闭运算连线)"),
    dict(key="disp_mode", cmd="D", name="显示模式", lo=0, hi=3, init=0,
         names={0: "0 = 左右分屏(灰度|边缘)", 1: "1 = 彩色+红边叠加",
                2: "2 = 左右 1:1", 3: "3 = 纯边缘"}),
    dict(key="ov_color", cmd="C", name="边缘彩色叠加", lo=0, hi=1, init=1,
         note="只对显示模式 1 有效"),
    dict(key="shp_en", cmd="S", name="形状识别开关", lo=0, hi=1, init=1,
         note="创意拓展⑥; 1 = 检到图形画框 + 汉字标签, 0 = 全关"),
    dict(key="shp_min", cmd="Y", name="形状 最小边长", lo=8, hi=255, init=24,
         note="bbox 任一边小于它就丢弃(px), 调大=滤掉小碎块"),
    dict(key="shp_fill", cmd="Z", name="形状 旧版填充率", lo=800, hi=990, init=875,
         note="新几何分类不使用; 保留 Z 命令与 FL 回读字段供旧版兼容"),
    dict(key="shp_nbox", cmd="W", name="形状 最多框数", lo=1, hi=6, init=4,
         note="同时显示的框数上限"),
    dict(key="shp_area", cmd="A", name="形状 最大面积%", lo=5, hi=100, init=50,
         note="bbox 面积超过全屏该百分比就丢弃(滤大背景块)"),
]

TELEM_RE = re.compile(
    r"M(?P<mode>\d+)\s+T(?P<t>\d+)\s+LO(?P<lo>\d+)\s+HI(?P<hi>\d+)"
    r"\s+MED(?P<median_en>\d+)\s+GAU(?P<gauss_en>\d+)\s+ISO(?P<isol_en>\d+)"
    r"\s+DSP(?P<disp_mode>\d+)\s+OVC(?P<ov_color>\d+)"
    r"(?:\s+EPS(?P<nms_eps>\d+))?"      # 65 字节新行才有; 旧位流(60 字节)缺这一段
    r"(?:\s+EPF(?P<epf>\d+))?"          # EPF 起(77 字节行)才有
    r"(?:\s+GF(?P<gf_eps>\d+))?"
    r"(?:\s+BRG(?P<brg>\d+))?"          # 82 字节新行才有
    r"(?:\s+CAM(?P<cam_grp>\d+)=(?P<cam_val>[0-9A-Fa-f]{2}))?"
    r"(?:\s+SHP(?P<shp_en>\d+))?"       # 108 字节行(形状识别)才有
    r"(?:\s+SZ(?P<shp_min>\d+))?"
    r"(?:\s+FL(?P<shp_fill>\d+))?"
    r"(?:\s+BX(?P<shp_nbox>\d+))?"
    r"(?:\s+AR(?P<shp_area>\d+))?")

SHAPE_DIAG_RE = re.compile(
    r"^M[^\r\n]*\bAR\d{3} CNT(?P<cnt>\d{3}) "
    r"OV(?P<ov>[0-9A-F]{4}) F(?P<fault>[01?])"
    r"(?: R(?P<reason>[0-9A-F?]))?$")


def parse_shape_diag(line: str) -> tuple[int, int, str, int | str | None] | None:
    """Return a complete optional diagnostic suffix; legacy lines lack it."""
    match = SHAPE_DIAG_RE.fullmatch(line)
    if match is None:
        return None
    reason = match["reason"]
    decoded = None if reason is None else ("?" if reason == "?" else int(reason, 16))
    return int(match["cnt"]), int(match["ov"], 16), match["fault"], decoded

# 状态行里 CAM 组的已知含义 (见 rtl/cam/piv2_config.v 的寄存器表)
CAM_HINT = "77=AGAIN 0x0157   75/76=曝光 0x015A/B   71=帧长 0x0160"


class NumEntry:
    """一行参数的「手动输入框」: [-1] 输入框 [+1]。

    和拖动滑块并存, 两者双向同步:
      * 直接键入数字 + 回车   -> 采用键入的值(超量程自动夹回范围里);
      * ▲ / ▼ 或 -1 / +1 按钮 -> 每次只改变 1 (与参数量程多大无关);
      * 鼠标滚轮停在输入框上   -> 每次 ±1。
    对外提供 set()/get()/configure(text=...), 和原来的数值标签接口一致。
    """

    def __init__(self, parent, p, on_edit, on_step):
        self.var = tk.StringVar(value=str(p["init"]))
        self.frame = ttk.Frame(parent)

        ttk.Button(self.frame, text="-1", width=3,
                   command=lambda: on_step(-1)).pack(side="left")

        self.box = ttk.Spinbox(self.frame, from_=p["lo"], to=p["hi"],
                               increment=1, textvariable=self.var,
                               width=7, justify="right")
        self.box.pack(side="left", padx=2)

        def _step_handler(delta):
            def _handler(_ev):
                on_step(delta)
                return "break"
            return _handler

        def _wheel(ev):
            on_step(1 if ev.delta > 0 else -1)
            return "break"

        self.box.bind("<Return>", lambda _e: on_edit())
        self.box.bind("<KP_Enter>", lambda _e: on_edit())
        self.box.bind("<FocusOut>", lambda _e: on_edit())
        self.box.bind("<Up>", _step_handler(+1))
        self.box.bind("<Down>", _step_handler(-1))
        self.box.bind("<MouseWheel>", _wheel)

        ttk.Button(self.frame, text="+1", width=3,
                   command=lambda: on_step(+1)).pack(side="left")

    def grid(self, **kw):
        self.frame.grid(**kw)

    # ---- 兼容原来 tk.Label 的用法(configure/set/get) ----
    def configure(self, text=None, **_kw):
        if text is not None:
            self.var.set(str(text))

    def set(self, value):
        self.var.set(str(value))

    def get(self):
        try:
            return int(float(self.var.get()))
        except Exception:
            return None


class Tuner:
    def __init__(self, root):
        self.root = root
        root.title("赛题4 边缘检测 - 运行期调参台")
        root.minsize(1080, 640)

        self.ser = None
        self.reader = None
        self.reader_stop = threading.Event()
        self.rx_queue = queue.Queue()
        self.last_readback = 0.0
        self.last_line = ""
        self.port_map = {}
        self._connection_epoch = 0
        self._prev_diag_ov = None

        self.vars = {}            # key -> IntVar: 本机当前值(唯一权威副本)
        self.scales = {}          # key -> tk.Scale: 拖动滑块
        self.value_labels = {}    # key -> NumEntry: 手动输入框(兼数值显示)
        self.board_labels = {}
        self.dirty = {}
        self.send_job = None
        self.last_send = 0.0
        self._syncing = False     # 防止 滑块<->输入框 互相回写时递归

        self._build_top()
        self._build_rows()
        self._build_bottom()
        self._reset_diag()
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

        tip = ("两种调法都保留: 拖滑块做粗调; 右边输入框可直接键入数字(回车生效), "
               "或按 ▲/▼ /「-1」「+1」每次精确改 1。改动立即生效(参数在 FPGA 内部是"
               "寄存器, 不需要重新编译/烧录)。「板端」列 = 板子回读的真实值。")
        ttk.Label(self.root, text=tip, foreground="#0a5", padding=(12, 0, 12, 6),
                  wraplength=860, justify="left").pack(fill="x")

    def _build_rows(self):
        frame = ttk.Frame(self.root, padding=(10, 0, 10, 0))
        frame.pack(fill="both", expand=True)
        for col, (text, width) in enumerate(
                (("参数", 18), ("拖动滑块", 40), ("手动输入(每次±1)", 16),
                 ("板端", 8), ("说明", 30))):
            ttk.Label(frame, text=text, width=width,
                      font=("", 9, "bold")).grid(row=0, column=col,
                                                 sticky="w", padx=2, pady=(0, 4))

        # 建界面时控件之间会互相 set(), 先挡住回调, 免得半成品状态被当成用户操作
        self._syncing = True
        try:
            for i, p in enumerate(PARAMS, start=1):
                key = p["key"]
                ttk.Label(frame, text="%s  (%s)" % (p["name"], p["cmd"])).grid(
                    row=i, column=0, sticky="w", padx=2, pady=3)

                var = tk.IntVar(value=p["init"])
                self.vars[key] = var

                # ---- 控件 1: 拖动滑块(粗调) ----
                scale = tk.Scale(frame, from_=p["lo"], to=p["hi"],
                                 orient="horizontal", resolution=1, showvalue=0,
                                 length=300,
                                 command=lambda v, k=key: self._on_drag(k, v))
                scale.set(p["init"])
                scale.grid(row=i, column=1, sticky="we", padx=4)
                scale.bind("<MouseWheel>", lambda ev, k=key: self._on_wheel(ev, k))
                self.scales[key] = scale

                # ---- 控件 2: 手动输入框(可键入, 每次 ±1) ----
                entry = NumEntry(frame, p,
                                 on_edit=lambda k=key: self._on_entry(k),
                                 on_step=lambda d, k=key: self._step(k, d))
                entry.grid(row=i, column=2, sticky="w", padx=3)
                self.value_labels[key] = entry

                blab = ttk.Label(frame, text="--", width=6, anchor="e")
                blab.grid(row=i, column=3, sticky="w", padx=2)
                self.board_labels[key] = blab

                if "names" in p:
                    desc = "  ".join(p["names"][v] for v in sorted(p["names"]))
                else:
                    desc = p.get("note", "")
                if key in ("mode", "disp_mode"):
                    var.trace_add("write", lambda *a, k=key: self._desc(k))
                ttk.Label(frame, text=desc, foreground="#555").grid(
                    row=i, column=4, sticky="w", padx=2)
        finally:
            self._syncing = False

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

        # 摄像头寄存器读回: 直接把 X<组号> 发下去, 结果读状态行末尾的 CAM 字段。
        cam = ttk.Frame(self.root, padding=(10, 0, 10, 6))
        cam.pack(fill="x")
        ttk.Label(cam, text="摄像头寄存器读回 (X):").pack(side="left")
        self.cam_grp_var = tk.StringVar(value="77")
        ttk.Spinbox(cam, from_=0, to=78, width=5,
                    textvariable=self.cam_grp_var).pack(side="left", padx=4)
        ttk.Button(cam, text="读回", width=6,
                   command=self.send_cam_read).pack(side="left")
        self.cam_lbl = ttk.Label(cam, text="CAM----=--",
                                 font=("Consolas", 10, "bold"))
        self.cam_lbl.pack(side="left", padx=(10, 6))
        ttk.Label(cam, text=CAM_HINT, foreground="#555").pack(side="left")

        diag = ttk.Frame(self.root, padding=(10, 0, 10, 6))
        diag.pack(fill="x")
        ttk.Label(diag, text="形状诊断（只读）:").pack(side="left")
        self.diag_labels = {}
        for key in ("cnt", "ov", "fault", "reason"):
            label = ttk.Label(diag, text="--", font=("Consolas", 10, "bold"))
            label.pack(side="left", padx=(10, 10))
            self.diag_labels[key] = label

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
        self._connection_epoch += 1
        self._reset_diag()
        self.reader_stop = threading.Event()
        self.reader = threading.Thread(
            target=self._read_loop,
            args=(self.ser, self.reader_stop, self._connection_epoch), daemon=True)
        self.reader.start()
        self.conn_btn.configure(text="断开")
        self.status.set("已连接 %s, 等待板子回读..." % port)
        self._log("已打开 %s" % port)
        self.root.after(250, self.send_all)      # 上电先与滑块对齐一次

    def disconnect(self):
        self._connection_epoch += 1
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
        self._reset_diag()

    def _read_loop(self, ser_obj, stop_event, epoch):
        buf = b""
        while not stop_event.is_set():
            try:
                data = ser_obj.read(256)
            except Exception as exc:
                self.rx_queue.put(("ERR", str(exc), epoch))
                break
            if not data:
                continue
            buf += data
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                self.rx_queue.put(("LINE", line.strip(b"\r").decode("ascii", "replace"), epoch))
        self.rx_queue.put(("CLOSED", "", epoch))

    def _poll(self):
        drained = 0
        try:
            while drained < 60:
                kind, payload, epoch = self.rx_queue.get_nowait()
                drained += 1
                if epoch != self._connection_epoch or self.ser is None:
                    continue
                if kind == "LINE":
                    self._on_line(payload)
                elif kind == "ERR":
                    self._log("读串口出错: %s" % payload)
                    self.disconnect()
                    self.status.set("串口读取失败: %s" % payload)
                elif kind == "CLOSED":
                    self._log("串口读线程结束")
                    self.disconnect()
                    self.status.set("串口连接已断开")
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
            self._reset_diag()
            self._log("RX  %s" % line)
            return
        vals = {}
        for k, v in m.groupdict().items():
            if v is None:
                continue
            vals[k] = int(v, 16) if k == "cam_val" else int(v)
        bad = []
        for p in PARAMS:
            k = p["key"]
            if k not in vals:
                # 旧位流的状态行没有 EPS 字段: 显示 "--" 而不是报不一致
                self.board_labels[k].configure(text="--", foreground="#888")
                continue
            got = vals[k]
            lab = self.board_labels[k]
            lab.configure(text=str(got))
            mine = self.vars[k].get()
            if got != mine:
                lab.configure(foreground="#c00")
                bad.append("%s: 本机%d/板端%d" % (p["name"], mine, got))
            else:
                lab.configure(foreground="#080")
        if "cam_grp" in vals:
            g, v = vals["cam_grp"], vals["cam_val"]
            self.cam_lbl.configure(text="CAM%04d=%02X" % (g, v))
            try:
                want = int(float(self.cam_grp_var.get()))
            except Exception:
                want = -1
            # 周期行里 CAM 会一直是上次读回的值, 只有组号对得上才高亮
            self.cam_lbl.configure(foreground="#080" if g == want else "#555")
        if bad:
            self.status.set("回读与滑块不一致 -> " + "; ".join(bad[:3]))
        else:
            self.status.set("已连接, 板端与滑块一致 (%s)" % time.strftime("%H:%M:%S"))
        self.count_lbl.configure(text="最近回读: " + " ".join(
            "%s%s" % (p["cmd"], vals.get(p["key"], "-")) for p in PARAMS))
        self._render_diag(parse_shape_diag(line))

    def _reset_diag(self):
        self._prev_diag_ov = None
        for key, label in self.diag_labels.items():
            label.configure(text={"cnt": "CNT --", "ov": "OV --", "fault": "F --",
                                  "reason": "R --"}[key],
                            foreground="#888")

    def _render_diag(self, diag):
        if diag is None:
            self._reset_diag()
            return
        cnt, ov, fault, reason = diag
        cnt_text = "CNT %03d" % cnt
        if fault == "?":
            cnt_text += " (等待完整帧)"
        elif fault == "0" and cnt == 0:
            cnt_text += " (无合格目标)"
        self.diag_labels["cnt"].configure(text=cnt_text, foreground="#555")

        ov_text = "OV %04X" % ov
        if ov == 0xFFFF:
            ov_text += " (已饱和)"
        elif self._prev_diag_ov is not None and ov >= self._prev_diag_ov:
            ov_text += " (+%d)" % (ov - self._prev_diag_ov)
        elif self._prev_diag_ov is not None:
            ov_text += " (计数重置)"
        self.diag_labels["ov"].configure(
            text=ov_text, foreground="#b70" if ov == 0xFFFF else "#555")
        self._prev_diag_ov = None if fault == "?" else ov

        fault_text = {"?": "F? 等待完整帧", "0": "F0 本帧正常", "1": "F1 整帧故障"}[fault]
        self.diag_labels["fault"].configure(
            text=fault_text, foreground="#c00" if fault == "1" else "#555")
        if reason is None:
            reason_text = "R -- (旧位流无来源码)"
        elif reason == "?":
            reason_text = "R? 等待完整帧"
        elif reason == 0:
            reason_text = "R0 无故障来源"
        else:
            causes = ((1, "识别槽位不足"), (2, "输入帧已标坏"),
                      (4, "帧处理追不上"), (8, "帧边界丢失/重同步"))
            reason_text = "R%X " % reason + "+".join(
                name for bit, name in causes if reason & bit)
        self.diag_labels["reason"].configure(
            text=reason_text, foreground="#c00" if isinstance(reason, int) and reason else "#555")

    # -------------------------------------------------------------- 下发命令
    @staticmethod
    def _param(key):
        for p in PARAMS:
            if p["key"] == key:
                return p
        raise KeyError(key)

    def _apply_value(self, key, value, src=None, push=True):
        """滑块 / 输入框 的唯一入口: 夹量程 -> 同步另一个控件 -> 排程下发。

        src 是改动来源("scale"/"num"/"step"), 用来避免把值写回源控件造成抖动;
        push=False 只更新界面、不发命令(给 R 复位用)。
        """
        p = self._param(key)
        try:
            value = int(float(value))
        except (TypeError, ValueError):
            return
        value = max(p["lo"], min(p["hi"], value))

        self._syncing = True
        try:
            if src != "scale" and key in self.scales:
                self.scales[key].set(value)
            if src != "num" and key in self.value_labels:
                self.value_labels[key].set(value)
        finally:
            self._syncing = False

        self.vars[key].set(value)
        if not push:
            self.dirty.pop(key, None)
            return
        self.dirty[key] = value
        if self.send_job is None:
            wait = max(0, SEND_INTERVAL_MS - int((time.time() - self.last_send) * 1000))
            self.send_job = self.root.after(wait, self._flush)

    def _on_drag(self, key, value):
        """滑块回调(名字保留, 兼容 gui_hw_test.py 等旧脚本)。"""
        if self._syncing:
            return
        self._apply_value(key, value, src="scale")

    def _on_wheel(self, ev, key):
        """鼠标滚轮停在滑块上 = 每次 ±1 (量程多大都只动 1)。"""
        self._step(key, 1 if ev.delta > 0 else -1)
        return "break"

    def _step(self, key, delta):
        """输入框的 ▲/▼/「-1」「+1」: 在当前值上精确 ±delta。"""
        if self._syncing:
            return
        self._apply_value(key, self.vars[key].get() + delta, src="step")

    def _on_entry(self, key):
        """回车/失焦: 采用输入框里键入的数字(非法输入则还原)。"""
        if self._syncing:
            return
        v = self.value_labels[key].get()
        if v is None:
            cur = self.vars[key].get()
            self.value_labels[key].set(cur)
            self._log("输入的不是数字, 已还原为 %d" % cur)
            return
        self._apply_value(key, v, src="num")

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
            # 板子已经复位了, 界面跟着回到默认值就行(不再重复下发命令)
            self._apply_value(p["key"], p["init"], src="reset", push=False)

    def send_cam_read(self):
        """X<组号>: 让板子重发那组寄存器的两个地址字节, 再读回一个数据字节。"""
        if self.ser is None:
            messagebox.showinfo("未连接", "先点「连接」")
            return
        try:
            g = int(float(self.cam_grp_var.get()))
        except Exception:
            g = 77
        g = max(0, min(78, g))
        self.cam_grp_var.set(str(g))
        self._send("X%d" % g)

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
