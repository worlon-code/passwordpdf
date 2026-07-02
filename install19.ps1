$candidates = @(
  'C:\Users\omsai\AppData\Local\Android\Sdk\platform-tools\adb.exe'
)
$adb = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $adb) { $adb = (Get-Command adb -ErrorAction SilentlyContinue).Source }
if (-not $adb) { Write-Host 'RESULT: FAIL (adb not found)'; exit 1 }
Write-Host "Using adb: $adb"
$apk = @(
  'D:\Repos\passwordpdf\android\app\build\outputs\apk\debug\app-debug.apk',
  'D:\Repos\passwordpdf\android\app\build\outputs\flutter-apk\app-debug.apk'
) | Where-Object { Test-Path $_ } | Sort-Object { (Get-Item $_).LastWriteTime } -Descending | Select-Object -First 1
if (-not $apk) { Write-Host 'RESULT: FAIL (no app-debug.apk found)'; exit 1 }
Write-Host ("Installing NEWEST: {0}  (built {1})" -f $apk, (Get-Item $apk).LastWriteTime)
$out = & $adb install -r -d $apk | Out-String
Write-Host $out
if ($out -match 'Success') { Write-Host '=== RESULT: INSTALL SUCCESS (in-place, data kept) ==='; exit 0 }
Write-Host '=== RESULT: INSTALL FAILED ==='; exit 1