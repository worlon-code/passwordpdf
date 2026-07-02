$f = 'D:\Repos\passwordpdf\lib\services\password_backup_service.dart'
$c = [System.IO.File]::ReadAllText($f)
$c = $c -replace 'MapEntry\([^)]*\)', 'MapEntry(k.toString(), v.toString())'
[System.IO.File]::WriteAllText($f, $c)
Write-Host 'DONE'
