@echo off
REM ---------------------------------------------------------------------------
REM Compile this worktree with Efinity (full flow: map -> place -> route -> pgm).
REM Writes every log into outflow\ ; the bitstream lands at outflow\ti60f225_oob.bit.
REM
REM WHY THIS SCRIPT EXISTS:
REM   efx_run.bat assumes setup.bat has run. This machine has a *user-level*
REM   EFINITY_HOME, so Efinity's own setup is skipped and the bundled Python dies
REM   with "init_fs_encoding ... No module named 'encodings'". Calling setup.bat
REM   explicitly first avoids that. EFINITY_USER_DIR must also be set because the
REM   board-profile loader reads it directly.
REM
REM Keep this file ASCII-only: cmd.exe parses .bat as OEM codepage (GBK here),
REM and non-ASCII comments come back as "not recognized as a command".
REM
REM Usage:  tools\compile.bat
REM ---------------------------------------------------------------------------

setlocal
call C:\Efinity\2026.1\bin\setup.bat
if not defined EFINITY_USER_DIR set "EFINITY_USER_DIR=%USERPROFILE%\.efinity"

cd /d "%~dp0.."
if not exist outflow mkdir outflow

echo === compiling ti60f225_oob.xml (log: outflow\compile.log) ===
C:\Efinity\2026.1\bin\efx_run.bat ti60f225_oob.xml --flow compile > outflow\compile.log 2>&1
set RC=%ERRORLEVEL%
echo DONE_RC=%RC% >> outflow\compile.log
echo === efx_run exit code: %RC% ===
echo === report:  outflow\ti60f225_oob.timing.rpt  /  outflow\ti60f225_oob.hier_util.rpt ===
endlocal & exit /b %RC%
