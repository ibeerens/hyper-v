<#
.SYNOPSIS
    Collects Hyper-V live migration configuration, events and network test results from a Hyper-V failover cluster.

.DESCRIPTION
    Run this from a management VM. The script is read-only: it does not change any configuration on the hosts.
    The only thing written on the hosts is a temporary cluster log in $env:TEMP, which is removed afterwards.

    Collected per node:
      - Live migration settings (performance option, authentication, max migrations)
      - Cluster networks and which ones live migration may use (exclude list / order)
      - Physical and virtual NICs (driver version, link speed, jumbo packet)
      - Hyper-V switches / SET teams
      - SMB bandwidth limit and active SMB multichannel connections
      - Microsoft Defender exclusions vs. Hyper-V recommended exclusions
      - Hyper-V / Failover Clustering events (errors, warnings and everything mentioning migration)
      - Cluster log lines mentioning migration
      - Network tests between nodes on live migration networks (ping, jumbo ping 8972, TCP 6600)

    Requirements:
      - PowerShell remoting (WinRM) from the management VM to every Hyper-V node
      - An account with local administrator rights on the nodes

.EXAMPLE
    .\Get-LiveMigrationReport.ps1 -ClusterName NK-HVC-01 -StartTime '2026-10-19 15:00' -EndTime '2026-10-19 17:00'

.EXAMPLE
    .\Get-LiveMigrationReport.ps1 -ComputerName NK-HV-01-FL, NK-HV-02-FL, NK-HV-03-FL -Credential (Get-Credential)
#>
[CmdletBinding(DefaultParameterSetName = 'Cluster')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Cluster')]
    [string]$ClusterName,

    [Parameter(Mandatory, ParameterSetName = 'Nodes')]
    [string[]]$ComputerName,

    [datetime]$StartTime = (Get-Date).AddHours(-24),

    [datetime]$EndTime = (Get-Date),

    [string]$OutputPath = (Join-Path (Get-Location) ('LM-Report-{0:yyyyMMdd-HHmm}' -f (Get-Date))),

    [pscredential]$Credential,

    [switch]$SkipClusterLog,

    [switch]$SkipNetworkTests
)

$ErrorActionPreference = 'Continue'
$credParam = @{}
if ($Credential) { $credParam.Credential = $Credential }

#region Helpers

function Write-Step {
    param([string]$Text)
    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}

function Invoke-Section {
    param([string]$Name, [scriptblock]$Action)
    Write-Step $Name
    try {
        & $Action
    }
    catch {
        Write-Warning "$Name failed: $($_.Exception.Message)"
    }
}

# Strips the remoting properties and writes the data to <OutputPath>\<Name>.csv
function Save-Csv {
    param($Data, [string]$Name)
    $clean = @($Data | Where-Object { $_ } |
        Select-Object * -ExcludeProperty PSComputerName, RunspaceId, PSShowComputerName)
    if ($clean.Count -gt 0) {
        $clean | Export-Csv -Path (Join-Path $OutputPath "$Name.csv") -NoTypeInformation -Encoding UTF8
    }
    $clean
}

#endregion

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
Start-Transcript -Path (Join-Path $OutputPath 'console.txt') | Out-Null

Write-Host "Time window : $StartTime - $EndTime"
Write-Host "Output      : $OutputPath"

#region Nodes and sessions

Write-Step 'Discovering nodes'
if ($PSCmdlet.ParameterSetName -eq 'Cluster') {
    if (-not $Credential -and (Get-Module -ListAvailable -Name FailoverClusters)) {
        $nodes = (Get-ClusterNode -Cluster $ClusterName).Name
    }
    else {
        $nodes = Invoke-Command -ComputerName $ClusterName @credParam -ScriptBlock { (Get-ClusterNode).Name }
    }
}
else {
    $nodes = $ComputerName
}

if (-not $nodes) {
    Stop-Transcript | Out-Null
    throw 'No nodes found. Check the cluster name, remoting and permissions.'
}
Write-Host "Nodes: $($nodes -join ', ')"

$sessions = @(New-PSSession -ComputerName $nodes @credParam)
if ($sessions.Count -eq 0) {
    Stop-Transcript | Out-Null
    throw 'Could not open a PowerShell session to any node.'
}
if ($sessions.Count -lt @($nodes).Count) {
    Write-Warning "Only $($sessions.Count) of $(@($nodes).Count) nodes reachable. Results are incomplete."
}

# Cluster-wide queries only need to run on one node
$clusterSession = $sessions[0]

#endregion

#region 1. Live migration settings

