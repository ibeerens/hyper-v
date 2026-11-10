#Requires -Modules ActiveDirectory
Import-Module ActiveDirectory
# Performance option. The script uses SMB as the transport for Live Migration. If your Live Migration network doesn’t have RDMA or SMB Direct, change it to Compression.
# Live Migration network. The script doesn’t choose which network Live Migration uses. To limit it to a dedicated subnet, run this on each host:
# Set-VMMigrationNetwork 172.20.3.0/24 -Priority 1
# AD has to replicate to all domain controllers before the delegation works everywhere. If a migration still fails with 0x8009030E or “no credentials available”, wait a few minutes or restart the VMMS service on the host:

Import-Module ActiveDirectory
$hosts    = 'host1','host2'
$services = 'Microsoft Virtual System Migration Service','cifs'
$domain   = (Get-ADDomain).DNSRoot

# 1. Constrained delegation in AD ("Use Kerberos only")
foreach ($source in $hosts) {
    $computer = Get-ADComputer $source -Properties msDS-AllowedToDelegateTo
    $existing = @($computer.'msDS-AllowedToDelegateTo')

    $spns = foreach ($target in $hosts | Where-Object { $_ -ne $source }) {
        foreach ($svc in $services) { "$svc/$target"; "$svc/$target.$domain" }
    }

    $toAdd = $spns | Where-Object { $_ -notin $existing }
    if ($toAdd) {
        Set-ADComputer $computer -Add @{ 'msDS-AllowedToDelegateTo' = [string[]]$toAdd }
        Write-Host "$source : $($toAdd.Count) SPN(s) added" -ForegroundColor Green
    } else {
        Write-Host "$source : already configured" -ForegroundColor Yellow
    }

    # Kerberos only, so no protocol transition
    Set-ADAccountControl $computer -TrustedToAuthForDelegation $false
}

# 2. Set up Live Migration on each host to use Kerberos
Invoke-Command -ComputerName $hosts -ScriptBlock {
    Enable-VMMigration
    Set-VMHost -VirtualMachineMigrationAuthenticationType Kerberos `
               -VirtualMachineMigrationPerformanceOption SMB `
               -MaximumVirtualMachineMigrations 4
    klist purge -li 0x3e7 | Out-Null   # flush the computer account's Kerberos tickets
    Get-VMHost | Select-Object ComputerName, VirtualMachineMigrationEnabled, VirtualMachineMigrationAuthenticationType
}

# 3. Check
Get-ADComputer "hyperv" -Properties msDS-AllowedToDelegateTo | Select-Object -ExpandProperty msDS-AllowedToDelegateTo
