# 候选位流归档记录

## 2026-10-02 故障分级候选（已编译归档，未烧录）

| 项 | 值 |
| --- | --- |
| 文件 | `shape_fault_grading_534a1d8_20261002.bit`，3,133,584 字节 |
| 源码 | `shape-detect` 提交 `534a1d8`（基于 `058d05c`）；构建前工作区干净，构建后 Efinity 删除的工程 XML 文件尾换行已恢复 |
| 来源 | 2026-10-02 02:03:16 完整构建的 `outflow/ti60f225_oob.bit` 逐字节副本，两份 SHA-256 相同 |
| SHA-256 | `4A08CD0EE5D82948C9FCC2BD9386C575DD8EE91B0780B3EE92187C40EA87F427` |
| 构建与时序 | Efinity 2026.1.132.4.5，map/interface/pnr/pgm 全 PASS，退出 0；19 组时钟关系的 setup/hold 最小 `+0.199/+0.026 ns`，342 条报告路径无负 slack；XLR `55187/60800`、RAM `251/256`、DSP `154/160`。IV 与组合环计时警告仍存在，不宣称全设计无条件签核 |
| 功能 | 故障分级：槽位耗尽与捕获期坏标记不再作废整帧，只保留 VS 待处理边界、边界入队失败、合成恢复边界三类整帧来源；帧照常提交其余合格目标。针对实拍“纸张放上去偶尔整屏无框”的根因修复，允许被丢槽裁短的局部几何 |
| 离线验证 | `check_shape.py --all` 退出 0、`ALL PASS`（23 项 Python、10,381 组几何、18 个形状 RTL 台）；`check_chain`/`check_ebridge` `RESULT: PASS`；`smoke_alg_tuner` `SMOKE OK`。过载台现要求提交真目标并保留 R1/R3 来源码，不是把过载写成正常帧 |
| 实板状态 | **未烧录、未写 Flash、未做画面验收**；不覆盖 `known_good/` 或最佳回退版，也不被认定为“最新版”。实拍“放上去不识别”是否消除必须以板主上板效果为准 |

验证记录见 [R3 负载诊断验证记录](../docs/shape_r3_load_validation.md) 末节；原始构建与回归证据保存在 [evidence/shape_fault_grading_534a1d8_20261002](../docs/evidence/shape_fault_grading_534a1d8_20261002/)。

## 2026-10-02 摘要预取吞吐候选（已 JTAG，待实板效果验收）

| 项 | 值 |
| --- | --- |
| 文件 | `shape_summary_prefetch_12ac41a_20261002.bit`，3,131,484 字节 |
| 源码 | `shape-detect` 提交 `12ac41a9afc2f342410d29650305e9419c190738`；构建后仅补验证文档/归档，Efinity 删除的工程 XML 文件尾换行已恢复，有效 RTL/SDC/工程输入与提交相同 |
| 来源 | 2026-10-02 00:50:54 完整构建的 `outflow/ti60f225_oob.bit` 逐字节副本 |
| SHA-256 | `6F49DD8542A26D7AC068294716254892DDA939A72F601FE19F82D41A2336BBE7`，与输出原件一致 |
| 构建与时序 | Efinity 2026.1.132.4.5，map/interface/pnr/pgm 全 PASS，退出 0；19 组时钟关系的 setup/hold 最小 `+0.142/+0.026 ns`，342 条报告路径无负 slack。XLR `55188/60800`、RAM `251/256`、DSP `154/160`；IV、未匹配 SDC 与组合环计时警告仍存在，不宣称全设计无条件签核 |
| 改动 | 仅正常游程摘要更新使用原读端口预取下一条记录；单条摘要占用从 66 拍降至 34 拍，数据/接口不变。未改识别规则、槽位/FIFO 容量或默认参数 |
| 离线验证 | 23 项 Python、10,381 组几何对拍、18 个形状 RTL 台 `ALL PASS`；摘要 11 阶段、498 游程逐字匹配，最大 34 拍。完整 720p 六方形类别/框正确，S/Q 为 0、F0/R0，队列峰值旧 10 → 新 6；计数台、主链/桥接对拍通过。原刻意过载台仍要求 F1/R3，不代表实拍 R3 已消除 |
| 实板状态 | **2026-10-02 经板主明确要求“烧录”，已用板载 FT4232H、6 MHz JTAG 临时下载此归档位流**：哈希匹配，命令退出 0，器件 ID `0x10660A79`，日志显示 `finished with JTAG programming`。**未写 Flash、未操作调参界面、未验收实际 F1/R3 或漏检改善**；不覆盖 `known_good/` 或最佳回退版。下载日志见验证记录 |

