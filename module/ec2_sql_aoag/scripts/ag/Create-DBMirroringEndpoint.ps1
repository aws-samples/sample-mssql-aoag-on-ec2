# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

<#
.SYNOPSIS
    Creates the database mirroring endpoint for Always On AG on the primary replica.
.DESCRIPTION
    Idempotent - checks if endpoint already exists before creating.
    Uses -TrustServerCertificate for SqlServer module v22+ compatibility.
    Grants CONNECT to SQL service account for AG replication.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SQLInstanceName,
    [Parameter(Mandatory=$false)][int]$EndpointPort = 5022
)
$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\aoag\log\Create-DBMirroringEndpoint.log -Append
try {
    Write-Host "=== Create-DBMirroringEndpoint (Primary) ==="
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"

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

    # Build instance name with single-quote concat
    if ($SQLInstanceName -eq 'MSSQLSERVER' -or $SQLInstanceName -eq 'DEFAULT') {
        $SqlInstance = $env:COMPUTERNAME
    } else {
        $SqlInstance = $env:COMPUTERNAME + '\' + $SQLInstanceName
    }
    Write-Host "SQL Instance: $SqlInstance"

    # Check if endpoint already exists
    $query = "SELECT e.name, e.state_desc, t.port FROM sys.endpoints e LEFT JOIN sys.tcp_endpoints t ON e.endpoint_id = t.endpoint_id WHERE e.type_desc = 'DATABASE_MIRRORING'"
    $result = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $query @sqlParams -ErrorAction Stop

    if ($result) {
        Write-Host "Database mirroring endpoint already exists: $($result.name) (State: $($result.state_desc), Port: $($result.port))"
    } else {
        Write-Host "Creating database mirroring endpoint on port $EndpointPort..."
        $createEndpoint = @"
CREATE ENDPOINT [Hadr_endpoint]
    STATE = STARTED
    AS TCP (LISTENER_PORT = $EndpointPort)
    FOR DATABASE_MIRRORING (
        ROLE = ALL,
        AUTHENTICATION = WINDOWS NEGOTIATE,
        ENCRYPTION = REQUIRED ALGORITHM AES
    )
"@
        Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $createEndpoint @sqlParams -ErrorAction Stop
        Write-Host "Endpoint created successfully."

        # Verify
        $verify = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "SELECT e.name, e.state_desc, t.port FROM sys.endpoints e LEFT JOIN sys.tcp_endpoints t ON e.endpoint_id = t.endpoint_id WHERE e.type_desc = 'DATABASE_MIRRORING'" @sqlParams -ErrorAction SilentlyContinue
        if ($verify) {
            Write-Host "Verified: $($verify.name) State=$($verify.state_desc) Port=$($verify.port)"
        }
    }

    # Grant CONNECT on endpoint to SQL service account
    # The service account runs SQL Server but may not have a SQL login yet.
    # We must create the login first, then grant CONNECT on the endpoint.
    try {
        $svcName = 'MSSQL$' + $SQLInstanceName
        $svcAcct = (Get-WmiObject Win32_Service -Filter "Name='$svcName'" -ErrorAction SilentlyContinue).StartName
        if ($svcAcct -and $svcAcct -ne 'LocalSystem' -and $svcAcct -ne 'NT AUTHORITY\SYSTEM') {
            $loginName = $svcAcct
            Write-Host "SQL service account: $loginName"

            # Create login if it does not exist
            $createLoginQuery = "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$loginName') BEGIN CREATE LOGIN [$loginName] FROM WINDOWS; PRINT 'Login created'; END ELSE BEGIN PRINT 'Login already exists'; END"
            Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $createLoginQuery @sqlParams -ErrorAction Stop

            # Grant CONNECT on endpoint
            Write-Host "Granting CONNECT on Hadr_endpoint to [$loginName]..."
            $grantQuery = "IF NOT EXISTS (SELECT 1 FROM sys.server_permissions sp JOIN sys.server_principals p ON sp.grantee_principal_id = p.principal_id JOIN sys.endpoints e ON sp.major_id = e.endpoint_id WHERE e.name = 'Hadr_endpoint' AND p.name = '$loginName' AND sp.permission_name = 'CONNECT') BEGIN GRANT CONNECT ON ENDPOINT::Hadr_endpoint TO [$loginName]; END"
            Invoke-Sqlcmd -ServerInstance $SqlInstance -Query $grantQuery @sqlParams -ErrorAction Stop
            Write-Host "CONNECT granted to [$loginName]."
        } else {
            Write-Host "SQL runs as $svcAcct - CONNECT grant not needed."
        }
    } catch {
        Write-Host "WARNING: CONNECT grant failed (non-fatal): $($_.Exception.Message)"
    }

    Write-Host "=== Create-DBMirroringEndpoint completed ==="
}
catch {
    Write-Error "Create-DBMirroringEndpoint FAILED: $_"
    throw $_
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
