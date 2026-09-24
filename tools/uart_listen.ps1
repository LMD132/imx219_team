# uart_listen.ps1
#
# Listen on one or more host COM ports at once and print whatever the board
# sends, so FPGA state can be observed as text instead of by photographing the
# panel. Uses System.IO.Ports only, so it needs nothing installed.
#
# Typical use (which FT4232H channel is the board UART?):
#     .\tools\uart_listen.ps1 -Ports COM5,COM6 -Seconds 8
#
# Add -Hex to also dump raw bytes, which is how a wrong baud rate shows up
# (the ASCII column looks fine but the byte pattern does not decode).

param(
    # Comma separated list, e.g. -Ports COM5,COM6. Accepts either an array or
    # one pre-joined string, because `powershell -File` binds the two forms
    # differently.
    [string[]] $Ports   = @('COM5', 'COM6'),
    [int]      $Baud    = 115200,
    [int]      $Seconds = 8,
    [switch]   $Hex
)

$ErrorActionPreference = 'Continue'
$Ports    = @($Ports | ForEach-Object { $_ -split '[,;\s]+' } |
                ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
$deadline = (Get-Date).AddSeconds($Seconds)
$rx       = @{}
$buffers  = @{}
$raw      = @{}
$opened   = @()

foreach ($p in $Ports) {
    $rx[$p]      = New-Object System.Text.StringBuilder
    $buffers[$p] = New-Object System.Text.StringBuilder
    $raw[$p]     = New-Object System.Collections.Generic.List[byte]
    try {
        $sp = New-Object System.IO.Ports.SerialPort $p, $Baud, 'None', 8, 'One'
        $sp.ReadTimeout  = 50
        $sp.WriteTimeout = 50
        $sp.Open()
        $sp.DiscardInBuffer()
        $rx[$p] = $sp
        $opened += $p
        Write-Host ("[open ] {0} @ {1} 8N1" -f $p, $Baud)
    } catch {
        Write-Host ("[fail ] {0} : {1}" -f $p, $_.Exception.Message)
    }
}

if ($opened.Count -eq 0) { Write-Host '[done ] no port could be opened'; exit 1 }

while ((Get-Date) -lt $deadline) {
    $any = $false
    foreach ($p in $opened) {
        $sp = $rx[$p]
        $n  = $sp.BytesToRead
        if ($n -le 0) { continue }
        $any = $true

        $bytes = New-Object byte[] $n
        [void] $sp.Read($bytes, 0, $n)

        foreach ($b in $bytes) { [void] $raw[$p].Add($b) }
        [void] $buffers[$p].Append([System.Text.Encoding]::ASCII.GetString($bytes))

        # Emit any complete lines immediately.
        while ($true) {
            $text = $buffers[$p].ToString()
            $idx  = $text.IndexOf("`n")
            if ($idx -lt 0) { break }
            $line = $text.Substring(0, $idx).TrimEnd("`r")
            [void] $buffers[$p].Remove(0, $idx + 1)
            Write-Host ("[{0}] {1}" -f $p, $line)
        }
    }
    if (-not $any) { Start-Sleep -Milliseconds 15 }
}

# Flush whatever arrived without a trailing newline.
foreach ($p in $opened) {
    $tail = $buffers[$p].ToString().Trim()
    if ($tail.Length -gt 0) { Write-Host ("[{0}] {1} (no newline)" -f $p, $tail) }
}

Write-Host ''
Write-Host '================ summary ================'
foreach ($p in $opened) {
    $bytes = $raw[$p]
    Write-Host ("{0}: {1} bytes" -f $p, $bytes.Count)
    if ($Hex -and $bytes.Count -gt 0) {
        # Note: do not name this $hex, the -Hex switch already owns that name.
        $shown   = [Math]::Min($bytes.Count, 64)
        $hexDump = @()
        for ($i = 0; $i -lt $shown; $i++) { $hexDump += ('{0:X2}' -f $bytes[$i]) }
        $more = ''
        if ($bytes.Count -gt $shown) { $more = ' ...' }
        Write-Host ("{0}: {1}{2}" -f $p, ($hexDump -join ' '), $more)
    }
    try { $rx[$p].Close() } catch { }
}