验证记录见 [R3 负载诊断验证记录](../docs/shape_r3_load_validation.md) 最后部分；原始构建日志、资源与最终时序报告保存在 [evidence/summary_prefetch_12ac41a_20261002](../docs/evidence/summary_prefetch_12ac41a_20261002/)。

## 2026-10-01 R3 负载计数候选（已 JTAG 临时下载，待实板验收）

| 项 | 值 |
| --- | --- |
| 文件 | `shape_r3_load_72380a3_20261001.bit`，3,116,013 字节 |
| 源码 | `shape-detect` 干净源码提交 `72380a3e177d7ef3cceaf6ae5cadb08c752e3c8d`；构建期间 Efinity 仅删除工程 XML 文件尾换行，归档前已恢复原样，有效工程输入与 RTL 未变 |
| 来源 | 2026-10-01 23:37:50 完整构建的 `outflow/ti60f225_oob.bit` 逐字节副本，两份 SHA-256 相同 |
| SHA-256 | `C671A57EB3E87502DA1C428ED50C416CB3B9C66902854E18B98AA0D0689C3211` |
| 构建与时序 | Efinity 2026.1.132.4.5 的 map/interface/pnr/pgm 全 PASS，命令退出 0；最终报告 19 组时钟关系 setup/hold 均非负，最小 `+0.091/+0.028 ns`，342 条报告路径无负 slack；XLR `54798/60800`、RAM `251/256`、DSP `154/160`。保留 IV 和组合环计时警告，不据此宣称全设计无条件签核 |
| 离线验证 | 23 项 Python 测试、10,381 组几何对拍、17 个形状 RTL 台 `ALL PASS`；CDC 20 元组、遥测 21 项、配置串口 68 项、主视频链与桥接对拍、GUI 冒烟均通过。新 32 位计数及 96 位 CDC 快照在综合网表中存在 |
| 功能 | 独立累计槽位丢弃 `S` 与 FIFO 满游程丢弃 `Q`，148 字节状态行与界面只读增量；保留旧 `CNT/OV/F/R` 语义。精确 R3 压力仿真通过，**尚未证明实拍 R3 根因或修复漏检** |
| 状态 | **2026-10-02 经板主明确同意，运行 `tools/flash_candidate.bat` 以 6.0 MHz JTAG 临时下载此归档位流**：命令退出码 0，读取器件 ID `0x10660A79`，日志显示 `jtag programming started!`、`Programming 'candidate_bitstreams\shape_r3_load_72380a3_20261001.bit' via JTAG at freq 6.0 MHz` 及 `finished with JTAG programming`。随后 COM5 调参界面已连接，读到 `S0000217C Q0001AAB7`，约 25 秒后两者增量仍为 `+0`，`F0/R0`；当前摄像头场景未知。**未写 Flash、未做屏幕肉眼／形状识别效果验收**；这些读数不证明实拍 R3 根因或漏检已修复。实板下一步须在同一阈值/场景下采集连续 `S/Q/F/R`。本候选不覆盖 `known_good/` 或最佳回退版，详见 `docs/shape_r3_load_validation.md` |

## 2026-10-01 故障来源细分候选（已 JTAG，待实板诊断）

