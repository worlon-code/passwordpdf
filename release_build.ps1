$root = 'D:\Repos\passwordpdf'
$logDir = Join-Path $root 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$log = Join-Path $logDir ('release_{0}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Set-Location $root
Write-Host "Building assembleRelease (output -> $log); please wait ~2-4 min ..."
Push-Location (Join-Path $root 'android')
cmd /c ".\gradlew.bat --stop"; cmd /c ".\gradlew.bat clean"
Remove-Item -Recurse -Force (Join-Path $root 'android\app\build') -ErrorAction SilentlyContinue
cmd /c ".\gradlew.bat assembleRelease > $log 2>&1"
$code = $LASTEXITCODE
Pop-Location
$apk = Join-Path $root 'android\app\build\outputs\apk\release\app-release.apk'
if (-not (Test-Path $apk)) { $apk = Join-Path $root 'android\app\build\outputs\flutter-apk\app-release.apk' }
if ($code -eq 0 -and (Test-Path $apk)) {
  Write-Host '=== RESULT: RELEASE BUILD SUCCESSFUL ==='
  $sha = (Get-FileHash -Algorithm SHA256 $apk).Hash.ToLower()
  Write-Host "APK: $apk"
  Write-Host ("SIZE: {0} bytes" -f (Get-Item $apk).Length)
  Write-Host "SHA256: $sha"
} else {
  Write-Host ('=== RESULT: RELEASE BUILD FAILED (exit {0}) ===' -f $code)
  Get-Content $log -Tail 25
}
Write-Host "LOG: $log"
