@echo off
REM ---------------------------------------------------------------------------
REM Flash a candidate bitstream to the Ti60F225 board over JTAG (volatile).
REM
REM Usage:  tools\flash_candidate.bat <path-to-bitstream>
REM Example:
REM   tools\flash_candidate.bat candidate_bitstreams\algo_canny_full_20260926_1954.bit
REM
REM WHY THIS SCRIPT EXISTS (a real gotcha on this machine):
REM   ftdi_pgm.bat starts with:  if not defined EFINITY_HOME ( call setup.bat )
REM   This machine has a *user-level* EFINITY_HOME variable, so ftdi_pgm.bat
REM   skips setup.bat -> PYTHONHOME is never set -> the bundled Python dies with
REM   "Fatal Python error: init_fs_encoding ... ModuleNotFoundError: No module
REM   named 'encodings'". Calling setup.bat explicitly first avoids that.
REM
REM   EFINITY_USER_DIR must also be set; setup.bat only sets EFINITY_USER_DIR_INI,
REM   and the efx_pgm board-profile loader reads EFINITY_USER_DIR directly.
REM
REM Keep this file ASCII-only: cmd.exe parses .bat as OEM codepage (GBK here),
REM and non-ASCII comments come back as "not recognized as a command".
REM
REM JTAG programming is VOLATILE: the design is lost on power cycle, and
REM pressing CRESET_N may reload whatever is in Flash. Re-flash after power-up.
REM Do NOT run this against Flash (no -m flash) unless the board holder asks.
REM ---------------------------------------------------------------------------

setlocal
set "BIT=%~1"
if "%BIT%"=="" (
  echo usage: %~nx0 ^<bitstream^>
  exit /b 2
)
if not exist "%BIT%" (
  echo ERROR: bitstream not found: %BIT%
  exit /b 3
)

call C:\Efinity\2026.1\bin\setup.bat
if not defined EFINITY_USER_DIR set "EFINITY_USER_DIR=%USERPROFILE%\.efinity"

echo === flashing: %BIT% ===
echo === board profile: Generic Board Profile Using FT4232H, JTAG @ 6 MHz ===
C:\Efinity\2026.1\pgm\bin\ftdi_pgm.bat "%BIT%" -m jtag -b "Generic Board Profile Using FT4232H" --jtag_clock_freq 6000000
set RC=%ERRORLEVEL%
echo === ftdi_pgm exit code: %RC% ===
echo === success looks like: "... finished with JTAG programming" ===
endlocal & exit /b %RC%