| 项 | 值 |
| --- | --- |
| 文件 | `shape_fault_reason_2508960_20261001.bit`，3,115,293 字节 |
| 源码 | `shape-detect` 提交 `2508960071741f87f682c8119c4e245fbcc3bb10`。完整构建在提交前启动；提交前后 RTL、SDC 和工程输入未变，后来仅修正独立测试台、文档和由 Efinity 改动的 XML 文件尾换行（恢复原样） |
| 来源 | 20:40:54 完整编译产生的 `outflow/ti60f225_oob.bit` 逐字节副本；SHA-256 与输出原件一致 |
| SHA-256 | `72D6A4F04CD760A04200DFFCCCBF1B36377D2F0C91198ED5B3A6F6CCE3DC6885` |
| 编译/时序 | Efinity 2026.1.132.4.5 的 map/interface/pnr/pgm 均 PASS，命令退出 0；报告列出的 setup/hold 最小余量 `+0.294/+0.026 ns`，XLR `54797/60800`、RAM `251/256`、DSP `154/160`。有 IV 与组合环计时警告，不能据此宣称全设计无条件签核 |
| 离线验证 | `check_shape.py --all` 为 `ALL PASS`（23 项 Python、10381 几何样本、16 个形状 RTL 台）；另 `tb_shp_diag`、`tb_shape_diag_cdc`、`tb_alg_tel_shp` 20 项和 `tb_alg_cfg_uart` 68 项通过，主流水、桥接逐位对拍通过，调参界面冒烟通过 |
| 功能与状态 | 只增加最近提交帧的 `R` 故障来源码及 GUI 解析；**未修复或证明修复实拍漏检**。纯白纸 `F0`、图案纸 `F1` 是旧位流实测。2026-10-01 经板主本轮明确同意，运行 `tools/flash_candidate.bat` 以板载 FT4232H、6 MHz **JTAG 临时下载**此归档位流：退出码 0、读取器件 ID `0x10660A79`、日志显示 `... finished with JTAG programming`。**未写 Flash、未进行摄像头/屏幕或真实串口验收**；断电或复位后可能恢复旧程序。细节见 `docs/shape_overload_diagnosis_20261001.md`；不覆盖 `known_good/` 或最佳回退版 |

## 2026-10-01 形状诊断候选（已JTAG，待画面与串口验收）

| 项 | 值 |
| --- | --- |
| 文件 | `shape_diag_3604b66_20261001.bit`，3,118,644 字节 |
| 来源 | `shape-detect` 源码提交 `3604b66`；18:49:47 完整编译产物 `outflow/ti60f225_oob.bit` 的逐字节副本。编译后仅补充 SDC 注释与测试/GUI 修复，有效 RTL/SDC 命令未变 |
| SHA-256 | `25F66926F864AC3054ADFBFD5B5622289B9254B7C3F2315ECD2E318B7E468B6C`；与编译输出一致 |
| 编译 | Efinity 2026.1.132.4.5，map/interface/pnr/pgm 四阶段退出 0 |
| 资源与时序 | XLR 54820/60800、RAM 251/256、DSP 154/160；最终报告中相关时钟 setup/hold 全部非负，最小 +0.228/+0.027 ns。保留原有未匹配端口警告，不等于全设计无条件签核 |
| 功能与测试 | 在现有三类抗旋转候选上新增最近帧合格数 `CNT`、饱和异常数 `OV`、帧状态 `F` 的串口/调参界面诊断；23 项 Python、10381 例几何、15 个形状 RTL 台和 4 个诊断/协议台通过；主链、桥接、GUI 冒烟通过。详情见 `docs/shape_diagnostics_validation.md` |
| 状态 | **2026-10-01 经板主指示，已通过板载 FT4232H 以 JTAG 临时下载**：命令退出码 0，器件 ID `0x10660A79`，日志显示 `finished with JTAG programming`。**未写 Flash、未做屏幕或真实串口验收**；断电或复位后可能恢复旧程序。不覆盖 `known_good/` 或下述最佳回退 |

## 2026-10-01 审查修复版三类抗旋转候选（已JTAG，待画面验收）

