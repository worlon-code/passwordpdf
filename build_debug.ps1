$ErrorActionPreference = 'Continue'
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$log = Join-Path $logDir ("build_" + $ts + ".txt")
Set-Location (Join-Path $PSScriptRoot 'android')
cmd /c "gradlew.bat assembleDebug" 2>&1 | Out-File -FilePath $log -Encoding utf8
Write-Host "LOG: $log"; Get-Content $log -Tail 25
