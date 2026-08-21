# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

<#
.SYNOPSIS
    Joins a secondary replica to the Availability Group.
.DESCRIPTION
    Adds the secondary replica definition on the primary, then joins locally.
    Uses -TrustServerCertificate for SqlServer module v22+ compatibility.
    Uses single-quote concatenation to avoid S3 encoding issues.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$AvailabilityGroupName,
    [Parameter(Mandatory=$true)][string]$PrimaryNodeName,
    [Parameter(Mandatory=$true)][string]$SQLInstanceName,
    [Parameter(Mandatory=$false)][int]$EndpointPort = 5022
)
$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\aoag\log\Join-AG.log -Append
try {
    Write-Host "=== Join-AG ==="
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"

    # Load SQL module
    $sqlMod = Get-Module -Name SqlServer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
    if ($sqlMod) { Import-Module SqlServer -Force }
    else { Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue }

    # Build instance names and SQLSERVER: paths
    # For named instances: SQLSERVER:\SQL\COMPUTERNAME\INSTANCENAME
    # For default instance: SQLSERVER:\SQL\COMPUTERNAME\DEFAULT
    if ($SQLInstanceName -eq 'MSSQLSERVER' -or $SQLInstanceName -eq 'DEFAULT') {
        $SqlInstance = $env:COMPUTERNAME
        $PrimarySqlInstance = $PrimaryNodeName
        $localSqlPath = 'SQLSERVER:\SQL\' + $env:COMPUTERNAME + '\DEFAULT'
        $primaryAgPath = 'SQLSERVER:\SQL\' + $PrimaryNodeName + '\DEFAULT\AvailabilityGroups\' + $AvailabilityGroupName
    } else {
        $SqlInstance = $env:COMPUTERNAME + '\' + $SQLInstanceName
        $PrimarySqlInstance = $PrimaryNodeName + '\' + $SQLInstanceName
        $localSqlPath = 'SQLSERVER:\SQL\' + $env:COMPUTERNAME + '\' + $SQLInstanceName
        $primaryAgPath = 'SQLSERVER:\SQL\' + $PrimaryNodeName + '\' + $SQLInstanceName + '\AvailabilityGroups\' + $AvailabilityGroupName
    }
    Write-Host "Local Instance: $SqlInstance"
    Write-Host "Primary Instance: $PrimarySqlInstance"
    Write-Host "Local SQL Path: $localSqlPath"
    Write-Host "Primary AG Path: $primaryAgPath"
    Write-Host "AG Name: $AvailabilityGroupName"

    # Check if already joined
    #
    # SECURITY NOTE: TrustServerCertificate = $true below disables TLS certificate
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
    $checkQuery = "SELECT rs.role_desc FROM sys.dm_hadr_availability_replica_states rs JOIN sys.availability_replicas r ON rs.replica_id = r.replica_id WHERE rs.is_local = 1"
    $localRole = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $checkQuery @sqlParams -ErrorAction SilentlyContinue
    if ($localRole) {
        Write-Host "Already joined to an AG as $($localRole.role_desc) - nothing to do."
        exit 0
    }

    Write-Host "Adding replica definition on primary..."

    $fqdn = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
    $endpointUrl = 'TCP://' + $fqdn + ':' + $EndpointPort

    # Prefer PowerShell cmdlets if available, fall back to T-SQL
    $addReplicaCmd = Get-Command -Name Add-SqlAvailabilityReplica -ErrorAction SilentlyContinue
    $newReplicaCmd = Get-Command -Name New-SqlAvailabilityReplica -ErrorAction SilentlyContinue

    if ($addReplicaCmd -and $newReplicaCmd) {
        # Check if SeedingMode parameter is supported (older SqlServer modules lack it)
        $replicaCmdInfo = Get-Command -Name New-SqlAvailabilityReplica -ErrorAction SilentlyContinue
        $supportsSeedingMode = $replicaCmdInfo -and $replicaCmdInfo.Parameters.ContainsKey('SeedingMode')

        if ($supportsSeedingMode) {
            Write-Host "Using PowerShell cmdlets (with SeedingMode)..."
            # Detect SQL major version from registry for -Version parameter
            $sqlMajorVersion = 16
            try {
                $regBase = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
                $instRegName = (Get-ItemProperty $regBase -ErrorAction SilentlyContinue).$SQLInstanceName
                if ($instRegName -and $instRegName -match '^MSSQL(\d+)\.') { $sqlMajorVersion = [int]$Matches[1] }
            } catch { Write-Host "WARNING: Could not detect SQL version from registry, using default $sqlMajorVersion" }
            Write-Host "SQL Major Version: $sqlMajorVersion"

            $NewReplica = New-SqlAvailabilityReplica -Name $SqlInstance `
                -EndpointUrl $endpointUrl `
                -AvailabilityMode SynchronousCommit `
                -FailoverMode Automatic `
                -SeedingMode Automatic `
                -AsTemplate -Version $sqlMajorVersion

            Add-SqlAvailabilityReplica -InputObject $NewReplica -Path $primaryAgPath
        } else {
            Write-Host "PowerShell cmdlets available but SeedingMode not supported - using T-SQL..."
            $addReplicaSql = 'ALTER AVAILABILITY GROUP [' + $AvailabilityGroupName + '] ADD REPLICA ON N''' + $SqlInstance + ''' WITH (ENDPOINT_URL = N''' + $endpointUrl + ''', AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = AUTOMATIC, SEEDING_MODE = AUTOMATIC);'
            Write-Host "Running on primary: $addReplicaSql"
            Invoke-Sqlcmd -ServerInstance $PrimarySqlInstance -Query $addReplicaSql @sqlParams -ErrorAction Stop
        }
    } else {
        Write-Host "PowerShell AG cmdlets not available, using T-SQL..."
        $addReplicaSql = 'ALTER AVAILABILITY GROUP [' + $AvailabilityGroupName + '] ADD REPLICA ON N''' + $SqlInstance + ''' WITH (ENDPOINT_URL = N''' + $endpointUrl + ''', AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = AUTOMATIC, SEEDING_MODE = AUTOMATIC);'
        Write-Host "Running on primary: $addReplicaSql"
        Invoke-Sqlcmd -ServerInstance $PrimarySqlInstance -Query $addReplicaSql @sqlParams -ErrorAction Stop
    }
    Write-Host "Replica added on primary."

    Write-Host "Joining local replica to AG..."
    $joinCmd = Get-Command -Name Join-SqlAvailabilityGroup -ErrorAction SilentlyContinue
    if ($joinCmd) {
        Write-Host "Using PowerShell cmdlet..."
        Join-SqlAvailabilityGroup -Name $AvailabilityGroupName -Path $localSqlPath
    } else {
        Write-Host "Using T-SQL..."
        $joinSql = 'ALTER AVAILABILITY GROUP [' + $AvailabilityGroupName + '] JOIN;'
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $joinSql @sqlParams -ErrorAction Stop
    }
    Write-Host "Local replica joined."

    Write-Host "Granting automatic seeding permission..."
    $seedingQuery = 'ALTER AVAILABILITY GROUP [' + $AvailabilityGroupName + '] GRANT CREATE ANY DATABASE;'
    Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $seedingQuery @sqlParams -ErrorAction Stop

    Write-Host "Successfully joined $SqlInstance to $AvailabilityGroupName"
    Write-Host "=== Join-AG completed ==="
}
catch {
    Write-Error "Join-AG FAILED: $_"
    throw $_
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