| 项 | 值 |
| --- | --- |
| 文件 | `shape_rotation_34e5d39_20261001.bit`，3123549字节 |
| 源码 | `D:\FPGA_Project\imx219_shape` / `shape-detect`，干净提交 `34e5d39b75654e2a8bb8d1149b2c9cd284750974` |
| 来源 | 2026-10-01 15:16:33完整重编译生成的 `outflow/ti60f225_oob.bit` 逐字节副本；不是下方失效旧候选改名 |
| SHA-256 | `EC1799C6DAE0B4D554A7E9184905328A833152B44F928220AEFBCB0D4AA8B32F`，与编译输出一致 |
| 编译 | Efinity 2026.1.132.4.5，map/interface/pnr/pgm四阶段PASS，命令退出0；有非致命IV警告及部分时钟名未匹配的SDC警告 |
| 资源与时序 | XLR 54488/60800、RAM 251/256、DSP 154/160；报告列出的15组时钟关系setup/hold均非负，最小+0.385/+0.026 ns。SDC警告意味着**不声称全部路径已获约束签核** |
| 验证 | 23项Python测试、10381例几何黄金对拍、15个形状RTL台全部PASS；`check_chain.py`/`check_ebridge.py`逐位对拍PASS；遥测17项、串口68项PASS。包含平行四边形拒识、同高四圆环、关闭再开启、连续/丢失帧边界及无消隐压力测试 |
| 范围 | 圆形/圆环、三角形、矩形；十字拒识，无OCR；保留中文类别标注。仿真不保证任意透视、断边、噪声、遮挡或实拍效果 |
| 上板状态 | **2026-10-01 通过板载FT4232H以JTAG临时下载**：脚本退出0、器件ID `0x10660A79`、日志显示 `finished with JTAG programming`。**未写Flash、未获屏幕肉眼验收**；断电后可能恢复Flash旧程序。`known_good/` 和最佳回退版未动，板主仍需按 `docs/shape_rotation_validation.md` 检查画面 |

> **审查警告（2026-10-01）：** 下列 `shape_rotation_e74ced2_20261001.bit`
> 已被代码审查判定为不可验收的历史候选：矩形直角检查存在索引错误，
> 相邻帧边界可能合并，关闭再开启识别可能发布旧标签。同高度多圆环
> 也会触发吞吐溢出。请勿将它烧录作本轮验收；修复版须重新编译并
> 单独归档。保留旧文件仅供追溯，不覆盖最佳回退版。

## 2026-10-01 三类抗旋转候选（未上板验收）

| 项 | 值 |
| --- | --- |
| 文件 | `shape_rotation_e74ced2_20261001.bit`，3114330字节 |
| 构建输入 | `D:\FPGA_Project\imx219_shape` 的 `shape-detect` 分支，源码/测试/文档提交 `e74ced23e9cc758366dd5edbc09d947636c983c1`；构建启动时工作区干净 |
| 来源 | 2026-10-01 14:01:16本目录最终 `outflow/ti60f225_oob.bit` 逐字节副本；新执行 `tools/compile.bat`，不是旧位流改名 |
| SHA-256 | `CC906672CC24907D5F87E121DF214B527AE53F54A0F5570E5FAF4D7CA00461DB`，复制后与outflow原件相同 |
| 编译 | Efinity 2026.1.132.4.5，map/interface/pnr/pgm四阶段PASS，命令退出0；日志有非致命 `cannot find correct IV value` 警告 |
| 资源与时序 | XLR 54819/60800，RAM 251/256，DSP 154/160；15组时钟关系setup/hold均非负，最小分别+0.222/+0.026 ns；余量较紧 |
| 验证 | Python形状测试23项PASS；`check_shape.py --all`模型门禁及12个RTL台PASS，包括10369例几何黄金对拍、间距2/4/8/16/32和吞吐拒识；既有`check_chain.py`/`check_ebridge.py`逐位对拍PASS，`tb_alg_tel_shp`17项、`tb_alg_cfg_uart`68项PASS |
| 范围与限制 | 圆形/圆环、三角形、矩形，十字拒识，无OCR；干净平面旋转标准集通过。不能由仿真推断任意透视、断边、噪声、遮挡或实拍均正确，实测详见 `docs/shape_rotation_validation.md` |
| 上板状态 | **尚未JTAG、未写Flash、未获肉眼验收**；不得视为最佳回退版或覆盖`known_good/`。上板测试需板主另行安排，并记录类别、框、空帧清框与异常行为 |

## 2026-10-01 旧形状识别候选（未通过旋转/倾斜识别验收，历史记录）

