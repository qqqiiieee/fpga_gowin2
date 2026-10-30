@echo off
setlocal
rem All compiler discovery and execution is shared with the portable runner.
python "%~dp0run_native.py" %*
exit /b %errorlevel%
