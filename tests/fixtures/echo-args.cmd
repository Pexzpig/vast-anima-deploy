@echo off
:loop
if "%~1"=="" goto done
echo ARG=[%~1]
shift
goto loop
:done
exit /b 0