| 项 | 值 |
| --- | --- |
| 文件 | `shape_detect_2cb0932_20261001.bit` |
| 算法源码提交 | `2cb0932a3f93ca6bb57fc385b6ed023ea5486137`，分支 `shape-detect`，目录 `D:\FPGA_Project\imx219_shape` |
| 来源 | 本目录现存 `outflow/ti60f225_oob.bit` 的逐字节副本；本次归档没有重新编译 |
| 现存构建时间 | 2026-10-01 01:00:32（文件时间及现存 `compile.log`） |
| 字节数 | 2794899 |
| SHA-256 | `C9DB772BA8853C1F17FFDEE06C116759F854D7ACAEB8CF0A39BD9B2B76CEFEBD` |
| 编译证据 | 检查现存日志：map / interface / pnr / pgm 均 PASS；日志另有 `cannot find correct IV value` 警告。本轮未重编译，不将旧日志当作新验证 |
| 资源证据 | 现存 `ti60f225_oob.place.rpt`：Memory Blocks 243/256，DSP Blocks 46/160 |
| 上板/效果 | 关联聊天此前记录过此源码版的 JTAG 下载；本轮没有烧录，也不保证当前板内仍运行此版。用户2026-10-01反馈纸张未端正摆放会误识别，**效果验收未通过** |
| 本日诊断 | 复跑 `tb_shp_rot.v`：40°和45°方形被判十字，FIFO溢出0；测试 `errors=0` 不等于形状分类正确 |
| 版本地位 | 仅候选；最佳回退仍是 `imx219_notemp` 中 `known_good/best_epf_guided_99540aa_20260928.bit`。不得因编译或下载成功自动替换 |

以下是早期归档的历史记录；其中“当前版”“板上运行”等措辞仅对应各自记录日期。

规则（见 `AGENTS.md`）：

- 候选位流只放本目录，并记录**来源提交、SHA-256、上板状态**。
- 只有**肉眼验证通过**的恢复位流才能进 `known_good/`；不要用实验位流覆盖已验证基线。
- `outflow/` 被 Git 忽略，**切分支不会切换位流**；下载前必须重新编译，或明确选择本目录里已记录的位流。

烧录命令（本机已封装，含 `PYTHONHOME` / `EFINITY_USER_DIR` 两个环境坑的处理）：

```bat
cd /d D:\FPGA_Project\imx219_pyrtl
tools\flash_candidate.bat candidate_bitstreams\<位流文件>
```

---

## -1. `brg_canny_smooth_78779c7_20260928.bit` —— 断线桥接版 = **冻结"最新版"的位流**（2026-09-28 晚）

| 项 | 值 |
| --- | --- |
| 来源提交 | `78779c7`（分支 `canny-smooth`，基于 `a390a99`） |
| 编译时间 | 2026-09-28 18:29:55（在 `imx219_smooth` 内编译，`outflow/compile.log`：map/interface/pnr/pgm 全 PASS） |
| 字节数 | 2548746 |
| SHA-256 | `09A44591609D17C25A70A32DCAD7BC04136531DA5FF9719E4611A6719ABB642F` |
| **上板状态** | ⚠️ **已烧录，肉眼效果待板主确认**。2026-09-28 19:14 用 `tools\flash_candidate.bat` 烧进板子（JTAG ID `0x10660A79`，日志 `finished with JTAG programming`），串口回读状态行为 `M2 T0024 LO0021 HI0058 MED1 GAU0 ISO1 DSP0 OVC1 EPS0 EPF2 GF0400 **BRG2** CAM0000=FF`，确认板上跑的就是这一版。**但 BRG 在屏幕上的实际观感还没得到板主回答**，所以只算"最新"，不算"最佳"。 |
| 冻结 | 2026-09-28 晚板主指令：这一版固定为**最新版本**，后续改动一律先备份 + 复制新目录再改；位流**暂不进 `known_good/`**（本目录规矩：只有肉眼验证通过的才进）。一键重烧：`D:\FPGA_Project\烧录最新版.bat` |
| 内容 | 与回退版同链，新增 **断线桥接 `alg_ebridge`**（命令 `B0..B3`，默认 B2）与精确深度行缓存 `alg_ring_ram`；`ROWD` 11→14、`L` 51→55；遥测行 77→82 字节 |
| 时序 | `hdmi_tx_slow_clk` setup **+4.774 ns**；`core_clk`（100 MHz）setup **+4.582 ns**；全设计最小 setup **+0.454 ns**、0 条负 slack |
| 资源 | XLRs 28809/60800 (47.4%)、**Memory Blocks 242/256 (94.5%)**、LUT 16157 / FF 12201、DSP 36/160 |
| 对拍 | `check_ebridge.py` K=0/1/2/3 全 0 mismatch；`check_chain.py` 含 BRG=0/1/3 三档 + 显示逐像素 `RESULT: PASS` |
| 回退 | 效果不满意就直接烧 `rollback_epf_guided_99540aa_20260928.bit`（`tools\flash_best.bat` / `烧录最佳版.bat`），本目录的 `imx219_smooth` 可继续改 |


