# Fast Debug Build, Push, and Install script for PasswordPDF
# Uses arm64 targeting and push+pm install for lightning-fast deployment (~10-15s total install time)
param(
    [switch]$SkipBuild
)

$root = $PSScriptRoot
Set-Location $root

# 1. Setup Log File
$logDir = Join-Path $root 'logs'
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir | Out-Null
}
$timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$log = Join-Path $logDir "build_$timestamp.txt"

function Write-Step {
    param([string]$Message)
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts] $Message"
    Write-Host $line
    $line | Out-File -FilePath $log -Append -Encoding utf8
}

Write-Step "=== FAST DEBUG DEPLOYMENT SCRIPT ==="
Write-Step "Log: $log"

# 2. Locate ADB
$adb = "adb"
$adbCmd = Get-Command adb -ErrorAction SilentlyContinue
if (-not $adbCmd) {
    $fallbackAdb = Join-Path $env:LOCALAPPDATA "Android\Sdk\platform-tools\adb.exe"
    if (Test-Path $fallbackAdb) {
        $adb = $fallbackAdb
    } else {
        Write-Step "ERROR: ADB not found in PATH or Android SDK."
        exit 1
    }
}
Write-Step "ADB: $adb"

# 3. Check Connected ADB Device
$devices = & $adb devices 2>&1
Write-Step "Connected Devices:`n$devices"
if ($devices -match "unauthorized") {
    Write-Step "WARNING: Device is UNAUTHORIZED! Please unlock your phone and tap 'Allow USB debugging'."
}

# 4. Build APK (optional if -SkipBuild specified)
$apk = Join-Path $root 'android\app\build\outputs\apk\debug\app-debug.apk'

if (-not $SkipBuild) {
    Write-Step "Building debug APK (arm64-v8a)..."
    $buildWatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    # Run gradle build targeting arm64 only
    Push-Location (Join-Path $root 'android')
    & .\gradlew.bat assembleDebug -Ptarget-platform=android-arm64 2>&1 | Out-File -FilePath $log -Append -Encoding utf8
    $buildCode = $LASTEXITCODE
    Pop-Location
    $buildWatch.Stop()

    if ($buildCode -ne 0) {
        Write-Step "ERROR: Build failed with exit code $buildCode"
        exit $buildCode
    }
    Write-Step "Build successful in $([math]::Round($buildWatch.Elapsed.TotalSeconds, 1))s"
} else {
    Write-Step "Skipping build as requested, using existing APK."
}

if (-not (Test-Path $apk)) {
    Write-Step "ERROR: APK not found at $apk"
    exit 1
}

$apkSizeMb = [math]::Round((Get-Item $apk).Length / 1MB, 2)
Write-Step "APK: $apk ($apkSizeMb MB)"

# 5. Fast Push to Device
Write-Step "Pushing APK to device /data/local/tmp/app-debug.apk..."
$pushWatch = [System.Diagnostics.Stopwatch]::StartNew()
$pushResult = & $adb push $apk /data/local/tmp/app-debug.apk 2>&1
$pushWatch.Stop()
Write-Step "Push output: $pushResult ($([math]::Round($pushWatch.Elapsed.TotalSeconds, 1))s)"

# 6. Fast PM Install on Device
Write-Step "Installing pushed APK via pm install..."
$installWatch = [System.Diagnostics.Stopwatch]::StartNew()
$installResult = & $adb shell pm install -r -d /data/local/tmp/app-debug.apk 2>&1
$installWatch.Stop()
Write-Step "Install output: $installResult ($([math]::Round($installWatch.Elapsed.TotalSeconds, 1))s)"

# Clean up temp apk on phone
& $adb shell rm -f /data/local/tmp/app-debug.apk 2>&1 | Out-Null

if ($installResult -notmatch "Success") {
    Write-Step "ERROR: Installation did not succeed: $installResult"
    exit 1
}

# 7. Grant All Files Access Permission
Write-Step "Ensuring MANAGE_EXTERNAL_STORAGE permission..."
& $adb shell appops set com.passwordpdf.passwordpdf_manager MANAGE_EXTERNAL_STORAGE allow 2>&1 | Out-Null

# 8. Launch App on Phone
Write-Step "Launching app on device..."
$launchResult = & $adb shell am start -n com.passwordpdf.passwordpdf_manager/.MainActivity 2>&1
Write-Step "Launch output: $launchResult"

Write-Step "=== DEPLOYMENT COMPLETE: App running on phone ==="
