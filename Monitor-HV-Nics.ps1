$refreshSeconds = 0
do {
    $inputValue = Read-Host 'How many seconds between NIC statistics refreshes?'
    $validInput = [int]::TryParse($inputValue, [ref]$refreshSeconds) -and $refreshSeconds -gt 0
    if (-not $validInput) {
        Write-Warning 'Enter a positive whole number of seconds.'
    }
} while (-not $validInput)

$prev = @{}; Get-NetAdapterStatistics | ForEach-Object { $prev[$_.Name] = $_ }
while ($true) {
    Start-Sleep -Seconds $refreshSeconds
    $now = Get-NetAdapterStatistics
    Clear-Host
    $now | ForEach-Object {
        $p = $prev[$_.Name]
        [pscustomobject]@{
            Adapter     = $_.Name
            'Send MB/s' = [math]::Round(($_.SentBytes - $p.SentBytes) / 1MB / $refreshSeconds, 1)
            'Recv MB/s' = [math]::Round(($_.ReceivedBytes - $p.ReceivedBytes) / 1MB / $refreshSeconds, 1)
        }
    } | Sort-Object 'Send MB/s', 'Recv MB/s' -Descending | Format-Table -AutoSize
    $now | ForEach-Object { $prev[$_.Name] = $_ }
}