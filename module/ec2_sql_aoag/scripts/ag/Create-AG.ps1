# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

<#
.SYNOPSIS
    Creates the SQL Server Availability Group on the primary replica.
.DESCRIPTION
    Idempotent - checks if AG already exists before creating.
    Uses -TrustServerCertificate for SqlServer module v22+ compatibility.
    Uses single-quote concatenation to avoid S3 encoding issues.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$AvailabilityGroupName,
    [Parameter(Mandatory=$true)][string]$SQLInstanceName,
    [Parameter(Mandatory=$false)][int]$EndpointPort = 5022
)
$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\aoag\log\Create-AG.log -Append
try {
    Write-Host "=== Create-AG ==="
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"

    # Load SQL module
    $sqlMod = Get-Module -Name SqlServer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
    if ($sqlMod) { Import-Module SqlServer -Force }
    else { Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue }

    # Common Invoke-Sqlcmd params (SqlServer v22+ requires TrustServerCertificate)
    $sqlParams = @{}
    $cmdInfo = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue
    if ($cmdInfo -and $cmdInfo.Parameters.ContainsKey('TrustServerCertificate')) {
        $sqlParams['TrustServerCertificate'] = $true
    }

    # Build instance name and SQLSERVER: path
    # For named instances: SQLSERVER:\SQL\COMPUTERNAME\INSTANCENAME
    # For default instance: SQLSERVER:\SQL\COMPUTERNAME\DEFAULT
    if ($SQLInstanceName -eq 'MSSQLSERVER' -or $SQLInstanceName -eq 'DEFAULT') {
        $SqlInstance = $env:COMPUTERNAME
        $sqlPath = 'SQLSERVER:\SQL\' + $env:COMPUTERNAME + '\DEFAULT'
    } else {
        $SqlInstance = $env:COMPUTERNAME + '\' + $SQLInstanceName
        $sqlPath = 'SQLSERVER:\SQL\' + $env:COMPUTERNAME + '\' + $SQLInstanceName
    }
    Write-Host "SQL Instance: $SqlInstance"
    Write-Host "SQL Path: $sqlPath"
    Write-Host "AG Name: $AvailabilityGroupName"

    # Idempotency check
    $query = "SELECT name FROM sys.availability_groups WHERE name = '$AvailabilityGroupName'"
    $result = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $query @sqlParams -ErrorAction SilentlyContinue

    if ($result) {
        Write-Host "Availability Group $AvailabilityGroupName already exists - nothing to do."
        exit 0
    }

    Write-Host "Creating Availability Group: $AvailabilityGroupName"

    $fqdn = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
    $endpointUrl = 'TCP://' + $fqdn + ':' + $EndpointPort

    # Prefer PowerShell cmdlets if available, fall back to T-SQL
    $newAgCmd = Get-Command -Name New-SqlAvailabilityGroup -ErrorAction SilentlyContinue
    $newReplicaCmd = Get-Command -Name New-SqlAvailabilityReplica -ErrorAction SilentlyContinue

    if ($newAgCmd -and $newReplicaCmd) {
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

            $PrimaryReplica = New-SqlAvailabilityReplica -Name $SqlInstance `
                -EndpointUrl $endpointUrl `
                -AvailabilityMode SynchronousCommit `
                -FailoverMode Automatic `
                -SeedingMode Automatic `
                -AsTemplate -Version $sqlMajorVersion

            New-SqlAvailabilityGroup -Name $AvailabilityGroupName `
                -Path $sqlPath `
                -AvailabilityReplica $PrimaryReplica
        } else {
            Write-Host "PowerShell cmdlets available but SeedingMode not supported - using T-SQL..."
            $createAgSql = 'CREATE AVAILABILITY GROUP [' + $AvailabilityGroupName + '] WITH (AUTOMATED_BACKUP_PREFERENCE = SECONDARY, DB_FAILOVER = OFF, CLUSTER_TYPE = WSFC) FOR REPLICA ON N''' + $SqlInstance + ''' WITH (ENDPOINT_URL = N''' + $endpointUrl + ''', AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = AUTOMATIC, SEEDING_MODE = AUTOMATIC, SECONDARY_ROLE(ALLOW_CONNECTIONS = ALL));'
            Write-Host "Running: $createAgSql"
            Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $createAgSql @sqlParams -ErrorAction Stop
        }
    } else {
        Write-Host "PowerShell AG cmdlets not available, using T-SQL..."
        $createAgSql = 'CREATE AVAILABILITY GROUP [' + $AvailabilityGroupName + '] WITH (AUTOMATED_BACKUP_PREFERENCE = SECONDARY, DB_FAILOVER = OFF, CLUSTER_TYPE = WSFC) FOR REPLICA ON N''' + $SqlInstance + ''' WITH (ENDPOINT_URL = N''' + $endpointUrl + ''', AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = AUTOMATIC, SEEDING_MODE = AUTOMATIC, SECONDARY_ROLE(ALLOW_CONNECTIONS = ALL));'
        Write-Host "Running: $createAgSql"
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $createAgSql @sqlParams -ErrorAction Stop
    }

    Write-Host "Availability Group $AvailabilityGroupName created successfully."

    # Verify
    $verify = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "SELECT name, primary_replica FROM sys.dm_hadr_availability_group_states" @sqlParams -ErrorAction SilentlyContinue
    if ($verify) {
        Write-Host "Verified AG: $($verify.name), Primary: $($verify.primary_replica)"
    }

    Write-Host "=== Create-AG completed ==="
}
catch {
    Write-Error "Create-AG FAILED: $_"
    throw $_
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