## 0. `rollback_epf_guided_99540aa_20260928.bit` —— 回退版（2026-09-28 晚起为板上运行版本）

> 取代下面第 1 节：TEMP 时域降噪版上板实测不合格后，按板主指示回退到加 TEMP 之前的版本。

| 项 | 值 |
| --- | --- |
| 来源提交 | `99540aa1413c9eadb28f3b74e2f6e1f9fb78cd61`（分支 `epf-guided`，即 `temp-blend` 的父提交） |
| 编译时间 | 2026-09-28 02:15:29（在 `imx219_gf` 内编译，`outflow/compile_gf.log`：map/interface/pnr/pgm 全 PASS） |
| 字节数 | 2540034 |
| SHA-256 | `DB3DD3727AC6BDCEED2E4B12461AC84EF4357502D0A9189B939A7ADD63502BCD` |
| 显示模式 | 固定 mode 0 = 同视野左右分屏（运行期 `D0..D3` 可切换） |
| **上板状态** | ✅ 2026-09-28 晚 JTAG 重新烧录成功（回退 TEMP 后），JTAG ID `0x10660A79` |
| 内容 | 灰度 → 3×3 中值 → 5×5 高斯 → Sobel → NMS → 双阈值 → 去孤点 → 显示；含导向滤波(EPF)参数 P，**不含 TEMP 时域降噪** |
| 背景 | TEMP 版（`temp-blend`，`405701f`/`b4e4dcf`）被判不合格：无效果且更差（拖影）。原因见 imx219_temp 根目录 不合格_已废弃_TEMP时域降噪_20260928.md |


## 1. `algo_uart_tuner_splitonly_20260926_2037.bit` —— **当前版**（算法全链 + 固定左右分屏 + 运行期串口调参）

| 项 | 值 |
| --- | --- |
| 来源提交 | `0cf4f6962760856742bc0eac7cf17a4ea8b2fd26`（分支 `py-algo-rtl`） |
| 编译时间 | 2026-09-26 20:36:52 |
| 字节数 | 2434185 |
| SHA-256 | `4F9D7D387627031A0D8F1AC6F4B0AE5AB1CC94D716D6238D8ADBCB51ECC3EB05` |
| 工具 | Efinity 2026.1.132.4.5 |
| 流程结果 | `map` PASS、`interface` PASS、`pnr` PASS、`pgm` PASS |
| 时序 | `hdmi_tx_slow_clk` setup **+5.360 ns** / hold **+0.026 ns**；全设计无负 slack；最大可分析频率 **123.335 MHz**（约束 74.25 MHz） |
| 资源 | XLRs 22313/60800 (36.70%)、Memory Blocks 208/256 (81.25%)、DSP 4/160 |
| CDC | `No Synchronizer warnings to report` |
| 显示模式 | **固定 mode 0** = 同视野左右分屏。可用串口命令 `D0..D3` 在运行期切换，不需要重新编译 |
| 调参通道 | 板载 UART 115200 8N1（`o_uart_txd`→`GPIOR_28`/R14，`i_uart_rxd`→`GPIOL_02`/R4），PC 端 `tools/alg_tuner.py` |
| **上板状态** | ✅ **JTAG 下载成功**（JTAG ID `0x10660A79`）；✅ **串口通道上板实测 9/9 OK**；✅ **GUI 真板端到端 PASS**；❌ **肉眼画面仍未确认** |
| 内容 | 灰度 → 3×3 中值 → 5×5 高斯 → Sobel(幅值+方向) → NMS → 双阈值滞后(58/21) → 去孤点 → 显示 |
| 已验证程度 | RTL + 仿真逐位对拍 + 编译/时序通过 + **JTAG 下载 + 串口链路真板实测**（**不含**肉眼画面） |

