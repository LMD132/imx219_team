<#
  code_map.ps1 -- answer one question: "where is the latest code right now?"

  Scans every git worktree under D:\FPGA_Project, and for each one prints the
  branch, the HEAD commit and its date, whether the working tree is dirty,
  whether HEAD is on GitHub or only on this disk, which of the contest-4
  marker files are present, and the newest bitstream it holds. Then it prints
  a plain-language verdict and writes the whole thing to
  D:\FPGA_Project\CODE_MAP.txt.

  Read-only. It never writes inside any worktree.

  Usage:
     powershell -NoProfile -ExecutionPolicy Bypass -File tools\code_map.ps1
#>
[CmdletBinding()]
param(
    [string]$SearchRoot = 'D:\FPGA_Project',
    [string]$BackupRoot = 'D:\FPGA_Project\_backups',
    [string]$ReportPath = 'D:\FPGA_Project\CODE_MAP.txt'
)

$ErrorActionPreference = 'Stop'
$out    = New-Object System.Collections.Generic.List[string]
$encBom = New-Object System.Text.UTF8Encoding($true)

function Emit([string]$line) { $out.Add($line); Write-Host $line }

function Invoke-Git {
    param([string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $txt  = ((& git @GitArgs 2>&1) | ForEach-Object { $_.ToString() }) -join "`n"
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    $global:LASTEXITCODE = 0
    return [pscustomobject]@{ Text = $txt.Trim(); Code = $code }
}

function First-Line([string]$t) { ($t -split "`n")[0].Trim() }

# markers that identify the contest-4 deliverable
$markers = @(
    'rtl\algo\alg_top.v',
    'tools\alg_tuner.py',
    'CONTEST_CHECKLIST.md',
    'sim\algo\model\rtl_model.py',
    'tools\backup\make_backup.ps1'
)

Emit '=============================================================================='
Emit (' 代码位置体检  生成时间 {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Emit '=============================================================================='
Emit ''

# ---------------------------------------------------------------- discover
$worktrees = @()
foreach ($d in (Get-ChildItem -LiteralPath $SearchRoot -Directory -Force -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path -LiteralPath (Join-Path $d.FullName '.git'))) { continue }
    $common = (Invoke-Git @('-C', $d.FullName, 'rev-parse', '--git-common-dir')).Text
    if (-not $common) { continue }
    if (-not [System.IO.Path]::IsPathRooted($common)) { $common = Join-Path $d.FullName $common }
    $common = [System.IO.Path]::GetFullPath($common).TrimEnd('\')

    $branch = (Invoke-Git @('-C', $d.FullName, 'rev-parse', '--abbrev-ref', 'HEAD')).Text
    $sha    = (Invoke-Git @('-C', $d.FullName, 'rev-parse', '--short', 'HEAD')).Text
    $one    = (Invoke-Git @('-C', $d.FullName, 'log', '-1', '--format=%ci|%s')).Text
    $parts  = $one -split '\|', 2
    $when   = $parts[0]
    $subj   = if ($parts.Count -gt 1) { $parts[1] } else { '' }
    $dirtyN = @((Invoke-Git @('-C', $d.FullName, 'status', '--porcelain', '--untracked-files=all')).Text -split "`n" |
                Where-Object { $_.Trim() }).Count
    $rc = (Invoke-Git @('-C', $d.FullName, 'branch', '-r', '--contains', $sha)).Text
    $onRemote = -not [string]::IsNullOrWhiteSpace($rc) -and $rc -notmatch 'no such|error'

    $present = @()
    $missing = @()
    foreach ($m in $markers) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName $m)) { $present += $m } else { $missing += $m }
    }

    $bits = @()
    $bitDir = Join-Path $d.FullName 'candidate_bitstreams'
    if (Test-Path -LiteralPath $bitDir) {
        $bits = @(Get-ChildItem -LiteralPath $bitDir -Force -File -Filter *.bit -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending)
    }

    $worktrees += [pscustomobject]@{
        Path = $d.FullName; Name = $d.Name; Common = $common
        Branch = $branch; Sha = $sha; Date = $when; Subject = $subj
        Dirty = $dirtyN; OnRemote = $onRemote
        Present = $present; Missing = $missing
        NewestBit = if ($bits.Count) { $bits[0] } else { $null }
        IsContest = ($missing.Count -eq 0)
    }
}

