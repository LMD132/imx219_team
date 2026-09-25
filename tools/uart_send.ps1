<#
  Send one remote-control line to the board UART and print the reply.

  The board accepts, terminated by LF (see rtl/uart_cmd.v):
      T<nnn>  threshold floor 0..255        S<n>  adaptive weight 0..8
      D<n>    despeckle neighbours 0..5     E<n>  denoise stages 0..2
      K       hand control back to the keys
  Separators such as '=' or a space are ignored, so "T=16" and "T16" are the
  same. Example:  uart_send.ps1 -Commands T16,E2 -Port COM5
#>
param(
  [Parameter(Mandatory = $true)][string[]]$Commands,
  [string]$Port = "COM5",
  [int]$Baud = 115200,
  [int]$Seconds = 2
)

# `powershell -File script.ps1 -Commands T16,E2` does not parse the comma: the
# whole "T16,E2" arrives as ONE array element. Split on commas/whitespace here
# so the script works with both `-File` and `& script.ps1` invocation styles.
# (The board accumulates every digit in a line and clamps at 255, so sending
# "T16,S2,D5,E0" as a single line would silently become THR=255.)
$lines = @(
  foreach ($c in $Commands) {
    foreach ($part in ($c -split '[,\s]+')) { if ($part) { $part } }
  }
)

$sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 'One'
$sp.ReadTimeout = 200
$sp.NewLine = "`n"
try {
  $sp.Open()
  foreach ($c in $lines) {
    Write-Host "[send] $c"
    $sp.Write("$c`n")
    Start-Sleep -Milliseconds 120
  }
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    try { $line = $sp.ReadLine().Trim() } catch { continue }
    if ($line) { Write-Host "[recv] $line" }
  }
} finally {
  if ($sp.IsOpen) { $sp.Close() }
}

