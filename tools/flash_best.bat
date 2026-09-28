@echo off
REM ---------------------------------------------------------------------------
REM Re-flash the current best bitstream.
REM   known_good\best_epf_guided_99540aa_20260928.bit
REM Close the tuning GUI first: it holds COM5 and the flash would fail.
REM JTAG programming is VOLATILE: the design is lost on power cycle.
REM ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0.."
call tools\flash_candidate.bat known_good\best_epf_guided_99540aa_20260928.bit
set RC=%ERRORLEVEL%
echo === flash_best exit code: %RC% ===
endlocal & exit /b %RC%