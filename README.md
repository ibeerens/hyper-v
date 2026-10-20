# Hyper-V scripts

PowerShell utilities for reviewing Hyper-V live migration configuration and monitoring host network adapter traffic.

## Scripts

### `Get-LiveMigrationReport.ps1`

Collects a troubleshooting report for a Hyper-V failover cluster, or for a specified list of Hyper-V hosts. It gathers:

- Live migration host settings and cluster network roles/order
- Cluster network interfaces, physical NIC details, and Hyper-V virtual switches / SET configuration
- SMB live migration bandwidth limits and active multichannel connections
- Microsoft Defender status and Hyper-V recommended exclusions
- Hyper-V, Failover Clustering, and SMB event log entries for a selected time window
- Cluster log lines mentioning migration
- Connectivity checks between migration network interfaces (standard ping, jumbo-frame ping with an 8972-byte payload, and TCP port 6600)

The script does not change host configuration. It creates a temporary cluster log on each queried host and removes it when collection is complete. Results are written as CSV files, with a `console.txt` transcript, to the output directory.

**Requirements:** Run from a management VM with PowerShell remoting (WinRM) access and local administrator rights on the Hyper-V hosts. Cluster-based discovery requires access to the Failover Clustering tools or remote access to the cluster.

**Examples**

```powershell
# Discover hosts from a cluster and report on the last 24 hours
.\Get-LiveMigrationReport.ps1 -ClusterName 'HV-Cluster'

# Report on named hosts and specify the time range and output directory
.\Get-LiveMigrationReport.ps1 `
    -ComputerName 'HV-01', 'HV-02' `
    -StartTime (Get-Date).AddHours(-6) `
    -EndTime (Get-Date) `
    -OutputPath '.\LM-Report'

# Supply credentials when needed
.\Get-LiveMigrationReport.ps1 -ClusterName 'HV-Cluster' -Credential (Get-Credential)
```

Use either `-ClusterName` or `-ComputerName`. The time range defaults to the last 24 hours. `-SkipClusterLog` omits cluster log collection, and `-SkipNetworkTests` omits the connectivity checks.

### `Monitor-HV-Nics.ps1`

Continuously displays each network adapter's approximate send and receive traffic in MB/s. At startup, it asks how many seconds to wait between samples; the displayed rates are averaged over that interval. The console refreshes and sorts the table by traffic. Press **Ctrl+C** to stop.

Run it in a PowerShell session on the Hyper-V host whose adapters you want to monitor:

```powershell
.\Monitor-HV-Nics.ps1
```
