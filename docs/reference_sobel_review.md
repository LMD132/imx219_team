# 第三方 Sobel 参考工程调研（`D:\FPGA边缘化参考\sobel`）

工程名 `Ti60_Demo`，性质：把 Intel/Altera Video & Image Processing(VIP) 套件
移植到 Ti60 上的 720p 边缘检测工程，通路是
CSI-2 -> RGB2Gray -> Sobel -> DDR(AXI) -> LCD/HDMI。
顶层 `example_top.v`，Sobel 本体在 `src/Sobeledge_8d/hdl/`。

## 可以借鉴的（按价值排序）

### 1. 边缘强度输出模式（最有价值）

`src/Sobeledge_8d/hdl/Sobeledge_proc.v:156`：

```verilog
assign source_data = edge_en ? (bin_en ? ((Gmax >= matrix_p22_dly) ? 8'hff : 8'h0)
                                         : ((Gmax > 10'd510) ? 8'hff : Gmax[8:1]))
                              : matrix_p22_dly;
```

顶层 `example_top.v:909-910` 是 `edge_en=1'b1, bin_en=1'b0`，也就是这个参考
工程实际跑的是"输出边缘强度灰度图"，根本不二值化。这解释了它为什么总是
"看起来效果好"：没有阈值，就没有阈值偏高偏低的问题。

对我们的用处：作为二值化之外的第 2 种显示模式，一边看边缘强度、一边看二值
结果，也能直接量出中值滤波削掉了多少梯度。

### 2. 自适应阈值（二值模式里的做法）

`bin_en=1` 时阈值取当前 3x3 窗口的中心像素灰度 `matrix_p22_dly`。源码注释：
"输入数据是中值滤波后的图像，所以根据论文中的算法，二值化只需要让边缘强度
Gmax 和本模块输入的数据中心点 matrix_p22 比较"。即局部自适应阈值，不是全局
固定阈值。

对我们的用处：中值滤波压低全局梯度后固定阈值 180 必然偏高，自适应阈值是
替代方案之一。它不总是更好（中心像素过亮时会把真边缘判掉），必须实测。

### 3. 4 方向 Sobel 取最大值

同文件 Step 1/2：算 0/45/90/135 四组算子各自取绝对差，然后
`Gmax = max(G0,G45,G90,G135)`。赛题指定 G = |Gx| + |Gy|，**基线不能换**；
但 4 方向属于"算法复杂度"维度，可作为可切换的第二种算子模式。

### 4. 中心裁剪

`src/Sensor_Image_XYCrop.v`：用 `image_xpos/image_ypos` 计数，取居中窗口
`IMAGE_HSIZE_TARGET x IMAGE_YSIZE_TARGET`，只重写 href。

对我们的用处：任务③"两边同一视野"可以直接用同一个居中裁剪窗口喂给两条显示
通路，比现在各裁各的更贴题面。

### 5. 帧率统计

`src/cmos_i2c/CMOS_Capture_RAW_Gray.v`：等 10 帧稳定后开始计数，用 2 秒窗口
数 vsync 得到 `cmos_fps_rate`。赛题里"视频帧频也是考核维度"，这个计数逻辑很
便宜，可以拿来做帧率指示。

### 6. 灰度系数

`src/vip_rgb2gray/hdl/vip_rgb2gray_proc.v`：`Y = (R*306 + G*601 + B*117)/1024`，
3 个乘法器 + 截低 10 位。我们的 `Y=(77R+150G+29B)>>8` 是同一组 BT.601 系数
(77/256 ~ 306/1024)，但用移位加法、无乘法器。我们的更省资源，不建议改。

## 这个工程里没有的

- **没有按键调阈值**：`edge_en`/`bin_en` 在顶层是硬编码常量，全工程搜不到
  key/button/debounce。任务②仍要自己写。
- **没有中值滤波模块**：只有 `Sobeledge_proc.v` 注释提到"输入数据是中值滤波
  后的图像"，模块本体不在这个工程里。
- **行缓存方式不同**：它用 Altera 的 `extract_region_c_shiftram_xtap` 抽头 IP
  (`Sobeledge_matrix_3x3.v`)，端口与我们的两行 BRAM 方案不同，无迁移价值。

## 版权

`src/cmos_i2c/CMOS_Capture_RAW_Gray.v`、`src/Sensor_Image_XYCrop.v`、
`src/lcd_driver.v`、`src/lcd_para.v`、`src/lcd_display.v` 文件头都带 CrazyBingo
的 "CONFIDENTIAL IN CONFIDENCE / may be only used as authorized by a licensing
agreement" 声明，`vip_*` 系列是 Intel VIP 套件派生。这些代码不能整段复制进
参赛作品或本仓库，只能作思路参考、自己重新实现。

## 结论

最值得吸收的是第 1 条"边缘强度输出模式"。它可以和任务②合并成一次上板：按键切
模式（灰度 / 边缘强度 / 二值）+ 按键调阈值，这样任务①的验收（中值滤波到底削掉
多少梯度）能在同一屏里直接量出来。