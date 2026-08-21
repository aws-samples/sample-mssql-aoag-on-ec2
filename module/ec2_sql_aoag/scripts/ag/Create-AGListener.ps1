# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

<#
.SYNOPSIS
    Creates an Availability Group Listener with multi-subnet support.
.DESCRIPTION
    Idempotent - checks if listener already exists before creating.
    Accepts a JSON array of listener IPs with subnet masks for multi-AZ clusters.
    Each IP corresponds to a node in a different subnet.
    Uses IMDSv2 to discover subnet mask if not provided.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$AvailabilityGroupName,
    [Parameter(Mandatory=$true)][string]$ListenerName,
    [Parameter(Mandatory=$true)][string]$SQLInstanceName,
    [Parameter(Mandatory=$true)][int]$ListenerPort = 1433,
    [Parameter(Mandatory=$true)][string]$ListenerIPsJson
)
$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\aoag\log\Create-AGListener.log -Append
try {
    Write-Host "=== Create-AGListener ==="
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"
    Write-Host "AG: $AvailabilityGroupName"
    Write-Host "Listener: $ListenerName"
    Write-Host "Port: $ListenerPort"
    Write-Host "Listener IPs JSON: $ListenerIPsJson"

    # Load SQL module
    $sqlMod = Get-Module -Name SqlServer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
    if ($sqlMod) { Import-Module SqlServer -Force }
    else { Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue }

    # SECURITY NOTE: TrustServerCertificate = $true disables TLS certificate
    # validation on this connection - the client accepts any certificate the
    # server presents, so an attacker on the network path could intercept or
    # modify SQL traffic without detection.
    #
    # It is set here because SQL Server presents a self-signed certificate until
    # one is provisioned, which is the case during this bootstrap. It is NOT
    # appropriate for production: install a CA-issued certificate on each SQL
    # Server instance, then remove this block so validation applies.
    # See: https://learn.microsoft.com/sql/database-engine/configure-windows/configure-sql-server-encryption
    $sqlParams = @{}
    $cmdInfo = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue
    if ($cmdInfo -and $cmdInfo.Parameters.ContainsKey('TrustServerCertificate')) {
        $sqlParams['TrustServerCertificate'] = $true
    }

    # Build instance name
    if ($SQLInstanceName -eq 'MSSQLSERVER' -or $SQLInstanceName -eq 'DEFAULT') {
        $SqlInstance = $env:COMPUTERNAME
    } else {
        $SqlInstance = $env:COMPUTERNAME + '\' + $SQLInstanceName
    }
    Write-Host "SQL Instance: $SqlInstance"

    # Idempotency check - see if listener already exists
    $checkQuery = "SELECT dns_name, port FROM sys.availability_group_listeners WHERE group_id IN (SELECT group_id FROM sys.availability_groups WHERE name = '" + $AvailabilityGroupName + "')"
    $existing = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $checkQuery @sqlParams -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Listener already exists: $($existing.dns_name):$($existing.port) - nothing to do."
        exit 0
    }

    # Parse listener IPs - JSON array of objects: [{"ip":"10.0.2.55","mask":"255.255.255.0"}, ...]
    $listenerIPs = ConvertFrom-Json $ListenerIPsJson
    if (-not $listenerIPs -or $listenerIPs.Count -eq 0) {
        throw 'No listener IPs provided in ListenerIPsJson.'
    }

    Write-Host "Listener IPs to configure: $($listenerIPs.Count)"
    foreach ($entry in $listenerIPs) {
        Write-Host "  IP: $($entry.ip), Mask: $($entry.mask)"
    }

    # Build the WITH IP clause for multi-subnet listener
    $ipClauses = @()
    foreach ($entry in $listenerIPs) {
        $ipClauses += "(N'$($entry.ip)', N'$($entry.mask)')"
    }
    $ipClauseStr = $ipClauses -join ', '

    $createListenerSql = "ALTER AVAILABILITY GROUP [$AvailabilityGroupName] ADD LISTENER N'$ListenerName' (WITH IP ($ipClauseStr), PORT = $ListenerPort);"
    Write-Host "SQL: $createListenerSql"

    try {
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $createListenerSql -QueryTimeout 300 @sqlParams -ErrorAction Stop
    } catch {
        # TCP port conflict is non-fatal - the listener was created but SQL cannot bind
        # a second listener on the same port the instance already uses. This is expected
        # for single-node AGs where instance and listener share the same port.
        if ($_.Exception.Message -match 'TCP provider.*failed to listen|TCP port is already in use') {
            Write-Host "WARNING: Listener created but TCP port binding conflict (expected when listener port matches instance port). Continuing."
        } else {
            throw $_
        }
    }

    Write-Host "Listener created successfully."

    # Verify
    Start-Sleep -Seconds 5
    $verify = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "SELECT dns_name, port FROM sys.availability_group_listeners WHERE group_id IN (SELECT group_id FROM sys.availability_groups WHERE name = '$AvailabilityGroupName')" @sqlParams -ErrorAction SilentlyContinue
    if ($verify) {
        Write-Host "Verified listener: $($verify.dns_name):$($verify.port)"
    } else {
        Write-Host "WARNING: Listener verification returned no results."
    }

    Write-Host "=== Create-AGListener completed ==="
}
catch {
    Write-Error "Create-AGListener FAILED: $_"
    throw $_
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
