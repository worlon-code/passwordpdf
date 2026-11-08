$ip = "192.168.1.13"
$startPort = 30000
$endPort = 50000
$timeoutMs = 70

Write-Host "Scanning $ip for open wireless debugging ports ($startPort..$endPort)..."

$openPorts = [System.Collections.Concurrent.ConcurrentBag[int]]::new()
$ports = $startPort..$endPort

$tasks = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
$semaphore = [System.Threading.SemaphoreSlim]::new(300, 300)

foreach ($port in $ports) {
    $semaphore.Wait()
    $t = [System.Threading.Tasks.Task]::Run([Action]{
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($ip, $port, $null, $null)
            if ($iar.AsyncWaitHandle.WaitOne($timeoutMs)) {
                $client.EndConnect($iar)
                $openPorts.Add($port)
                Write-Host "Found open port: $port"
            }
            $client.Close()
        } catch {}
        finally {
            $semaphore.Release()
        }
    })
    $tasks.Add($t)
}

[System.Threading.Tasks.Task]::WaitAll($tasks.ToArray())

Write-Host "Open ports found:"
$openPorts | ForEach-Object { Write-Host " - $_" }
