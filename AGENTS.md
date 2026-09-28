# 工程协作约束

- 以赛题 PDF 第 23–26 页为需求来源；先满足基础要求，再做进阶项。对未完成项如实标注，不因编译通过就宣称上板成功。
- `main` 是已在板上验证的灰度 + Sobel 基线。不要覆盖 `known_good/edge_detect_720p_verified.bit`，不要破坏可回退版本。
- 新功能在独立分支完成；保持 `ti60f225_oob.peri.xml` 引脚和 DDR/HDMI/摄像头链路不变，除非有明确的板级证据与队员同意。
- 修改后至少检查 map、interface、pnr、pgm 结果及 setup/hold 时序；再请求板子持有人安排 JTAG 与屏幕验证。
- 未经板子持有人明确指示，不自动烧录 FPGA，不执行 Flash 擦写，不公开厂商资料；推送前检查敏感数据、授权与文件体积。
- 候选位流仅放 `candidate_bitstreams/` 并记录来源提交、SHA-256 和未/已上板状态；只有肉眼验证通过的恢复位流才能放 `known_good/`。不要用实验位流覆盖已验证基线。
- 提交说明需区分 RTL 实现、编译通过、JTAG 下载、肉眼观察到正确画面这四个不同等级的证据。

## 文件归档（板子持有人 2026-09-24 反复强调的硬性要求）

- **AI 助手和队员生成的每一个文件，默认都要提交进本仓库并推送到私有远端**：RTL、约束、脚本、分析记录、证据截图、日志结论、报告与文档、候选位流等，都算在内。
- 确实不重要的临时文件可以不入库，例如 `outflow/`、缓存、一次性草稿、临时波形。这个取舍由生成者自己判断，不必逐个解释。
- 目的：资料落在仓库里，就不依赖任何一段聊天记录或某一台电脑。**聊天窗口不是备份**；只留在对话里的东西，换线程或换机器就找不回来了。

## 改代码前必须先做备份（板子持有人 2026-09-27 要求）

> 每次修改代码时要确保上一版本的代码有备份，不要直接在上一版的代码里面直接改。

