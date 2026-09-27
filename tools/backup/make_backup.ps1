<#
  make_backup.ps1 -- snapshot the FPGA contest worktree BEFORE any code change.

  Rule being enforced: never edit code in place without holding a complete,
  restorable copy of the previous version.

  Creates, under D:\FPGA_Project\_backups\<yyyyMMdd_HHmmss>[_label]\ :
     worktree\        full file copy of the python-to-RTL worktree
     worktree_team\   full file copy of the teammate worktree
     gitdir\          full copy of the shared .git (every branch, every reflog entry)
     git_all.bundle   portable bundle of all branches and tags
     STATUS.txt       branch, HEAD, git status, worktree list, algorithm ref listing
     MANIFEST.sha256  sha256 of every source file
     RESTORE.txt      how to get back

  Usage:
     powershell -NoProfile -ExecutionPolicy Bypass -File make_backup.ps1
     powershell -NoProfile -ExecutionPolicy Bypass -File make_backup.ps1 -Label before-mode-swap
     powershell -NoProfile -ExecutionPolicy Bypass -File make_backup.ps1 -KeepN 20
#>
[CmdletBinding()]
param(
    [string]$Label        = '',
    [string]$Worktree     = 'D:\FPGA_Project\imx219_pyrtl',
    [string]$TeamWorktree = 'D:\FPGA_Project\imx219_team',
    [string]$BackupRoot   = 'D:\FPGA_Project\_backups',
    [int]$KeepN           = 0,
    [switch]$Full
)

$ErrorActionPreference = 'Stop'
$enc = New-Object System.Text.UTF8Encoding($false)

function Say([string]$m) { Write-Host $m }

function Copy-Tree {
    param([string]$Src, [string]$Dst, [string[]]$Xd)
    if (-not (Test-Path -LiteralPath $Src)) { throw "source missing: $Src" }
    $rcArgs = @($Src, $Dst, '/E', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($Xd) { $rcArgs += '/XD'; $rcArgs += $Xd }
    & robocopy @rcArgs | Out-Null
    $code = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    if ($code -ge 8) { throw ("robocopy failed with code {0} for {1}" -f $code, $Src) }
    return $code
}

function Write-Manifest {
    param([string]$Root, [string]$Out)
    $skipTop = @('outflow', 'work_syn', 'work_pnr', 'work_dbg', '.git', 'ip', 'ooc')
    $lines = New-Object System.Collections.Generic.List[string]
    $files = Get-ChildItem -LiteralPath $Root -Recurse -Force -File -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($Root.Length + 1)
        $top = $rel.Split([char]92)[0]
        if ($skipTop -contains $top) { continue }
        $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
        $lines.Add(("{0}  {1}" -f $h, $rel.Replace([char]92, '/')))
    }
    [System.IO.File]::WriteAllLines($Out, $lines, $enc)
    return $lines.Count
}

# ---------------------------------------------------------------- location
$stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$name   = if ($Label) { "{0}_{1}" -f $stamp, $Label } else { $stamp }
$dest   = Join-Path $BackupRoot $name
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Say ("backup target : {0}" -f $dest)

# ---------------------------------------------------------------- live facts
$head   = (& git -C $Worktree rev-parse --short HEAD)
$branch = (& git -C $Worktree rev-parse --abbrev-ref HEAD)
$status = (& git -C $Worktree status --porcelain)
$dirty  = if ($status) { 'DIRTY' } else { 'clean' }
Say ("revision      : {0} on {1} ({2})" -f $head, $branch, $dirty)

# Directories that are NOT source: regenerable build products and the
# downloaded toolchain. Excluded by default so a snapshot stays small and
# fast; pass -Full to archive absolutely everything.
$buildDirs = @('work', 'outflow', 'work_syn', 'work_pnr', 'work_dbg', 'ip', 'ooc')
$xd = @('.git')
if (-not $Full) { $xd += $buildDirs }
Say ("excluded dirs : {0}" -f ($(if ($Full) { '(none, full copy)' } else { $xd -join ', ' })))

# ---------------------------------------------------------------- copies
Say 'copying worktree ...'
[void](Copy-Tree -Src $Worktree -Dst (Join-Path $dest 'worktree') -Xd $xd)
Say 'copying teammate worktree ...'
[void](Copy-Tree -Src $TeamWorktree -Dst (Join-Path $dest 'worktree_team') -Xd $xd)
Say 'copying shared .git ...'
$gitCommon = (& git -C $Worktree rev-parse --git-common-dir).Trim()
if (-not [System.IO.Path]::IsPathRooted($gitCommon)) { $gitCommon = Join-Path $Worktree $gitCommon }
[void](Copy-Tree -Src $gitCommon -Dst (Join-Path $dest 'gitdir'))

