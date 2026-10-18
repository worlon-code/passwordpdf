$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logPath = "D:\Repos\passwordpdf\logs\build_$timestamp.txt"
Write-Host "Starting debug build. Output logging to $logPath"
cmd.exe /c "cd /d D:\Repos\passwordpdf\android && gradlew.bat assembleDebug" 2>&1 | Out-File -FilePath $logPath -Encoding utf8
if ($LASTEXITCODE -eq 0) {
    Write-Host "BUILD SUCCESSFUL. Log saved to: $logPath"
    exit 0
} else {
    Write-Host "BUILD FAILED with exit code $LASTEXITCODE. Log saved to: $logPath"
    exit $LASTEXITCODE
}
