<#
  Live parameter sweep over the board UART.

  For every setting it sends the UART commands, waits for the change to reach
  the video path, then grabs one HDMI clip. Nothing here needs a person at the
  board pressing keys, and the clips land in work\capture\<label>\ so
  tools\analyze_sweep.py can score them.

  Usage (from the repo root):
      powershell -NoProfile -ExecutionPolicy Bypass -File tools\live_sweep.ps1 `
          -Port COM7 -Settings E0_T16,E1_T16,E2_T16,E2_T12,E2_T20

  A setting is "<cmd>_<cmd>", e.g. E2_T16 means "send E2 then T16".
#>
param(
  [string]$Port = "COM7",
  [int]$Device = 1,
  [int]$Seconds = 2,
  [int]$Stills = 3,
  [int]$SettleMs = 1500,
  [string[]]$Settings = @("E0_T16", "E1_T16", "E2_T16", "E2_T12", "E2_T20"),
  [string]$Reference = "E2_T16",
  [string]$OutRoot = "work\capture",
  [string]$Python = ""
)

$ErrorActionPreference = "Stop"
$tools = $PSScriptRoot
$root  = Split-Path -Parent $tools

# `powershell -File live_sweep.ps1 -Settings E2_T16,E1_T16` does not parse the
# comma: the whole "E2_T16,E1_T16" arrives as ONE array element, which would run
# every command in sequence and capture a single useless clip. Split here so the
# script works with both `-File` and `& script.ps1` invocation styles. (Same trap
# as tools\uart_send.ps1 - see docs\uart_remote_control.md.)
$Settings = @(
  foreach ($s in $Settings) {
    foreach ($part in ($s -split '[,\s]+')) { if ($part) { $part } }
  }
)
if ($Settings.Count -eq 0) { throw "no settings given" }

if (-not $Python) {
  $Python = "C:\Users\HUAWEI\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
}
if (-not (Test-Path $Python)) { throw "python not found: $Python" }
if (-not (Test-Path (Join-Path $root "rtl"))) { throw "run this from the repository, got root=$root" }

# The camera app holds the capture device exclusively.
Get-Process WindowsCamera -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 400

# Plan the run. The reference setting is captured both first and last: the
# camera's auto exposure drifts slowly, and in an earlier run the grey mean fell
# 13 % from the first clip to the last, which silently biased every comparison
# between clips captured at different times. Two reference clips measure that
# drift, so analyze_sweep.py can say whether a run is trustworthy at all.
# Flat "<label>||<setting>" strings: nesting arrays here silently stringifies
# them instead of keeping the pairs apart.
# The separator must be split as a regex: String.Split("||") takes a char[] and
# would therefore cut on every single '|', leaving an empty setting behind.
$SEP = '\|\|'
$plan = @()
if ($Reference) { $plan += "refa_" + $Reference.ToLower() + "||" + $Reference }
foreach ($s in $Settings) { $plan += "ab_" + $s.ToLower() + "||" + $s }
if ($Reference) { $plan += "refz_" + $Reference.ToLower() + "||" + $Reference }

foreach ($step in $plan) {
  $parts = $step -split $SEP
  $label = $parts[0]
  $s     = $parts[1]
  if (-not $s) { throw "empty setting in plan entry '$step'" }
  $cmds  = ($s -split "_") -join ","
  Write-Host "=== $s   (uart: $cmds)   -> $label"
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tools "uart_send.ps1") `
      -Commands $cmds -Port $Port -Seconds 1 | Out-Null
  Start-Sleep -Milliseconds $SettleMs
  $dest = Join-Path $root (Join-Path $OutRoot $label)
  & $Python (Join-Path $tools "capture_hdmi.py") --device $Device --width 1280 `
      --height 720 --seconds $Seconds --label $label --stills $Stills | Out-Null
  if (-not (Test-Path $dest)) { throw "capture did not land in $dest" }
  Write-Host "    wrote $dest"
}

Write-Host ""
Write-Host "now score them:"
$labels = ($plan | ForEach-Object { ($_ -split $SEP)[0] }) -join ","
Write-Host "  & `"$Python`" tools\analyze_sweep.py --root $OutRoot --labels $labels"