与上一版（`..._2019.bit`）的**唯一**差别是参数来源：这一版 `alg_top` 的 `cfg_*`
由 UART 寄存器组驱动，上一版接的是常量。算法 RTL 一行未改，**每个默认值都等于它
替换掉的那个常量**，所以不插串口线时画面与上一版逐位一致。

协议表、GUI 用法与实测记录见 [`../docs/运行期调参.md`](../docs/运行期调参.md)。

## 2. `algo_canny_splitonly_20260926_2019.bit` —— 上一版（固定左右分屏，**已被上面那份取代**）

| 项 | 值 |
| --- | --- |
| 来源提交 | `56867bb43c75c094fa14dd37612a64f82174a14b`（分支 `py-algo-rtl`） |
| 编译时间 | 2026-09-26 20:19:14 |
| 字节数 | 2420499 |
| SHA-256 | `A7234BB845C8E067BA2ABADBE45BF832B3A6BF580D77ECDC938CFC1317A7B1B7` |
| 工具 | Efinity 2026.1.132.4.5 |
| 流程结果 | `map` PASS、`interface` PASS、`pnr` PASS、`pgm` PASS |
| 时序 | `hdmi_tx_slow_clk` setup **+4.843 ns** / hold **+0.031 ns**；全设计无负 slack；该时钟最大可分析频率 115.942 MHz（约束 74.25 MHz） |
| 资源 | XLRs 21351/60800 (35.12%)、Memory Blocks 208/256 (81.25%)、DSP 4/160 |
| 显示模式 | **固定 mode 0** = 同视野左右分屏（左半屏灰度全画幅 / 右半屏边缘全画幅，2:1 水平抽取）。**不再轮换** |
| **上板状态** | ✅ JTAG 下载成功（2026-09-26 20:2x，JTAG ID `0x10660A79`）；❌ 肉眼画面未确认。**已被上面 `..._2037.bit` 取代** |
| 内容 | 灰度 → 3×3 中值 → 5×5 高斯 → Sobel(幅值+方向) → NMS → 双阈值滞后(58/21) → 去孤点 → 显示 |
| 已验证程度 | RTL 实现 + 仿真逐位对拍 + 编译/时序通过 + **JTAG 下载**（**不含**肉眼画面） |

算法来源、逐级映射与对拍数据见 `docs/ALGO_RTL.md`。

## 3. `algo_canny_full_20260926_1954.bit` —— 更早（含模式轮换，已被取代）

| 项 | 值 |
| --- | --- |
| 来源提交 | `4fcc6dbef0bce2090ab934cc1ab13f63c84f6c51` |
| 编译时间 | 2026-09-26 19:54:52 |
| 字节数 | 2422623 |
| SHA-256 | `0B1354A8C08C544B40801815378BCD93DB604210A1BC1CC805BE2592CC0AED89` |
| 时序 | `hdmi_tx_slow_clk` setup +5.316 ns / hold +0.031 ns |
| 资源 | XLRs 21593/60800 (35.51%)、Memory Blocks 208/256、DSP 4/160 |
| 显示模式 | 每 128 帧轮换 0/1/2/3（**已按需求移除**） |
| **上板状态** | ✅ JTAG 下载成功（2026-09-26 19:5x）；❌ 肉眼画面未确认 |

与当前版的唯一差别就是显示模式：算法链、参数、链路完全相同。
保留它是因为"JTAG 下载成功"这条证据最早记在它身上，便于对照。

## 4. `pre_algo_edge_display_720p_20260926_1728.bit` —— 移植前的旧基线

| 项 | 值 |
| --- | --- |
| 用途 | 算法移植**之前**的 `edge_display_720p`（灰度 + Sobel）位流，作为对照/回退参考 |
| 编译时间 | 2026-09-26 17:28:52 |
| 字节数 | 2333919 |
| SHA-256 | `140E575936B2222E8AAC808A7E7827CED124638A19106A38B3E0260C1A1B2F6A` |
| **上板状态** | ❌ 未下载、未上板确认 |

