@echo off
REM Load a bitstream over JTAG. This is volatile: a power cycle brings back
REM whatever is in the configuration Flash, and nothing here writes the Flash.
REM Usage: program.bat [bitfile]     default outflow\ti60f225_oob.bit
setlocal
set ROOT=%~dp0..\..
set BIT=%~1
if "%BIT%"=="" set BIT=%ROOT%\outflow\ti60f225_oob.bit
call C:\Efinity\2026.1\bin\setup.bat >nul 2>&1
call C:\Efinity\2026.1\pgm\bin\ftdi_pgm.bat "%BIT%" -m jtag -b "Generic Board Profile Using FT4232H" --jtag_clock_freq 6000000
endlocal