每次动手改文件之前，先跑一遍下面的三步，看到 `RESULT: BACKUP VERIFIED RESTORABLE`
之后才允许改。工具说明见 `tools/backup/README.md`。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\backup\make_backup.ps1 -Label 这次要改什么
powershell -NoProfile -ExecutionPolicy Bypass -File tools\backup\verify_backup.ps1 -Snapshot latest
```

- 快照落在仓库外的 `D:\FPGA_Project\_backups\<时间戳>_<标签>\`：`worktree\` 逐字节文件副本、
  `worktree_team\`、`gitdir\` 完整对象库与 reflog、`git_all.bundle` 全部分支、
  `STATUS.txt`、`MANIFEST.sha256`、`RESTORE.txt`；索引见 `_backups\INDEX.txt`。
- 默认排除可再生的 `outflow/`、`work_*/`、`work/`，一份约 78 MB；要连构建产物一起留档加 `-Full`。
- **还原走 `worktree\` 文件副本，不要用 `git clone` bundle**：`.gitattributes` 把 `*.v` 等标成
  `text`，clone 出的源文件会被改写成 CRLF，内容相同但哈希不同；`*.bit` 是 `binary`，两条路径都一致。
- `tools\backup\*.ps1` 与 `D:\FPGA_Project\_backups\*.ps1` 是两份，改动后手工同步并比对 SHA-256。

## 冻结版本：先复制、再修改（板子持有人 2026-09-27 再次强调）

> 现在这个版本的代码先放那不动；后面如果要修改，不能直接在这个代码上改，
> 应该把这个代码复制一份，再在它基础上修改，记住了。

- 冻结版 = `D:\FPGA_Project\imx219_pyrtl`（分支 `py-algo-rtl`，提交 `691a46d`，对应板上
  位流 SHA-256 `BEAF7321…3A51`）。此后视作只读样板，不直接在它里面改代码。
- 新改动一律先复制出新工作目录再改，示例（基于冻结提交建新分支 + 新检出）：
  `git -C D:\FPGA_Project\imx219_pyrtl worktree add -b <新分支名> D:\FPGA_Project\<新目录名> 691a46d`
- 新目录与主仓库共享同一个 `.git`（与 `imx219_team` 属同一种“同一仓库、两份检出”关系）；
  对外交付/移交时用 `tools\make_archive.ps1` 打包，不要直接拷 `.git`。
- 动手改任何文件之前，仍要先跑 `tools\backup\make_backup.ps1`（见上一节），双保险。
- 每个版本上板验证通过后，都用 `tools\make_archive.ps1` 另存压缩包归档；旧版本目录一律保留、不清理。

## 找代码 / 判断哪一份最新（2026-09-27）

不要凭记忆回答"最新代码在哪"。跑 `tools/code_map.ps1`，或直接双击
`D:\FPGA_Project\代码在哪.bat`。脚本只读，结果同时打印到屏幕并写入
`D:\FPGA_Project\CODE_MAP.txt`：每个 worktree 的分支/HEAD/提交时间/工作区是否干净/
该提交在不在 GitHub、所有分支按时间排序及各自检出在哪个目录、所有候选位流的时间与
SHA-256、最后给出两行结论（提交时间最新的代码、赛题4 交付物所在）。

当前事实（2026-09-27 实测）：

- **赛题4 代码 = `D:\FPGA_Project\imx219_pyrtl`，分支 `py-algo-rtl`。**
- `D:\FPGA_Project\imx219_team` 是**另一条已经分叉的线**（分支 `teammate-ip-v2`，队友 IP
  与画质验证，81 个提交我们这边没有）。它不是"更新的版本"，也不含赛题4 交付物。
- 两边**共享同一个 `.git`**（`D:\FPGA_Project\imx219_team\.git`），所以那两个目录不是两份
  拷贝，而是同一仓库两个分支的检出；在任一个里切分支都会换掉那个目录的内容。
- 板上正在跑的位流来自 `py-algo-rtl`，该文件只存在于 `imx219_pyrtl\candidate_bitstreams\`。
- "在不在 GitHub"要用 `git branch -r --contains <sha>` 判断，**不能**看
  `%(upstream:short)` 是否为空：本地分支没配跟踪关系并不代表没推送过。

## 2026-09-28 晚：TEMP 版不合格，已回退

- 分支 `temp-blend`（提交 `405701f`、`b4e4dcf`）的 **TEMP 时域降噪**经上板实测
  **不合格**：边缘闪烁没有改善，反而出现拖影/重影，比加 TEMP 之前更差。
  根因：参考实现 `temporal_blend` 是递归(IIR)（融合结果写回 prev），本版 RTL 是
  FIR（只和"上一帧原始画面"混合）；TEMP 越大差别越大，TEMP=90 时 FIR 噪声比 0.906
  （几乎不降噪）而 IIR 为 0.229。详见 `docs/时序降噪_移植说明.md` §3.2。
- 失败版本整目录保留在 `D:\FPGA_Project\imx219_temp`：根目录已加
  `不合格_已废弃_TEMP时域降噪_20260928.md`，并打标签 `rejected-temp-20260928`；
  该目录不再修改。
- **当前最新工作副本 = `D:\FPGA_Project\imx219_notemp`（分支 `no-temp`，基线
  `99540aa`，即加 TEMP 之前的 epf-guided 版本）。** 回退位流已归档到
  `candidate_bitstreams/rollback_epf_guided_99540aa_20260928.bit`
  （SHA-256 `DB3DD3727AC6…502BCD`），并于 2026-09-28 晚重新烧到板上。
- 后续改动仍按"先备份、再复制新目录"执行。

## 2026-09-28 晚（二）：本版定为"最佳版"（回退基线）

- 板主 2026-09-28 确认：**`D:\FPGA_Project\imx219_notemp`（分支 `no-temp`，提交 `f253127`）
  = 当前最佳版本**；后续所有修改都从它复制新目录/新分支进行，本目录保持不动。
- 对应位流已复制进 `known_good/best_epf_guided_99540aa_20260928.bit`
  （与 `candidate_bitstreams/rollback_epf_guided_99540aa_20260928.bit` 同一份，
  SHA-256 `DB3DD3727AC6…502BCD`）。回退烧录用 `tools\flash_best.bat`，
  或双击 `D:\FPGA_Project\烧录最佳版.bat`。
- 回退四件套（内容同一份）：本目录源码、`_backups\20260928_174632_post-rollback-notemp`
  快照、`_archives\` 归档 zip、GitHub `no-temp` 分支。
- 提醒：JTAG 烧录是易失的，板子断电后需要重新烧录，用上面的位流/脚本即可。

## 2026-09-28 晚（三）：断线桥接 BRG（`imx219_smooth`，分支 `canny-smooth`）

- 板主授权：**不要局限于 GitHub 参考 Python**，去外部检索更好的方案；"最佳版"
  `imx219_notemp` 保持只读，改动放到新副本。外部检索结论：Canny 边缘"断成几截"
  的标准解法就是**边缘图形态学闭运算连线**（cv2 里一行
  `morphologyEx(edge, MORPH_CLOSE, kernel)`），没有可直接移植的 Verilog 开源实现，
  所以按闭运算语义手写了 `rtl/algo/alg_ebridge.v`（7×7 二值窗口、只沿 4 条轴线，
  补 1/3/5 像素空洞 = BRG 1/2/3，BRG=0 逐位透传）。
- 新副本：`D:\FPGA_Project\imx219_smooth`（分支 `canny-smooth`，基线 `a390a99`），
  改前快照 `_backups\20260928_180719_pre-canny-smooth`（已验证可恢复）。
- **关键坑（已踩已解）**：`ROWD` 11→14 后 `alg_vdisp` 行缓存 12→15 行，
  `simple_dual_port_ram` 会把深度向上取成 2 的幂（19200→32768），
  BRAM 208→278，PnR 直接 `capacity=256 usage=278` 失败。新增精确深度的
  `rtl/algo/alg_ring_ram.v`（按 1024 深逐块拼）后 278→242，编译四阶段全 PASS。
  以后再加算法级只读看 `ROWD` 的改动，必须先算 `ROWS*W` 会不会跨 2 的幂。
- 状态：`check_ebridge.py` + `check_chain.py` 全 PASS，位流已生成
  （`outflow\ti60f225_oob.bit`），**待烧录、待上板肉眼确认**；
  在上板确认之前，"最佳版"仍然是 `imx219_notemp`，回退用 `烧录最佳版.bat`。
- 调参台新增 `B<n>`（断线桥接 0..3，默认 2，只 mode 1/2 有效），
  板端状态行从 77 字节变成 **82 字节**（`... EPF2 GF0400 BRG2 CAM0077=C0`），
  PC 侧正则对旧行仍兼容（缺字段显示 `--`）。
