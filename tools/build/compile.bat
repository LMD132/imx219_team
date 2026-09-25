@echo off
REM Compile the Ti60F225 edge-detection project with Efinity.
REM Usage: compile.bat            (log -> work\compile.log)
setlocal
set ROOT=%~dp0..\..
pushd %ROOT%
call C:\Efinity\2026.1\bin\setup.bat >nul 2>&1
C:\Efinity\2026.1\python311\bin\python.exe C:\Efinity\2026.1\scripts\efx_run.py ti60f225_oob.xml --flow compile > work\compile.log 2>&1
echo --- flow result ---
findstr /C:" :	PASS" /C:" :	FAIL" /C:"ERROR" work\compile.log
popd
endlocal
