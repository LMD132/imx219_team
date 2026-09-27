<#
  make_archive.ps1 -- pack the current version of the worktree into one .zip.

  The archive is self-describing: it carries a PACKAGE_INFO.txt naming the
  branch, the commit and how to restore, a git bundle holding every branch
  (so the history travels with the code), and a SHA-256 list of every source
  file it contains.

  The worktree's own .git is a 64 byte text file pointing at an absolute
  path on this machine, so it is left out; the bundle replaces it.

  Usage:
     powershell -NoProfile -ExecutionPolicy Bypass -File tools\make_archive.ps1
     powershell -NoProfile -ExecutionPolicy Bypass -File tools\make_archive.ps1 -Label before-submit
     powershell -NoProfile -ExecutionPolicy Bypass -File tools\make_archive.ps1 -SourceOnly
#>
[CmdletBinding()]
param(
    [string]$Worktree = 'D:\FPGA_Project\imx219_pyrtl',
    [string]$OutDir   = 'D:\FPGA_Project\_archives',
    [string]$Label    = '',
    [switch]$SourceOnly,
    [switch]$KeepStage
)

$ErrorActionPreference = 'Stop'
$encBom = New-Object System.Text.UTF8Encoding($true)
$nl = [string][char]13 + [string][char]10

function Say([string]$m) { Write-Host $m }

