# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

<#
.SYNOPSIS
    Adds a database to an existing Availability Group.
.DESCRIPTION
    Idempotent. Two seeding modes:
      AUTOMATIC (default): Sets recovery to FULL, takes a full + log backup,
                           then ALTER AVAILABILITY GROUP ADD DATABASE. SQL Server
                           pushes the data to all secondary replicas over the AG
                           endpoint. Best for DBs <100 GB on a fast network.
      MANUAL:              Operator is responsible for restoring the database
                           WITH NORECOVERY on every secondary BEFORE running this
                           script. The script will only run ADD DATABASE on the
                           primary and ALTER DATABASE SET HADR on each secondary
                           the operator passes via -SecondaryNodes. Required for
                           VLDBs and on-prem extension scenarios.
.PARAMETER AvailabilityGroupName
    Name of the existing AG.
.PARAMETER DatabaseName
    Name of the database to add. Must exist on the primary in FULL recovery.
.PARAMETER SQLInstanceName
    SQL Server instance name (e.g. MSSQLSERVER for default).
.PARAMETER SeedingMode
    AUTOMATIC or MANUAL. Defaults to AUTOMATIC for backward compatibility.
.PARAMETER BackupPath
    Local path used for the full + log backup taken on the primary.
    Used for AUTOMATIC mode only. Default: C:\sqlbackup.
.PARAMETER SecondaryNodes
    Comma-separated list of secondary node hostnames. Required for MANUAL mode.
    Each name is used as a SQL Server instance target for ALTER DATABASE SET HADR.
.NOTES
    Designed to be invoked by SSM Automation document
    'proserve_aoag_add_database', or directly via Invoke-Command.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AvailabilityGroupName,

    [Parameter(Mandatory = $true)]
    [string]$DatabaseName,

    [Parameter(Mandatory = $true)]
    [string]$SQLInstanceName,

    [Parameter(Mandatory = $false)]
    [ValidateSet('AUTOMATIC', 'MANUAL')]
    [string]$SeedingMode = 'AUTOMATIC',

    [Parameter(Mandatory = $false)]
    [string]$BackupPath = "C:\sqlbackup",

    [Parameter(Mandatory = $false)]
    [string]$SecondaryNodes = ''
)

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\aoag\log\Add-DatabaseToAG.log -Append

try {
    Write-Host "=== Add-DatabaseToAG ==="
    Write-Host "AG Name        : $AvailabilityGroupName"
    Write-Host "Database Name  : $DatabaseName"
    Write-Host "SQL Instance   : $SQLInstanceName"
    Write-Host "Seeding Mode   : $SeedingMode"

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
        $LocalInstance = $env:COMPUTERNAME
    } else {
        $LocalInstance = $env:COMPUTERNAME + '\' + $SQLInstanceName
    }
    Write-Host "Local SQL Instance: $LocalInstance"

    # Idempotency: skip if already in the AG on this node
    $alreadyJoined = Invoke-Sqlcmd -ServerInstance $LocalInstance @sqlParams -ErrorAction SilentlyContinue -Query @"
