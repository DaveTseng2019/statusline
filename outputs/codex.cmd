@echo off
REM Shim for the Codex desktop app CLI. The bin folder is hash-named and
REM changes on every update, so resolve the newest one that has codex.exe.
REM The exe is launched on the last line so its exit code becomes ours.
set "CODEXBIN=%LOCALAPPDATA%\OpenAI\Codex\bin"
set "CODEXEXE="
for /f "delims=" %%d in ('dir /b /a:d /o-d "%CODEXBIN%" 2^>nul') do (
  if not defined CODEXEXE if exist "%CODEXBIN%\%%d\codex.exe" set "CODEXEXE=%CODEXBIN%\%%d\codex.exe"
)
if not defined CODEXEXE (
  echo codex.exe not found under %CODEXBIN% 1>&2
  exit /b 1
)
"%CODEXEXE%" %*