$hostSettings = Invoke-Section 'Live migration settings' {
    $data = Invoke-Command -Session $sessions -ScriptBlock {
        $h = Get-VMHost
        $os = Get-CimInstance Win32_OperatingSystem
        [pscustomobject]@{
            Host                 = $env:COMPUTERNAME
            MigrationEnabled     = $h.VirtualMachineMigrationEnabled
            PerformanceOption    = [string]$h.VirtualMachineMigrationPerformanceOption
            AuthenticationType   = [string]$h.VirtualMachineMigrationAuthenticationType
            MaxVMMigrations      = $h.MaximumVirtualMachineMigrations
            MaxStorageMigrations = $h.MaximumStorageMigrations
            UseAnyNetwork        = $h.UseAnyNetworkForMigration
            OS                   = $os.Caption
            Build                = $os.BuildNumber
            LastBoot             = $os.LastBootUpTime
        }
    }
    Save-Csv $data 'HostSettings'
}
$hostSettings | Format-Table Host, MigrationEnabled, PerformanceOption, AuthenticationType, MaxVMMigrations, MaxStorageMigrations, UseAnyNetwork -AutoSize

foreach ($prop in 'PerformanceOption', 'AuthenticationType', 'MaxVMMigrations') {
    $values = @($hostSettings | Select-Object -ExpandProperty $prop -Unique)
    if ($values.Count -gt 1) {
        Write-Warning "$prop differs between nodes: $($values -join ', ')"
    }
}

#endregion

#region 2. Cluster networks

$clusterNetworks = Invoke-Section 'Cluster networks and live migration network selection' {
    $data = Invoke-Command -Session $clusterSession -ScriptBlock {
        $vmType  = Get-ClusterResourceType -Name 'Virtual Machine'
        $exclude = @(([string]($vmType | Get-ClusterParameter -Name MigrationExcludeNetworks).Value -split ';') | Where-Object { $_ })
        $order   = @(([string]($vmType | Get-ClusterParameter -Name MigrationNetworkOrder).Value -split ';') | Where-Object { $_ })

        foreach ($n in Get-ClusterNetwork) {
            $id   = [string]$n.Id
            $role = [string]$n.Role
            [pscustomobject]@{
                Network              = $n.Name
                Role                 = $role
                Metric               = $n.Metric
                Subnet               = "$($n.Address)/$($n.AddressMask)"
                State                = [string]$n.State
                LiveMigrationAllowed = ($exclude -notcontains $id) -and ($role -ne 'None')
                MigrationOrder       = if ($order -contains $id) { [array]::IndexOf($order, $id) + 1 } else { $null }
                Id                   = $id
            }
        }
    }
    Save-Csv $data 'ClusterNetworks'
}
$clusterNetworks | Sort-Object MigrationOrder | Format-Table Network, Role, Metric, Subnet, State, LiveMigrationAllowed, MigrationOrder -AutoSize

$netInterfaces = Invoke-Section 'Cluster network interfaces' {
    $data = Invoke-Command -Session $clusterSession -ScriptBlock {
        Get-ClusterNetworkInterface | ForEach-Object {
            [pscustomobject]@{
                Node    = [string]$_.Node
                Network = [string]$_.Network
                Adapter = [string]$_.Adapter
                Address = [string]$_.Address
                State   = [string]$_.State
            }
        }
    }
    Save-Csv $data 'ClusterNetworkInterfaces'
}
$netInterfaces | Sort-Object Network, Node | Format-Table -AutoSize

#endregion

#region 3. NICs and virtual switches

$nics = Invoke-Section 'Network adapters' {
    $data = Invoke-Command -Session $sessions -ScriptBlock {
        $jumbo = @{}
        Get-NetAdapterAdvancedProperty -RegistryKeyword '*JumboPacket' -ErrorAction SilentlyContinue |
            ForEach-Object { $jumbo[$_.Name] = $_.DisplayValue }

        Get-NetAdapter | ForEach-Object {
            [pscustomobject]@{
                Host          = $env:COMPUTERNAME
                Name          = $_.Name
                Description   = $_.InterfaceDescription
                Status        = [string]$_.Status
                LinkSpeed     = $_.LinkSpeed
                DriverVersion = $_.DriverVersionString
                DriverDate    = $_.DriverDate
                JumboPacket   = $jumbo[$_.Name]
                MacAddress    = $_.MacAddress
            }
        }
    }
    Save-Csv $data 'NetworkAdapters'
}
$nics | Sort-Object Host, Name | Format-Table Host, Name, Description, Status, LinkSpeed, DriverVersion, JumboPacket -AutoSize

$switches = Invoke-Section 'Hyper-V switches / SET' {
    $data = Invoke-Command -Session $sessions -ScriptBlock {
        Get-VMSwitch | ForEach-Object {
            $team = if ($_.EmbeddedTeamingEnabled) { Get-VMSwitchTeam -Name $_.Name } else { $null }
            [pscustomobject]@{
                Host          = $env:COMPUTERNAME
                Switch        = $_.Name
                Type          = [string]$_.SwitchType
                SET           = $_.EmbeddedTeamingEnabled
                LoadBalancing = if ($team) { [string]$team.LoadBalancingAlgorithm } else { $null }
                BandwidthMode = [string]$_.BandwidthReservationMode
                Adapters      = ($_.NetAdapterInterfaceDescriptions -join '; ')
            }
        }
    }
    Save-Csv $data 'VMSwitches'
}
$switches | Format-Table -AutoSize