# ---------------------------------------------------------------- bundle
Say 'writing git bundle ...'
$bundle = Join-Path $dest 'git_all.bundle'
& git -C $Worktree bundle create $bundle --all 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'git bundle failed' }
$global:LASTEXITCODE = 0
$bundleBytes = (Get-Item -LiteralPath $bundle).Length

# ---------------------------------------------------------------- status file
$nl = [string][char]13 + [string][char]10
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("snapshot      : $name")
[void]$sb.AppendLine("created       : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
[void]$sb.AppendLine("host          : $env:COMPUTERNAME  user=$env:USERNAME")
[void]$sb.AppendLine("worktree      : $Worktree")
[void]$sb.AppendLine("team worktree : $TeamWorktree")
[void]$sb.AppendLine("shared .git   : $gitCommon")
[void]$sb.AppendLine("branch        : $branch")
[void]$sb.AppendLine("HEAD          : $head")
[void]$sb.AppendLine("worktree state: $dirty")
[void]$sb.AppendLine("bundle bytes  : $bundleBytes")
[void]$sb.AppendLine("copy mode     : $(if ($Full) { 'FULL (build products included)' } else { 'SOURCE ONLY' })")
[void]$sb.AppendLine("excluded dirs : $(if ($Full) { '(none)' } else { $buildDirs -join ', ' })")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('--- git status --porcelain ---')
[void]$sb.AppendLine($(if ($status) { $status -join $nl } else { '(clean)' }))
[void]$sb.AppendLine('')
[void]$sb.AppendLine('--- git log -5 ---')
[void]$sb.AppendLine(((& git -C $Worktree log --oneline -5) -join $nl))
[void]$sb.AppendLine('')
[void]$sb.AppendLine('--- git worktree list ---')
[void]$sb.AppendLine(((& git -C $Worktree worktree list) -join $nl))
[void]$sb.AppendLine('')
[void]$sb.AppendLine('--- branches (-vv) ---')
[void]$sb.AppendLine(((& git -C $Worktree branch -vv) -join $nl))
[void]$sb.AppendLine('')
[void]$sb.AppendLine('--- remotes ---')
[void]$sb.AppendLine(((& git -C $Worktree remote -v) -join $nl))
foreach ($b in (& git -C $Worktree branch --format='%(refname:short)')) {
    $global:LASTEXITCODE = 0
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('--- branches with no upstream (never pushed) ---')
$unpublished = 0
foreach ($rec in (& git -C $Worktree for-each-ref --format='%(refname:short)|%(upstream:short)' refs/heads/)) {
    if ($rec -notmatch '\|') { continue }
    $parts = $rec -split '\|', 2
    if ([string]::IsNullOrWhiteSpace($parts[1])) {
        [void]$sb.AppendLine("  $($parts[0])")
        $unpublished++
    }
}
$global:LASTEXITCODE = 0
if ($unpublished -eq 0) { [void]$sb.AppendLine('  (none)') }
[void]$sb.AppendLine('')
[void]$sb.AppendLine('--- algorithm reference source (single source of truth) ---')
$refDir = Join-Path $Worktree 'sim\algo\model\ref\FPGA-Python-main'
if (Test-Path -LiteralPath $refDir) {
    foreach ($f in (Get-ChildItem -LiteralPath $refDir -Force -File | Sort-Object Name)) {
        [void]$sb.AppendLine(("  {0,-30} {1,9} B" -f $f.Name, $f.Length))
    }
} else {
    [void]$sb.AppendLine('  (absent)')
}
[System.IO.File]::WriteAllText((Join-Path $dest 'STATUS.txt'), $sb.ToString(), $enc)

# ---------------------------------------------------------------- restore note
$r = @(
 'HOW TO GET BACK TO THIS SNAPSHOT',
 '================================',
 '',
 'A) Fastest: overwrite the live worktree with these exact files.',
 '   (close editors first)',
 '',
 '     robocopy "<this folder>\worktree" "D:\FPGA_Project\imx219_pyrtl" /MIR /XD .git',
 '',
 '   The worktree .git is a 64 byte text file containing:',
 '     gitdir: D:/FPGA_Project/imx219_team/.git/worktrees/imx219_pyrtl',
 '   Copy it back as well if it was lost. The whole git object store lives in',
 '   <this folder>\gitdir and can replace D:\FPGA_Project\imx219_team\.git',
 '   verbatim (close every git client first).',
 '',
 'B) Or rebuild from the bundle, leaving the current repository untouched:',
 '',
 '     git clone "<this folder>\git_all.bundle" D:\FPGA_Project\recover_check',
 '     git -C D:\FPGA_Project\recover_check log --oneline --all',
 '',
 'C) Or restore one single file:',
 '',
 '     copy "<this folder>\worktree\rtl\algo\alg_top.v" ^',
 '          "D:\FPGA_Project\imx219_pyrtl\rtl\algo\alg_top.v"',
 '',
 'D) Verify byte identity before trusting a restored file:',
 '',
 '     Get-FileHash -Algorithm SHA256 <file>',
 '',
 '   and compare against MANIFEST.sha256 (paths are relative to worktree\).',
 '',
 'E) Diff this snapshot against the live tree without restoring anything:',
 '',
 '     git -C D:\FPGA_Project\imx219_pyrtl --work-tree=<this folder>\worktree diff',
 '',
 'F) What is deliberately missing from worktree\ and worktree_team\ in a',
 '   default snapshot (regenerable, not source):',
 '',
 '     work\       oss-cad-suite + iverilog toolchain, about 880 MB,',
 '                 re-downloadable; relocated by ALG_OSS_BIN.',
 '     outflow\    Efinity build products; rerun the build to recreate them.',
 '     work_syn\ work_pnr\ work_dbg\ ip\ ooc\   same category.',
 '',
 '   The .git copy next to this file (gitdir\) plus git_all.bundle still',
 '   contain every committed bitstream and every source revision, so nothing',
 '   tracked by git is lost. Use -Full to snapshot the excluded dirs too.',
 '',
 'G) KNOWN GOTCHA -- prefer path A (the file copy) over path B (the clone).',
 '   .gitattributes marks *.v *.xml *.sdc *.md as "text", so a fresh git',
 '   checkout rewrites LF to CRLF on this machine. A clone therefore gives',
 '   source files that are content-identical but byte-different from the live',
 '   worktree (measured: alg_top.v 11101 B CRLF from clone vs 10862 B LF',
 '   live). The worktree\ copy here is the byte-exact one; MANIFEST.sha256',
 '   was computed from it and is the authority. *.bit is marked binary and',
 '   is never rewritten, so bitstreams survive either path unchanged.',
 ''
)
[System.IO.File]::WriteAllText((Join-Path $dest 'RESTORE.txt'), ($r -join $nl), $enc)

# ---------------------------------------------------------------- manifest
Say 'hashing files ...'
$n = Write-Manifest -Root (Join-Path $dest 'worktree') -Out (Join-Path $dest 'MANIFEST.sha256')

# ---------------------------------------------------------------- report
$bytes = (Get-ChildItem -LiteralPath $dest -Recurse -Force -File -ErrorAction SilentlyContinue |
          Measure-Object Length -Sum).Sum
Say ("files hashed  : {0}" -f $n)
Say ("snapshot size : {0:N1} MB" -f ($bytes / 1MB))

$idx = Join-Path $BackupRoot 'INDEX.txt'
if (-not (Test-Path -LiteralPath $idx)) {
    [System.IO.File]::WriteAllText($idx, ("stamp          name                                      branch                 head" + $nl), $enc)
}
$line = ('{0}  {1,-40}  {2,-22}  {3}' -f $stamp, $name, $branch, $head)
[System.IO.File]::AppendAllText($idx, ($line + $nl), $enc)

# ---------------------------------------------------------------- optional prune
if ($KeepN -gt 0) {
    $resolvedRoot = (Resolve-Path -LiteralPath $BackupRoot).Path.TrimEnd([char]92)
    $today = $stamp.Substring(0, 8)
    $all = Get-ChildItem -LiteralPath $resolvedRoot -Directory -Force |
           Where-Object { $_.Name -match '^\d{8}_\d{6}' -and $_.Name.StartsWith($today) } |
           Sort-Object Name
    $drop = $all | Select-Object -First ([Math]::Max(0, $all.Count - $KeepN))
    foreach ($d in $drop) {
        $full = (Resolve-Path -LiteralPath $d.FullName).Path
        if (-not $full.StartsWith($resolvedRoot + [char]92, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "refusing to delete outside backup root: $full"
        }
        Say ("pruning       : {0}" -f $d.Name)
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}

Say ''
Say ("RESULT: OK  ->  {0}" -f $dest)
exit 0
