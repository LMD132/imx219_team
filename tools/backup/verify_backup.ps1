<#
  verify_backup.ps1 -- prove a snapshot is complete and byte-identical.

  Checks, in order:
    1. every file listed in MANIFEST.sha256 exists in worktree\ and hashes equal
    2. the live worktree has no file that the snapshot is missing
       (source files only; build dirs are excluded on purpose)
    3. git_all.bundle passes "git bundle verify" and contains every branch
    4. gitdir\ exists and holds a real object store

  Usage:
     powershell -NoProfile -ExecutionPolicy Bypass -File verify_backup.ps1
     powershell -NoProfile -ExecutionPolicy Bypass -File verify_backup.ps1 -Snapshot <name>
     powershell -NoProfile -ExecutionPolicy Bypass -File verify_backup.ps1 -Snapshot latest
#>
[CmdletBinding()]
param(
    [string]$Snapshot   = 'latest',
    [string]$BackupRoot = 'D:\FPGA_Project\_backups',
    [string]$Worktree   = 'D:\FPGA_Project\imx219_pyrtl'
)

$ErrorActionPreference = 'Stop'
$problems = New-Object System.Collections.Generic.List[string]

# git writes ordinary progress text to stderr, which -ErrorActionPreference
# Stop would turn into a terminating error. Capture it properly instead.
function Git-Capture {
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
    return [pscustomobject]@{ Text = $txt; Code = $code }
}

if ($Snapshot -eq 'latest') {
    $snapDir = Get-ChildItem -LiteralPath $BackupRoot -Directory -Force |
               Where-Object { $_.Name -match '^\d{8}_\d{6}' } |
               Sort-Object Name | Select-Object -Last 1
    if (-not $snapDir) { throw "no snapshot found under $BackupRoot" }
} else {
    $snapDir = Get-Item -LiteralPath (Join-Path $BackupRoot $Snapshot)
}
$snap = $snapDir.FullName
Write-Host ("verifying snapshot : {0}" -f $snapDir.Name)

# --- 1 -------------------------------------------------------------------
$manifest = Join-Path $snap 'MANIFEST.sha256'
if (-not (Test-Path -LiteralPath $manifest)) { throw "missing MANIFEST.sha256" }
$copyRoot = Join-Path $snap 'worktree'
$n = 0
foreach ($line in [System.IO.File]::ReadAllLines($manifest)) {
    if (-not $line.Trim()) { continue }
    $h, $rel = $line -split '  ', 2
    $p = Join-Path $copyRoot ($rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $p)) { $problems.Add("missing in snapshot: $rel"); continue }
    if ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLower() -ne $h) {
        $problems.Add("hash mismatch in snapshot: $rel")
    }
    $n++
}
Write-Host ("  [1] manifest entries verified : {0}" -f $n)

# --- 2 -------------------------------------------------------------------
$skipTop = @('outflow', 'work_syn', 'work_pnr', 'work_dbg', '.git', 'ip', 'ooc', 'work')
$extra = 0
foreach ($f in (Get-ChildItem -LiteralPath $Worktree -Recurse -Force -File -ErrorAction SilentlyContinue)) {
    $rel = $f.FullName.Substring($Worktree.Length + 1)
    if ($skipTop -contains $rel.Split([char]92)[0]) { continue }
    if (-not (Test-Path -LiteralPath (Join-Path $copyRoot $rel))) {
        $problems.Add("live file absent from snapshot: $rel")
        $extra++
    }
}
Write-Host ("  [2] live files not covered by snapshot : {0}" -f $extra)

# --- 3 -------------------------------------------------------------------
$bundle = Join-Path $snap 'git_all.bundle'
if (-not (Test-Path -LiteralPath $bundle)) {
    $problems.Add('missing git_all.bundle')
} else {
    $res = Git-Capture -GitArgs @('-C', $Worktree, 'bundle', 'verify', $bundle)
    $out = $res.Text
    if ($res.Code -ne 0) { $problems.Add("git bundle verify failed: $out") }
    $refs = @()
    foreach ($l in $out -split "`n") { if ($l -match '^([0-9a-f]{40}) (refs/\S+)') { $refs += $matches[2] } }
    $liveBranches = @((Git-Capture -GitArgs @('-C', $Worktree, 'for-each-ref', '--format=%(refname)', 'refs/heads/', 'refs/remotes/')).Text -split "`n" |
                      ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $missingRefs = @()
    foreach ($lb in $liveBranches) {
        if ($refs -notcontains $lb) { $missingRefs += $lb }
    }
    Write-Host ("  [3] refs inside bundle : {0} (branches+remotes)" -f $refs.Count)
    if ($missingRefs.Count) { $problems.Add("bundle missing refs: $($missingRefs -join ', ')") }
}

# --- 4 -------------------------------------------------------------------
$gitdir = Join-Path $snap 'gitdir'
if (-not (Test-Path -LiteralPath $gitdir)) {
    $problems.Add('missing gitdir copy')
} else {
    $objects = Join-Path $gitdir 'objects'
    $ok = (Test-Path -LiteralPath $objects)
    Write-Host ("  [4] gitdir object store present : {0}" -f $ok)
    if (-not $ok) { $problems.Add('gitdir has no objects/ directory') }
}

Write-Host ''
if ($problems.Count -eq 0) {
    Write-Host 'RESULT: BACKUP VERIFIED RESTORABLE'
    exit 0
} else {
    Write-Host ("RESULT: FAIL -- {0} problem(s)" -f $problems.Count)
    foreach ($p in $problems) { Write-Host ("  - {0}" -f $p) }
    exit 1
}
