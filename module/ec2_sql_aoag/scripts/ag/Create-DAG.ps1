# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

<#
.SYNOPSIS
    Creates or Joins a Distributed Availability Group (DAG).
.DESCRIPTION
    Single script for both sides of the DAG:
    - Action=Create: Runs on PRIMARY site. Creates the DAG linking primary AG to DR AG.
    - Action=Join: Runs on DR site. Joins the DR AG to the existing DAG.
    Idempotent - checks if DAG already exists before creating/joining.
    Uses single-quote concatenation to avoid S3 encoding issues.
    No em dashes in comments or strings.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Create','Join')][string]$Action,
    [Parameter(Mandatory=$true)][string]$DAGName,
    [Parameter(Mandatory=$true)][string]$PrimaryAGName,
    [Parameter(Mandatory=$true)][string]$DRAGName,
    [Parameter(Mandatory=$true)][string]$PrimaryListenerName,
    [Parameter(Mandatory=$true)][string]$DRListenerName,
    [Parameter(Mandatory=$true)][string]$SQLInstanceName,
    [Parameter(Mandatory=$false)][int]$EndpointPort = 5022,
    [Parameter(Mandatory=$false)][ValidateSet('AUTOMATIC','MANUAL')][string]$SeedingMode = 'AUTOMATIC'
)
$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\aoag\log\Create-DAG.log -Append
try {
    Write-Host "=== Create-DAG ($Action) ==="
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"
    Write-Host "DAG Name: $DAGName"
    Write-Host "Primary AG: $PrimaryAGName"
    Write-Host "DR AG: $DRAGName"
    Write-Host "Primary Listener: $PrimaryListenerName"
    Write-Host "DR Listener: $DRListenerName"
    Write-Host "Seeding Mode: $SeedingMode"

    # Load SQL module
    $sqlMod = Get-Module -Name SqlServer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
    if ($sqlMod) { Import-Module SqlServer -Force }
    else { Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue }

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

    # Idempotency check - see if DAG already exists on this node
    $checkQuery = "SELECT name FROM sys.availability_groups WHERE name = '" + $DAGName + "' AND is_distributed = 1"
    $existing = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $checkQuery @sqlParams -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "Distributed AG '$DAGName' already exists on this node - nothing to do."
        exit 0
    }

    # Check for name conflict with a non-distributed AG
    $conflictQuery = "SELECT name, is_distributed FROM sys.availability_groups WHERE name = '" + $DAGName + "'"
    $conflict = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $conflictQuery @sqlParams -ErrorAction SilentlyContinue
    if ($conflict) {
        throw ('An AG named ' + $DAGName + ' exists but is_distributed=' + $conflict.is_distributed + '. Remove it first.')
    }

    # Build listener endpoint URLs (TCP://FQDN:port)
    $primaryListenerUrl = 'TCP://' + $PrimaryListenerName + ':' + $EndpointPort
    $drListenerUrl = 'TCP://' + $DRListenerName + ':' + $EndpointPort
    Write-Host "Primary Listener URL: $primaryListenerUrl"
    Write-Host "DR Listener URL: $drListenerUrl"

    if ($Action -eq 'Create') {
        # ---------------------------------------------------------------
        # CREATE: Run on primary site node
        # Verify the primary AG exists locally before creating DAG
        # ---------------------------------------------------------------
        $primaryAgCheck = "SELECT name FROM sys.availability_groups WHERE name = '" + $PrimaryAGName + "'"
        $primaryAg = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $primaryAgCheck @sqlParams -ErrorAction Stop
        if (-not $primaryAg) {
            throw ('Primary AG ' + $PrimaryAGName + ' does not exist on this node. Cannot create DAG.')
        }
        Write-Host "Primary AG '$PrimaryAGName' confirmed on this node."

        $createSql = @"
CREATE AVAILABILITY GROUP [$DAGName]
WITH (DISTRIBUTED)
AVAILABILITY GROUP ON
    N'$PrimaryAGName' WITH (
        LISTENER_URL = N'$primaryListenerUrl',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = $SeedingMode
    ),
    N'$DRAGName' WITH (
        LISTENER_URL = N'$drListenerUrl',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = $SeedingMode
    );
"@
        Write-Host "Creating Distributed AG: $DAGName"
        Write-Host "SQL: $createSql"
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $createSql @sqlParams -ErrorAction Stop
        Write-Host "Distributed AG '$DAGName' created successfully on primary site."
    }
    elseif ($Action -eq 'Join') {
        # ---------------------------------------------------------------
        # JOIN: Run on DR site node
        # Verify the DR AG exists locally before joining DAG
        # ---------------------------------------------------------------
        $drAgCheck = "SELECT name FROM sys.availability_groups WHERE name = '" + $DRAGName + "'"
        $drAg = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $drAgCheck @sqlParams -ErrorAction Stop
        if (-not $drAg) {
            throw ('DR AG ' + $DRAGName + ' does not exist on this node. Cannot join DAG.')
        }
        Write-Host "DR AG '$DRAGName' confirmed on this node."

        $joinSql = @"
ALTER AVAILABILITY GROUP [$DAGName]
JOIN
AVAILABILITY GROUP ON
    N'$PrimaryAGName' WITH (
        LISTENER_URL = N'$primaryListenerUrl',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = $SeedingMode
    ),
    N'$DRAGName' WITH (
        LISTENER_URL = N'$drListenerUrl',
        AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT,
        FAILOVER_MODE = MANUAL,
        SEEDING_MODE = $SeedingMode
    );
"@
        Write-Host "Joining Distributed AG: $DAGName from DR site"
        Write-Host "SQL: $joinSql"
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $joinSql @sqlParams -ErrorAction Stop
        Write-Host "DR site joined Distributed AG '$DAGName' successfully."

        # Grant automatic seeding on the DR AG only when SEEDING_MODE = AUTOMATIC.
        # For MANUAL seeding the operator restores databases with NORECOVERY before
        # attaching them, so this grant is unnecessary.
        if ($SeedingMode -eq 'AUTOMATIC') {
            $grantSql = "ALTER AVAILABILITY GROUP [" + $DRAGName + "] GRANT CREATE ANY DATABASE"
            Write-Host "Granting CREATE ANY DATABASE on DR AG: $grantSql"
            Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $grantSql @sqlParams -ErrorAction Stop
            Write-Host "Seeding grant applied on DR AG '$DRAGName'."
        } else {
            Write-Host "Skipping CREATE ANY DATABASE grant - SeedingMode is MANUAL."
            Write-Host "Operator must restore databases WITH NORECOVERY on DR replicas, then run ALTER DATABASE [<db>] SET HADR AVAILABILITY GROUP = [$DRAGName]."
        }
    }

    # Verification - confirm DAG exists and check state
    Start-Sleep -Seconds 5
    $verifyQuery = @"
SELECT ag.name AS dag_name, ag.is_distributed,
       ags.primary_replica, ags.synchronization_health_desc
FROM sys.availability_groups ag
LEFT JOIN sys.dm_hadr_availability_group_states ags ON ag.group_id = ags.group_id
WHERE ag.name = '$DAGName' AND ag.is_distributed = 1
"@
    $verify = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $verifyQuery @sqlParams -ErrorAction SilentlyContinue
    if ($verify) {
        Write-Host "Verified DAG: $($verify.dag_name), Primary: $($verify.primary_replica), Health: $($verify.synchronization_health_desc)"
    } else {
        Write-Host "WARNING: DAG verification query returned no results. It may take a moment to initialize."
    }

    Write-Host "=== Create-DAG ($Action) completed ==="
}
catch {
    Write-Error "Create-DAG ($Action) FAILED: $_"
    throw $_
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