# ---------------------------------------------------------------- per tree
Emit "【一】这台机器上现在有几份代码"
Emit ''
foreach ($w in ($worktrees | Sort-Object Date -Descending)) {
    Emit ("  {0}" -f $w.Path)
    Emit ("      分支 {0}    提交 {1}    {2}" -f $w.Branch, $w.Sha, $w.Date)
    Emit ("      说明 {0}" -f $w.Subject)
    Emit ("      工作区 {0}" -f $(if ($w.Dirty -gt 0) { "有 $($w.Dirty) 个未提交改动" } else { '干净，没有未提交改动' }))
    Emit ("      GitHub {0}" -f $(if ($w.OnRemote) { '这个提交已经在远端上' } else { '这个提交只在本地，远端还没有' }))
    Emit ("      赛题4标记文件 {0}/{1}" -f $w.Present.Count, $markers.Count)
    if ($w.Missing.Count -gt 0) { Emit ("      缺少 {0}" -f ($w.Missing -join ', ')) }
    if ($w.NewestBit) {
        Emit ("      最新位流 {0}  ({1} 字节, {2})" -f $w.NewestBit.Name, $w.NewestBit.Length, $w.NewestBit.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
    } else {
        Emit '      最新位流 （没有 candidate_bitstreams）'
    }
    Emit ''
}

# ---------------------------------------------------------------- all branches
Emit "【二】所有分支，按提交时间从新到旧"
Emit ''
$commonDirs = $worktrees | Select-Object -ExpandProperty Common -Unique
foreach ($cd in $commonDirs) {
    Emit ("  仓库: {0}" -f $cd)
    $host0 = ($worktrees | Where-Object { $_.Common -eq $cd } | Select-Object -First 1).Path
    $fmt = '%(committerdate:short)|%(refname:short)|%(objectname:short)|%(subject)'
    foreach ($line in (Invoke-Git @('-C', $host0, 'for-each-ref', '--sort=-committerdate', "--format=$fmt", 'refs/heads/')).Text -split "`n") {
        if (-not $line.Trim()) { continue }
        $f = $line -split '\|', 4
        $holder = ($worktrees | Where-Object { $_.Common -eq $cd -and $_.Branch -eq $f[1] } | Select-Object -First 1)
        $where = if ($holder) { "  <== 检出在 $($holder.Name)" } else { '' }
        $rcb = (Invoke-Git @('-C', $host0, 'branch', '-r', '--contains', $f[1])).Text
        $gh = if ([string]::IsNullOrWhiteSpace($rcb)) { '仅本地' } else { '远端有' }
        Emit ("    {0}  {1,-24} {2,-9} [{3}]  {4}{5}" -f $f[0], $f[1], $f[2], $gh, $f[3], $where)
    }
    Emit ''
}

# ---------------------------------------------------------------- bitstreams
Emit "【三】所有候选位流，新到旧"
Emit ''
foreach ($b in ($worktrees | Where-Object { $_.NewestBit } | ForEach-Object { Get-ChildItem -LiteralPath (Join-Path $_.Path 'candidate_bitstreams') -Force -File -Filter *.bit } | Sort-Object LastWriteTime -Descending | Select-Object -First 12)) {
    $owner = ($worktrees | Where-Object { $b.FullName.StartsWith($_.Path + '\') } | Select-Object -First 1).Name
    $h = (Get-FileHash -LiteralPath $b.FullName -Algorithm SHA256).Hash.Substring(0, 12)
    Emit ("  {0}  {1,-46} {2,9} B  sha256:{3}  [{4}]" -f $b.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $b.Name, $b.Length, $h, $owner)
}
Emit ''

# ---------------------------------------------------------------- verdict
Emit "【四】结论"
Emit ''
$newest = $worktrees | Sort-Object Date -Descending | Select-Object -First 1
$contest = $worktrees | Where-Object { $_.IsContest }
Emit ("  提交时间最新的代码: {0}" -f $newest.Path)
Emit ("      分支 {0} @ {1}  ({2})" -f $newest.Branch, $newest.Sha, $newest.Date)
Emit ''
if ($contest) {
    foreach ($c in $contest) {
        Emit ("  赛题4 交付物所在: {0}" -f $c.Path)
        Emit ("      分支 {0} @ {1}" -f $c.Branch, $c.Sha)
    }
} else {
    Emit '  赛题4 交付物: 没有找到一个同时具备全部标记文件的目录，需要人工确认'
}
Emit ''

# ---------------------------------------------------------------- snapshots
if (Test-Path -LiteralPath $BackupRoot) {
    $snaps = @(Get-ChildItem -LiteralPath $BackupRoot -Directory -Force -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match '^\d{8}_\d{6}' } | Sort-Object Name)
    Emit ("【五】本地备份快照 {0} 份（仓库外的独立副本）" -f $snaps.Count)
    Emit ''
    foreach ($s in ($snaps | Select-Object -Last 5)) {
        Emit ("  {0}   {1}" -f $s.Name, $s.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
    }
    Emit ''
    Emit ("  索引: {0}\INDEX.txt" -f $BackupRoot)
    Emit ''
}

Emit '=============================================================================='
Emit ' 提醒：git 的"最新"只到提交为止。未提交的改动、以及只在本地的提交，'
Emit '       远端和聊天记录都救不了你。改代码前先跑 tools\backup\make_backup.ps1。'
Emit '=============================================================================='

[System.IO.File]::WriteAllLines($ReportPath, $out, $encBom)
Write-Host ''
Write-Host ("已写入 {0}" -f $ReportPath)