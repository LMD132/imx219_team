# board_probe.ps1
#
# Is the Ti60F225 board actually attached? program.bat answers every failure
# with the same "ERROR: No USB target detected, aborting!", which is also the
# message for an unpowered board and for a charge-only cable. This enumerates
# what the host sees so those cases can be told apart before retrying anything.
#
# Exit code 0 = FT4232H present, JTAG programming and UART should work.
# Exit code 1 = no FTDI device on USB, i.e. the board is not reachable.
#
# Usage:
#     powershell -ExecutionPolicy Bypass -File tools\board_probe.ps1

$ErrorActionPreference = 'Continue'

$usb    = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -like 'USB\VID_*' })
$ftdi   = @($usb | Where-Object { $_.InstanceId -like 'USB\VID_0403*' })
$serial = @(Get-PnpDevice -PresentOnly -Class Ports -ErrorAction SilentlyContinue |
            Where-Object { $_.InstanceId -like 'FTDIBUS*' })

Write-Host ("USB devices present : " + $usb.Count)
foreach ($d in $usb) { Write-Host ("    " + $d.FriendlyName + "   [" + $d.InstanceId + "]") }

Write-Host ("FTDI (VID_0403)     : " + $ftdi.Count)
foreach ($d in $ftdi) { Write-Host ("    " + $d.FriendlyName) }

if ($serial.Count -eq 0) {
    Write-Host "FTDI serial ports   : (none)"
} else {
    Write-Host ("FTDI serial ports   : " + (($serial | ForEach-Object { $_.FriendlyName }) -join ', '))
}

if ($ftdi.Count -eq 0) {
    Write-Host ""
    Write-Host "RESULT: board NOT seen by the host. Check, in this order:"
    Write-Host "  1. board powered (D7 LED lit)"
    Write-Host "  2. USB cable in the board JTAG/UART socket, both ends seated"
    Write-Host "  3. a data cable - a charge-only cable never enumerates"
    Write-Host "  4. replug, wait for the COM port, then run this again"
    exit 1
}

Write-Host ""
Write-Host "RESULT: FT4232H present. JTAG programming and UART telemetry should work;"
Write-Host "        the board UART is the COM port listed above."
exit 0
