# tools/backup — 改代码前的强制备份

## 为什么需要它

板子持有人 2026-09-27 的要求：

> 每次修改代码时要确保上一版本的代码有备份，不要直接在上一版的代码里面直接改。

git 本身能回退已提交的内容，但下面的情况 git 救不了：

- 改动还没 commit 就被改坏了，而你想回到"动手前那一秒"；
- 上游仓库连不上，`origin` 的某个分支其实只存在于本机（本仓库现有 3 个这样的分支）；
- 误删了整个 worktree，连 `.git` 都一起没了；
- 想看"上一版的某一天"到底长什么样，而不想动当前工作区。

所以每次动手前，先落一份**与 git 无关的、可独立还原的**快照。

## 用法

```powershell
cd D:\FPGA_Project\imx219_pyrtl

# 1) 动手之前 —— 给当前版本拍快照
powershell -NoProfile -ExecutionPolicy Bypass -File tools\backup\make_backup.ps1 -Label 改什么

# 2) 确认这份快照真的能还原
powershell -NoProfile -ExecutionPolicy Bypass -File tools\backup\verify_backup.ps1 -Snapshot latest

# 3) 看到 RESULT: BACKUP VERIFIED RESTORABLE 之后，才动手改文件
```

`-Label` 写这次打算改什么，方便事后认人。也可以直接双击
`D:\FPGA_Project\_backups\backup_now.bat`。

## 快照里有什么

落在 `D:\FPGA_Project\_backups\<yyyyMMdd_HHmmss>[_标签]\`：

| 内容 | 说明 |
| --- | --- |
| `worktree\` | `imx219_pyrtl` 全部文件的**逐字节副本**（还原首选路径） |
| `worktree_team\` | `imx219_team` 的全部文件副本 |
| `gitdir\` | 共享 `.git` 的完整副本：所有分支、所有 reflog、所有已提交位流 |
| `git_all.bundle` | 可独立 `git clone` 出的全量包，含 7 个本地分支与全部远端跟踪分支 |
| `STATUS.txt` | 分支、HEAD、工作区是否干净、各分支上游、算法参考源清单 |
| `MANIFEST.sha256` | `worktree\` 里每个源文件的 SHA-256 |
| `RESTORE.txt` | 还原步骤，含下面两个坑 |
| （仓库外）`INDEX.txt` | 所有历史快照的索引 |

默认**排除**可再生的东西，所以一份快照约 78 MB 而不是 1.07 GB：
`outflow/`、`work_syn/`、`work_pnr/`、`work_dbg/`、`ip/`、`ooc/`（Efinity 构建产物），
以及 `work/`（oss-cad-suite 工具链，约 880 MB，可重下，用 `ALG_OSS_BIN` 指向它）。
要连这些一起留档时加 `-Full`。

## 两个已验证的坑

1. **还原请用 `worktree\` 的文件副本，不要用 `git clone` bundle。**
   `.gitattributes` 把 `*.v`、`*.xml`、`*.sdc`、`*.md` 标成 `text`，
   在本机检出时会把 LF 改写成 CRLF。实测 `rtl/algo/alg_top.v`：
   工作区 10862 B 纯 LF，clone 出来 11101 B 纯 CRLF，内容相同、哈希不同。
   `*.bit` 标成 `binary` 不会被改写，两条路径位流都一致。
2. **`git bundle verify` 把 "is okay" 写在 stderr。**
   脚本里若开着 `$ErrorActionPreference = 'Stop'`，这行会被当成致命错误终止脚本。
   `verify_backup.ps1` 里用 `Git-Capture` 包装解决。

## 保留期

```powershell
# 只保留当天最近 20 份，更早的当天快照删掉（跨天的不动）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\backup\make_backup.ps1 -KeepN 20
```

删除前脚本会 `Resolve-Path` 并确认目标仍在 `_backups\` 之内，否则直接报错退出。

## 两份副本

仓库里 `tools\backup\*.ps1` 是受版本管理的那份；
`D:\FPGA_Project\_backups\*.ps1` 是仓库外的那份，整个 worktree 没了也能用。
改过其中一份之后，手工同步另一份，并用 SHA-256 确认两边一致：

```powershell
Get-FileHash tools\backup\make_backup.ps1, D:\FPGA_Project\_backups\make_backup.ps1 -Algorithm SHA256
```
## 已验证的证据（2026-09-27，不是推断）

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 文件副本完整性 | `verify_backup.ps1 -Snapshot latest` | 249 / 249 文件 SHA-256 全匹配，现网无遗漏文件 |
| bundle 完整性 | `git bundle verify <快照>\git_all.bundle` | `is okay`，**19 个 ref** 全在包内（7 个本地分支 + 8 个远端跟踪 + HEAD + `refs/original/*`） |
| 对象库完整性 | `verify_backup.ps1` 第 4 项 | `gitdir\objects\` 存在且完整，含全部 reflog |
| **还原演练** | `robocopy /MIR <快照>\worktree <临时目录>`，再与现网逐字节比对 | robocopy 退出码 1（成功），**249 文件 0 损坏 0 缺失**，`RESULT: RESTORE DRILL PASS` |
| 从 bundle 独立重建 | `git clone <快照>\git_all.bundle` | 7 个本地分支全部可恢复为远端跟踪分支，HEAD 落在正确的提交 |

已验证的两份快照：

| 快照 | 覆盖的提交 | 说明 |
| --- | --- | --- |
| `20260927_144635_baseline-f39fa95` | `f39fa95` | 引入备份机制**之前**的状态 |
| `20260927_144941_post-backup-policy-f67acb1` | `f67acb1` | 引入备份机制之后的状态 |