SELECT db.name
FROM sys.databases db
JOIN sys.dm_hadr_database_replica_states drs ON db.database_id = drs.database_id
JOIN sys.availability_groups ag ON drs.group_id = ag.group_id
WHERE db.name = '$DatabaseName' AND ag.name = '$AvailabilityGroupName'
"@
    if ($alreadyJoined) {
        Write-Host "Database '$DatabaseName' is already a member of AG '$AvailabilityGroupName' - nothing to do."
        exit 0
    }

    # Verify the database exists locally
    $dbExists = Invoke-Sqlcmd -ServerInstance $LocalInstance @sqlParams -Query "SELECT name FROM sys.databases WHERE name = '$DatabaseName'"
    if (-not $dbExists) {
        throw "Database $DatabaseName does not exist on $LocalInstance. Restore or create it first."
    }

    # Set recovery model to FULL (required for AG)
    Write-Host "Setting recovery model to FULL on primary..."
    Invoke-Sqlcmd -ServerInstance $LocalInstance @sqlParams -Query "ALTER DATABASE [$DatabaseName] SET RECOVERY FULL"

    if ($SeedingMode -eq 'AUTOMATIC') {
        # ---------------------------------------------------------------
        # AUTOMATIC seeding: SQL Server pushes the data over AG endpoint.
        # We still need at least one full backup so the DB has a backup chain.
        # ---------------------------------------------------------------
        if (-not (Test-Path $BackupPath)) {
            Write-Host "Creating backup directory $BackupPath ..."
            New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
        }

        Write-Host "Taking full backup to $BackupPath ..."
        Invoke-Sqlcmd -ServerInstance $LocalInstance @sqlParams -Query "BACKUP DATABASE [$DatabaseName] TO DISK = '$BackupPath\$DatabaseName.bak' WITH INIT, COMPRESSION"

        Write-Host "Taking log backup to $BackupPath ..."
        Invoke-Sqlcmd -ServerInstance $LocalInstance @sqlParams -Query "BACKUP LOG [$DatabaseName] TO DISK = '$BackupPath\$DatabaseName.trn' WITH INIT, COMPRESSION"

        Write-Host "Adding database to AG '$AvailabilityGroupName' (automatic seeding)..."
        Invoke-Sqlcmd -ServerInstance $LocalInstance @sqlParams -Query "ALTER AVAILABILITY GROUP [$AvailabilityGroupName] ADD DATABASE [$DatabaseName]"

        Write-Host "Database '$DatabaseName' added to AG. SQL Server will seed it to all secondaries."
    }
    else {
        # ---------------------------------------------------------------
        # MANUAL seeding: operator pre-restores the DB on every secondary
        # WITH NORECOVERY. We only run ADD DATABASE on the primary and
        # SET HADR on each secondary the operator passes in.
        # ---------------------------------------------------------------
        if ([string]::IsNullOrWhiteSpace($SecondaryNodes)) {
            throw "MANUAL seeding requires -SecondaryNodes (comma-separated hostnames). Each secondary must already have the database restored WITH NORECOVERY."
        }
        $secondaryList = $SecondaryNodes -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        Write-Host "Secondary nodes: $($secondaryList -join ', ')"

        # Pre-flight: verify the DB is in RESTORING state on every secondary
        Write-Host "Verifying database state on each secondary..."
        foreach ($node in $secondaryList) {
            $remoteInstance = if ($SQLInstanceName -eq 'MSSQLSERVER' -or $SQLInstanceName -eq 'DEFAULT') { $node } else { "$node\$SQLInstanceName" }
            $remoteState = Invoke-Sqlcmd -ServerInstance $remoteInstance @sqlParams -ErrorAction Stop -Query "SELECT state_desc FROM sys.databases WHERE name = '$DatabaseName'"
            if (-not $remoteState) {
                throw "Database '$DatabaseName' does not exist on secondary $remoteInstance. Restore it WITH NORECOVERY before running this script."
            }
            if ($remoteState.state_desc -ne 'RESTORING') {
                throw "Database '$DatabaseName' on $remoteInstance is in state '$($remoteState.state_desc)' but must be 'RESTORING'. Restore WITH NORECOVERY."
            }
            Write-Host "  $remoteInstance : RESTORING (ok)"
        }

        Write-Host "Adding database to AG '$AvailabilityGroupName' on primary (manual seeding)..."
        Invoke-Sqlcmd -ServerInstance $LocalInstance @sqlParams -Query "ALTER AVAILABILITY GROUP [$AvailabilityGroupName] ADD DATABASE [$DatabaseName]"

        # Attach the pre-restored DB to the AG on each secondary
        foreach ($node in $secondaryList) {
            $remoteInstance = if ($SQLInstanceName -eq 'MSSQLSERVER' -or $SQLInstanceName -eq 'DEFAULT') { $node } else { "$node\$SQLInstanceName" }
            Write-Host "Setting HADR AG on secondary $remoteInstance ..."
            Invoke-Sqlcmd -ServerInstance $remoteInstance @sqlParams -ErrorAction Stop `
                -Query "ALTER DATABASE [$DatabaseName] SET HADR AVAILABILITY GROUP = [$AvailabilityGroupName]"
        }

        Write-Host "Database '$DatabaseName' joined to AG on all secondaries."
    }

    # Verify
    Start-Sleep -Seconds 5
    $verify = Invoke-Sqlcmd -ServerInstance $LocalInstance @sqlParams -ErrorAction SilentlyContinue -Query @"
SELECT db.name AS db_name, drs.synchronization_state_desc, drs.synchronization_health_desc
FROM sys.databases db
JOIN sys.dm_hadr_database_replica_states drs ON db.database_id = drs.database_id
WHERE db.name = '$DatabaseName' AND drs.is_local = 1
"@
    if ($verify) {
        Write-Host "Verified: db=$($verify.db_name) state=$($verify.synchronization_state_desc) health=$($verify.synchronization_health_desc)"
    }

    Write-Host "=== Add-DatabaseToAG completed ($SeedingMode) ==="
}
catch {
    Write-Error "Add-DatabaseToAG FAILED: $_"
    throw $_
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
