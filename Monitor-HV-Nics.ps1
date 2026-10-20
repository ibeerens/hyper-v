$prev = @{}; Get-NetAdapterStatistics | ForEach-Object { $prev[$_.Name] = $_ }
while ($true) {
    Start-Sleep -Seconds 1
    $now = Get-NetAdapterStatistics
    Clear-Host
    $now | ForEach-Object {
        $p = $prev[$_.Name]
        [pscustomobject]@{
            Adapter     = $_.Name
            'Send MB/s' = [math]::Round(($_.SentBytes - $p.SentBytes) / 1MB, 1)
            'Recv MB/s' = [math]::Round(($_.ReceivedBytes - $p.ReceivedBytes) / 1MB, 1)
        }
    } | Sort-Object 'Send MB/s', 'Recv MB/s' -Descending | Format-Table -AutoSize
    $now | ForEach-Object { $prev[$_.Name] = $_ }
}