#endregion

#region 4. SMB

$smb = Invoke-Section 'SMB bandwidth limit and multichannel' {
    $data = Invoke-Command -Session $sessions -ScriptBlock {
        $limit = $null
        if (Get-Command Get-SmbBandwidthLimit -ErrorAction SilentlyContinue) {
            $limit = Get-SmbBandwidthLimit -Category LiveMigration -ErrorAction SilentlyContinue
        }
        $conns = @(Get-SmbMultichannelConnection -ErrorAction SilentlyContinue)
        [pscustomobject]@{
            Host                       = $env:COMPUTERNAME
            LiveMigrationBandwidthCap  = if ($limit) { '{0:N0} MB/s' -f ($limit.BytesPerSecond / 1MB) } else { 'none' }
            ActiveMultichannelConns    = $conns.Count
            MultichannelPaths          = ($conns | ForEach-Object { "$($_.ClientIpAddress)->$($_.ServerIpAddress)" }) -join '; '
        }
    }
    Save-Csv $data 'Smb'
}
$smb | Format-Table -AutoSize
Write-Host 'Note: SMB multichannel connections are only listed while a migration (or other SMB traffic) is running.'

#endregion

#region 5. Defender exclusions

$defender = Invoke-Section 'Microsoft Defender exclusions' {
    $data = Invoke-Command -Session $sessions -ScriptBlock {
        if (-not (Get-Command Get-MpPreference -ErrorAction SilentlyContinue)) { return }

        # Recommended Hyper-V exclusions (Microsoft docs: antivirus exclusions for Hyper-V hosts)
        $recExt  = 'vhd', 'vhdx', 'avhd', 'avhdx', 'vhds', 'vhdpmem', 'iso', 'rct', 'mrt', 'vsv', 'bin', 'xml', 'vmcx', 'vmrs', 'vmgs'
        $recProc = 'vmms.exe', 'vmwp.exe', 'vmsp.exe', 'vmcompute.exe'

        $p = Get-MpPreference
        $s = Get-MpComputerStatus
        $ext  = @($p.ExclusionExtension | ForEach-Object { $_.TrimStart('*', '.').ToLower() })
        $proc = @($p.ExclusionProcess | ForEach-Object { (Split-Path $_ -Leaf).ToLower() })

        [pscustomobject]@{
            Host               = $env:COMPUTERNAME
            RealTimeProtection = $s.RealTimeProtectionEnabled
            MissingExtensions  = ($recExt | Where-Object { $ext -notcontains $_ }) -join ', '
            MissingProcesses   = ($recProc | Where-Object { $proc -notcontains $_ }) -join ', '
            ExclusionPath      = ($p.ExclusionPath -join '; ')
            ExclusionExtension = ($p.ExclusionExtension -join '; ')
            ExclusionProcess   = ($p.ExclusionProcess -join '; ')
        }
    }
    Save-Csv $data 'Defender'
}
$defender | Format-List Host, RealTimeProtection, MissingExtensions, MissingProcesses, ExclusionPath
Write-Host 'Note: if exclusions are hidden from local admins (MDE policy), they show as "N/A" and must be checked in the Defender portal/Intune.'

#endregion

#region 6. Event logs

$events = Invoke-Section 'Hyper-V and cluster events' {
    $data = Invoke-Command -Session $sessions -ArgumentList $StartTime, $EndTime -ScriptBlock {
        param($start, $end)
        $logs = 'Microsoft-Windows-Hyper-V-VMMS-Admin',
                'Microsoft-Windows-Hyper-V-VMMS-Operational',
                'Microsoft-Windows-Hyper-V-High-Availability-Admin',
                'Microsoft-Windows-Hyper-V-Worker-Admin',
                'Microsoft-Windows-FailoverClustering/Operational',
                'Microsoft-Windows-SMBClient/Connectivity'
        foreach ($log in $logs) {
            Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $start; EndTime = $end } -ErrorAction SilentlyContinue |
                Where-Object { $_.Level -in 1, 2, 3 -or $_.Message -match 'migrat' } |
                ForEach-Object {
                    [pscustomobject]@{
                        Time    = $_.TimeCreated
                        Host    = $env:COMPUTERNAME
                        Log     = $log
                        Id      = $_.Id
                        Level   = $_.LevelDisplayName
                        Message = ([string]$_.Message -replace '\s+', ' ').Trim()
                    }
                }
        }
    }
    Save-Csv ($data | Sort-Object Time) 'Events'
}