> 它与 `known_good/edge_detect_720p_verified.bit` 同源思路但**不是**同一份文件，
> 请勿与已验证恢复位流混淆。

## 5. `known_good/edge_detect_720p_verified.bit`（不在本目录，仅列出以便对照）

| 项 | 值 |
| --- | --- |
| 状态 | ✅ **已在板上肉眼验证**（左半灰度 / 右半 Sobel 黑白边缘，实时变化） |
| 字节数 | 2333919 |
| SHA-256 | `146D627FF082B7DF383068A9511EAE1B5758CDEABE6B7562E0DA2A6755D0A355` |

任何时候需要"至少能看到画面"，用这一份。

---

## 6. `known_good/best_epf_guided_99540aa_20260928.bit` —— 当前最佳版（回退基线）

| 项 | 值 |
| --- | --- |
| 位流 | 与第 0 节 `rollback_epf_guided_99540aa_20260928.bit` 同一份文件（SHA-256 相同），复制进 `known_good/` 便于需要回退时直接取用 |
| 来源提交 | `99540aa`（分支 `epf-guided`，即 `no-temp` 的基线提交） |
| 字节数 | 2540034 |
| SHA-256 | `DB3DD3727AC6BDCEED2E4B12461AC84EF4357502D0A9189B939A7ADD63502BCD` |
| **状态** | ✅ 板主 2026-09-28 认定：**当前最佳版本**，作为后续改动的回退基线；板上正在运行的就是这一份 |
| 回退用法 | `tools\flash_best.bat`（等价于 `tools\flash_candidate.bat known_good\best_epf_guided_99540aa_20260928.bit`），烧录前先关掉调参界面 |


## 哈希校验

在仓库根目录执行：

```powershell
Get-ChildItem candidate_bitstreams,known_good -Filter *.bit -Recurse |
  ForEach-Object { "{0}  {1}  {2}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash, $_.Length, $_.FullName }
```

期望值（2026-09-26 实测）：

| 文件 | SHA-256 |
| --- | --- |
| `candidate_bitstreams/algo_uart_tuner_splitonly_20260926_2037.bit` | `4F9D7D387627031A0D8F1AC6F4B0AE5AB1CC94D716D6238D8ADBCB51ECC3EB05` |
| `candidate_bitstreams/algo_canny_splitonly_20260926_2019.bit` | `A7234BB845C8E067BA2ABADBE45BF832B3A6BF580D77ECDC938CFC1317A7B1B7` |
| `candidate_bitstreams/algo_canny_full_20260926_1954.bit` | `0B1354A8C08C544B40801815378BCD93DB604210A1BC1CC805BE2592CC0AED89` |
| `candidate_bitstreams/pre_algo_edge_display_720p_20260926_1728.bit` | `140E575936B2222E8AAC808A7E7827CED124638A19106A38B3E0260C1A1B2F6A` |
| `known_good/edge_detect_720p_verified.bit` | `146D627FF082B7DF383068A9511EAE1B5758CDEABE6B7562E0DA2A6755D0A355` |
| `candidate_bitstreams/rollback_epf_guided_99540aa_20260928.bit` | `DB3DD3727AC6BDCEED2E4B12461AC84EF4357502D0A9189B939A7ADD63502BCD` |
| `known_good/best_epf_guided_99540aa_20260928.bit` | `DB3DD3727AC6BDCEED2E4B12461AC84EF4357502D0A9189B939A7ADD63502BCD` |

## 归档说明

- 2026-09-26 19:49 曾归档过一份候选位流（`..._1949.bit`），随后修正了
  `alg_top.v` / `alg_stream_delay.v` 的**注释**（旧的 `alg_disp`/`DLY_RGB` 描述）并重编译。
  综合结果与时序/资源完全相同（注释不影响网表），但为了让"入库源码"与"归档位流"
  严格一一对应，已删除 1949 那份，改为归档 1954 那份。
- 归档位流对应的源码提交必须能在 `git log` 里找到；提交信息里注明证据等级。
- **每次改动 RTL 后都要重新编译并归档**，因为位流与源码必须一一对应；
  同时旧位流要标明是否已被取代。
