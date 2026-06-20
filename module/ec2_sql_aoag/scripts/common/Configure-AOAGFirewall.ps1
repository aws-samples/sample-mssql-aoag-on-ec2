# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [int]$ListenerPort = 1433,

    [Parameter(Mandatory = $false)]
    [int]$MirroringPort = 5022
)

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\aoag\log\Configure-AOAGFirewall.ps1.txt -Append

try {
    Write-Output "Configuring firewall rules for Always On Availability Groups..."

    # SQL Server port
    $sqlRule = Get-NetFirewallRule -DisplayName "SQL Server" -ErrorAction SilentlyContinue
    if (-not $sqlRule) {
        Write-Output "Creating SQL Server firewall rule (port $ListenerPort)..."
        New-NetFirewallRule -DisplayName "SQL Server" -Direction Inbound -Protocol TCP -LocalPort $ListenerPort -Action Allow
    }

    # Database Mirroring endpoint
    $mirrorRule = Get-NetFirewallRule -DisplayName "SQL Server Mirroring" -ErrorAction SilentlyContinue
    if (-not $mirrorRule) {
        Write-Output "Creating SQL Server Mirroring firewall rule (port $MirroringPort)..."
        New-NetFirewallRule -DisplayName "SQL Server Mirroring" -Direction Inbound -Protocol TCP -LocalPort $MirroringPort -Action Allow
    }

    # AG Listener (if different from SQL port)
    if ($ListenerPort -ne 1433) {
        $listenerRule = Get-NetFirewallRule -DisplayName "SQL AG Listener" -ErrorAction SilentlyContinue
        if (-not $listenerRule) {
            Write-Output "Creating AG Listener firewall rule (port $ListenerPort)..."
            New-NetFirewallRule -DisplayName "SQL AG Listener" -Direction Inbound -Protocol TCP -LocalPort $ListenerPort -Action Allow
        }
    }

    # WSFC ports
    $wsfcPorts = @(135, 137, 138, 139, 445, 3343, 5985, 5986)
    foreach ($port in $wsfcPorts) {
        $ruleName = "WSFC Port $port"
        $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if (-not $rule) {
            Write-Output "Creating WSFC firewall rule (port $port)..."
            New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP -LocalPort $port -Action Allow
        }
    }

    # WSFC UDP ports
    $wsfcUdpPorts = @(137, 138, 3343)
    foreach ($port in $wsfcUdpPorts) {
        $ruleName = "WSFC UDP Port $port"
        $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
        if (-not $rule) {
            Write-Output "Creating WSFC UDP firewall rule (port $port)..."
            New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol UDP -LocalPort $port -Action Allow
        }
    }

    Write-Output "Firewall configuration completed successfully"
}
catch {
    Write-Error "Failed to configure firewall: $_"
    throw $_
}
finally {
    Stop-Transcript
}