if ($events) {
    Write-Host "`nEvent count per host / log / level:"
    $events | Group-Object Host, Log, Level | Sort-Object Name |
        Format-Table @{ n = 'Host, Log, Level'; e = { $_.Name } }, Count -AutoSize

    Write-Host 'Errors and warnings (first 30):'
    $events | Where-Object { $_.Level -in 'Error', 'Warning', 'Critical', 'Fout', 'Waarschuwing', 'Kritiek' } |
        Select-Object -First 30 |
        Format-Table Time, Host, Id, Level, @{ n = 'Message'; e = { $_.Message.Substring(0, [math]::Min(140, $_.Message.Length)) } } -AutoSize
}
else {
    Write-Host 'No matching events in this time window.'
}

#endregion

#region 7. Cluster log

if (-not $SkipClusterLog) {
    $clusterLog = Invoke-Section 'Cluster log (lines mentioning migration)' {
        $data = Invoke-Command -Session $sessions -ArgumentList $StartTime, $EndTime -ScriptBlock {
            param($start, $end)
            $dest = Join-Path $env:TEMP ('lmreport-' + [guid]::NewGuid())
            New-Item -ItemType Directory -Path $dest | Out-Null
            try {
                $minutes = [int][math]::Ceiling(((Get-Date) - $start).TotalMinutes)
                Get-ClusterLog -Node $env:COMPUTERNAME -Destination $dest -TimeSpan $minutes -UseLocalTime | Out-Null

                Get-ChildItem -Path $dest -Filter *.log | Select-String -Pattern 'migrat' | ForEach-Object {
                    $time = $null
                    if ($_.Line -match '::(\d{4}/\d{2}/\d{2}-\d{2}:\d{2}:\d{2})') {
                        $time = [datetime]::ParseExact($Matches[1], 'yyyy/MM/dd-HH:mm:ss', $null)
                    }
                    if ($time -and ($time -lt $start -or $time -gt $end)) { return }
                    [pscustomobject]@{
                        Time = $time
                        Host = $env:COMPUTERNAME
                        Line = $_.Line.Trim()
                    }
                }
            }
            finally {
                Remove-Item -Path $dest -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Save-Csv ($data | Sort-Object Time) 'ClusterLog'
    }
    Write-Host "Cluster log lines mentioning migration: $(@($clusterLog).Count) (see ClusterLog.csv)"
}

#endregion

#region 8. Network tests

if (-not $SkipNetworkTests) {
    $lmNetworks = @($clusterNetworks | Where-Object LiveMigrationAllowed | Select-Object -ExpandProperty Network)
    $lmIfs = @($netInterfaces | Where-Object { $lmNetworks -contains $_.Network -and $_.Address })

    $tests = Invoke-Section 'Network tests on live migration networks (ping, jumbo 8972, TCP 6600)' {
        if ($lmIfs.Count -eq 0) {
            Write-Warning 'No live migration network interfaces found, skipping tests.'
            return
        }
        $data = Invoke-Command -Session $sessions -ArgumentList (, $lmIfs) -ScriptBlock {
            param($ifs)
            $me = $env:COMPUTERNAME
            foreach ($src in ($ifs | Where-Object { $_.Node -eq $me })) {
                foreach ($dst in ($ifs | Where-Object { $_.Network -eq $src.Network -and $_.Node -ne $me })) {
                    $std   = ping.exe -n 2 -w 1000 -S $src.Address $dst.Address
                    $jumbo = ping.exe -n 2 -w 1000 -f -l 8972 -S $src.Address $dst.Address
                    $tcp   = Test-NetConnection -ComputerName $dst.Address -Port 6600 -WarningAction SilentlyContinue
                    [pscustomobject]@{
                        Network   = $src.Network
                        From      = $me
                        FromIP    = $src.Address
                        To        = $dst.Node
                        ToIP      = $dst.Address
                        Ping      = [bool]($std -match 'TTL=')
                        Jumbo8972 = [bool]($jumbo -match 'TTL=')
                        Tcp6600   = [bool]$tcp.TcpTestSucceeded
                    }
                }
            }
        }
        Save-Csv $data 'NetworkTests'
    }
    $tests | Sort-Object Network, From, To | Format-Table Network, From, FromIP, To, ToIP, Ping, Jumbo8972, Tcp6600 -AutoSize

    $failed = @($tests | Where-Object { -not ($_.Ping -and $_.Jumbo8972 -and $_.Tcp6600) })
    if ($failed.Count -gt 0) {
        Write-Warning "$($failed.Count) network test(s) failed. Ping OK but Jumbo8972 failed = MTU mismatch somewhere in the path."
    }
}

#endregion

$sessions | Remove-PSSession

Write-Step 'Done'
Write-Host "CSV files and console output saved in: $OutputPath"
Stop-Transcript | Out-Null