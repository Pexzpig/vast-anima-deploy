@echo off
if "%~1"=="show" if "%~2"=="user" (
  echo {^"id^":123,^"email^":^"tester@example.com^",^"ssh_key^":^"ssh-ed25519 AAAATESTKEY fixture^"}
  exit /b 0
)
if "%~1"=="show" if "%~2"=="ssh-keys" (
  echo [{^"id^":1,^"public_key^":^"ssh-ed25519 AAAATESTKEY fixture^"}]
  exit /b 0
)
exit /b 2