function Invoke-Git {
    param([string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $txt  = ((& git @GitArgs 2>&1) | ForEach-Object { $_.ToString() }) -join "`n"
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    $global:LASTEXITCODE = 0
    return [pscustomobject]@{ Text = $txt.Trim(); Code = $code }
}

function Copy-Tree {
    param([string]$Src, [string]$Dst, [string[]]$Xd, [string[]]$Xf)
    $rcArgs = @($Src, $Dst, '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($Xd) { $rcArgs += '/XD'; $rcArgs += $Xd }
    if ($Xf) { $rcArgs += '/XF'; $rcArgs += $Xf }
    & robocopy @rcArgs | Out-Null
    $code = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($code -ge 8) { throw ("robocopy failed with code {0}" -f $code) }
}

$tar = (Get-Command tar -ErrorAction SilentlyContinue).Source
if (-not $tar) { throw 'bsdtar (tar.exe) not found; it is needed for UTF-8 correct zip names' }

# ---------------------------------------------------------------- version
$branch = (Invoke-Git @('-C', $Worktree, 'rev-parse', '--abbrev-ref', 'HEAD')).Text
$sha    = (Invoke-Git @('-C', $Worktree, 'rev-parse', '--short', 'HEAD')).Text
$shaFull= (Invoke-Git @('-C', $Worktree, 'rev-parse', 'HEAD')).Text
$when   = (Invoke-Git @('-C', $Worktree, 'log', '-1', '--format=%ci')).Text
$subj   = (Invoke-Git @('-C', $Worktree, 'log', '-1', '--format=%s')).Text
$dirty  = (Invoke-Git @('-C', $Worktree, 'status', '--porcelain', '--untracked-files=all')).Text
$dirtyCount = 0
if ($dirty) { $dirtyCount = @($dirty -split "`n" | Where-Object { $_.Trim() }).Count }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$leaf  = Split-Path $Worktree -Leaf
$pkg   = '{0}_{1}_{2}' -f $leaf, $branch, $sha
if ($Label) { $pkg = '{0}_{1}' -f $pkg, $Label }
$pkg   = '{0}_{1}' -f $pkg, $stamp
$zipPath = Join-Path $OutDir ($pkg + '.zip')

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stageRoot = Join-Path $OutDir ('_stage_' + $stamp)
$stagePkg  = Join-Path $stageRoot $pkg
New-Item -ItemType Directory -Force -Path $stagePkg | Out-Null

Say ("packing     : {0}" -f $pkg)
Say ("version     : {0} @ {1}  ({2})" -f $branch, $sha, $when)
Say ("worktree    : {0}" -f $(if ($dirty) { "有未提交改动（$dirtyCount 处）" } else { '干净' }))

# ---------------------------------------------------------------- copy
$xd = @()
if ($SourceOnly) { $xd = @('outflow', 'work_syn', 'work_pnr', 'work_dbg', 'ip', 'ooc') }
Say ("copying     : 全部文件{0}" -f $(if ($SourceOnly) { '（排除构建产物）' } else { '' }))
Copy-Tree -Src $Worktree -Dst $stagePkg -Xd $xd -Xf @('.git')

# ---------------------------------------------------------------- info dir
$infoDir = Join-Path $stagePkg '_archive_info'
New-Item -ItemType Directory -Force -Path $infoDir | Out-Null

$bundlePath = Join-Path $infoDir 'GIT_HISTORY.git_all.bundle'
$r = Invoke-Git @('-C', $Worktree, 'bundle', 'create', $bundlePath, '--all')
if ($r.Code -ne 0) { throw "git bundle create failed: $($r.Text)" }

# ---------------------------------------------------------------- manifest
Say 'hashing     : source files'
$skipTop = @('outflow', 'work_syn', 'work_pnr', 'work_dbg', 'ip', 'ooc', '.git', '_archive_info')
$sums = New-Object System.Collections.Generic.List[string]
$nFiles = 0
foreach ($f in (Get-ChildItem -LiteralPath $stagePkg -Recurse -Force -File -ErrorAction SilentlyContinue)) {
    $rel = $f.FullName.Substring($stagePkg.Length + 1)
    if ($skipTop -contains $rel.Split([char]92)[0]) { continue }
    $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
    $sums.Add(("{0}  {1}" -f $h, $rel.Replace([char]92, '/')))
    $nFiles++
}
[System.IO.File]::WriteAllLines((Join-Path $infoDir 'SHA256SUMS.txt'), $sums, $encBom)

# ---------------------------------------------------------------- info text
$bundleMB = [math]::Round((Get-Item -LiteralPath $bundlePath).Length / 1MB, 2)
$a = New-Object System.Collections.Generic.List[string]
$a.Add('这个压缩包是什么')
$a.Add('================')
$a.Add('')
$a.Add('内容  : FPGA 竞赛赛题4（边缘检测）的 RTL 实现，完整工作区。')
$a.Add('分支  : ' + $branch)
$a.Add('提交  : ' + $sha + '  (' + $shaFull + ')')
$a.Add('提交时间: ' + $when)
$a.Add('提交说明: ' + $subj)
$a.Add('打包时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
$a.Add('打包来源: ' + $Worktree)
$a.Add('工作区状态: ' + $(if ($dirty) { '有未提交改动，见 _archive_info\UNCOMMITTED.txt' } else { '干净，内容与该提交完全一致' }))
$a.Add('')
$a.Add('包含什么')
$a.Add('--------')
$a.Add('  rtl\            顶层与算法 RTL（rtl\algo\ 为赛题4 算法链，11+ 模块）')
$a.Add('  sim\            逐位对拍测试平台、金标准模型、以及 Python 参考源快照')
$a.Add('  tools\          PC 端调参界面、串口工具、备份工具、代码位置体检')
$a.Add('  docs\           算法溯源、上板记录、运行期调参说明、交付报告')
$a.Add('  candidate_bitstreams\  候选位流（含板上正在运行的那个）')
$a.Add('  known_good\     已验证可回退的位流')
$a.Add('  outflow\ work_pnr\      Efinity 构建产物（可重新生成）')
$a.Add('  CONTEST_CHECKLIST.md   赛题要求逐条对照与证据等级')
$a.Add('  _archive_info\  本说明、git 全量历史包、文件 SHA-256 清单')
$a.Add('')
$a.Add('注意：包内没有 .git')
$a.Add('------------------')
$a.Add('原工作区的 .git 只是一个 64 字节文本文件，内容指向本机绝对路径，')
$a.Add('换台机器就没意义，所以没有放进来。真正的历史在')
$a.Add('  _archive_info\GIT_HISTORY.git_all.bundle')
$a.Add('它包含所有分支。要恢复成可用的 git 仓库：')
$a.Add('')
$a.Add('  git clone _archive_info\GIT_HISTORY.git_all.bundle my_repo')
$a.Add('  git -C my_repo branch -a')
$a.Add('')
$a.Add('只想要代码、不需要 git 历史，直接用解压出来的文件即可：')
$a.Add('')
$a.Add('  git clone 会把带 text 属性的源文件（*.v 等）改写成 CRLF；')
$a.Add('  解压出来的这份文件是逐字节原样，需要完全一致时请用解压的这份。')
$a.Add('')
$a.Add('校验')
$a.Add('----')
$a.Add('  _archive_info\SHA256SUMS.txt 列出每个源文件的 SHA-256，路径相对于包根目录。')
$a.Add('  校验（PowerShell，在包根目录执行）：')
$a.Add('    Get-FileHash -Algorithm SHA256 <文件>')
$a.Add('  构建产物目录（outflow\ work_pnr\ 等）未列入清单。')
$a.Add('')
$a.Add('这个包本身由工作区原样复制而成，不是从 git 导出，')
$a.Add('所以未提交的改动如果有，也在里面。')
[System.IO.File]::WriteAllLines((Join-Path $infoDir 'PACKAGE_INFO.txt'), $a, $encBom)

if ($dirty) {
    [System.IO.File]::WriteAllLines((Join-Path $infoDir 'UNCOMMITTED.txt'),
        ($dirty -split "`n"), $encBom)
}

# ---------------------------------------------------------------- zip
Say ("zipping     : {0}" -f $zipPath)
$tarOut = & $tar --options zip:hdrcharset=UTF-8 -a -cf $zipPath -C $stageRoot $pkg 2>&1
if ($LASTEXITCODE -ne 0) { throw "tar failed: $tarOut" }
$global:LASTEXITCODE = 0

$zipBytes = (Get-Item -LiteralPath $zipPath).Length
$zipHash  = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLower()

Say ("files       : {0}" -f $nFiles)
Say ("bundle      : {0} MB" -f $bundleMB)
Say ("zip size    : {0:N1} MB" -f ($zipBytes / 1MB))
Say ("zip sha256  : {0}" -f $zipHash)

# ---------------------------------------------------------------- self check
# bsdtar stores non-ASCII names in the ANSI code page unless asked otherwise,
# which round-trips on this machine but turns into mojibake anywhere else.
# Re-read the finished zip and refuse to hand over a broken one.
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
$zr = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try { $entryNames = @($zr.Entries | ForEach-Object { $_.FullName }) } finally { $zr.Dispose() }
$fileEntries = @($entryNames | Where-Object { -not $_.EndsWith('/') })
$mojibake = @($fileEntries | Where-Object { $_ -like "*$([char]0xFFFD)*" })
$set = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($e in $fileEntries) { [void]$set.Add($e) }
$expected = @()
foreach ($f in (Get-ChildItem -LiteralPath $stagePkg -Recurse -Force -File)) {
    $expected += ($pkg + '/' + $f.FullName.Substring($stagePkg.Length + 1).Replace([char]92, '/'))
}
$missing = @($expected | Where-Object { -not $set.Contains($_) })
$nonAscii = @($fileEntries | Where-Object { $_ -match '[^\x00-\x7F]' })
Say ("zip entries : {0} files, {1} with non-ASCII names" -f $fileEntries.Count, $nonAscii.Count)
if ($mojibake.Count -gt 0) { throw ("zip entry names are not valid UTF-8: " + ($mojibake -join ', ')) }
if ($missing.Count -gt 0) { throw ("zip is missing {0} file entries, first: {1}" -f $missing.Count, $missing[0]) }
Say 'zip names   : UTF-8 correct, no file missing'

# ---------------------------------------------------------------- index
$idx = Join-Path $OutDir 'ARCHIVE_INDEX.txt'
if (-not (Test-Path -LiteralPath $idx)) {
    [System.IO.File]::WriteAllText($idx, ('stamp|package|branch|commit|commit_date|zip_bytes|zip_sha256' + $nl), $encBom)
}
[System.IO.File]::AppendAllText($idx,
    (('{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $stamp, ($pkg + '.zip'), $branch, $sha, $when, $zipBytes, $zipHash) + $nl), $encBom)

# ---------------------------------------------------------------- cleanup
if (-not $KeepStage) {
    $resolvedOut = (Resolve-Path -LiteralPath $OutDir).Path.TrimEnd([char]92)
    $full = (Resolve-Path -LiteralPath $stageRoot).Path
    if (-not $full.StartsWith($resolvedOut + [char]92, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "refusing to delete outside output dir: $full"
    }
    Remove-Item -LiteralPath $full -Recurse -Force
    Say 'stage       : removed'
}

Say ''
Say ("RESULT: OK  ->  {0}" -f $zipPath)
exit 0