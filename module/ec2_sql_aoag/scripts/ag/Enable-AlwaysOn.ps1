# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

<#
.SYNOPSIS
    Enables SQL Server Always On (HADR) on the local node.
.DESCRIPTION
    Works for both primary and secondary replicas.
    Tries Enable-SqlAlwaysOn cmdlet first, falls back to registry.
    SQL 2022 uses HADR\HADR_Enabled subkey (not just HadrEnabled).
    Uses sc.exe for restart (Stop-Service fails under SSM SYSTEM context).
    Must stop SQL Agent before SQL Server (dependent service blocks sc.exe stop).
    Detects partial enablement: HADR enabled via registry but WSFC integration
    incomplete (missing HadrAgNameToIdMap). Re-runs cmdlet in that case.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SQLInstanceName,
    [Parameter(Mandatory=$false)][ValidateSet('Primary','Secondary')][string]$Role = 'Primary'
)
$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\aoag\log\Enable-AlwaysOn.log -Append
try {
    Write-Host "=== Enable-AlwaysOn: $Role replica ==="
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"

    # Load SQL module
    $sqlMod = Get-Module -Name SqlServer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
    if ($sqlMod) { Import-Module SqlServer -Force; Write-Host "SqlServer module: v$($sqlMod.Version)" }
    else { Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue; Write-Host "WARNING: Using legacy SQLPS" }

    # Verify WSFC membership
    Write-Host "Checking WSFC cluster membership..."
    try { $cluster = Get-Cluster -ErrorAction Stop; Write-Host "Cluster: $($cluster.Name)" }
    catch { throw "Not a WSFC member. Error: $($_.Exception.Message)" }

    # Resolve names using single-quote concat (avoids backtick encoding issues on S3)
    if ($SQLInstanceName -eq 'MSSQLSERVER' -or $SQLInstanceName -eq 'DEFAULT') {
        $ServiceName = 'MSSQLSERVER'
        $AgentService = 'SQLSERVERAGENT'
        $SqlInstance = $env:COMPUTERNAME
    } else {
        $ServiceName = 'MSSQL$' + $SQLInstanceName
        $AgentService = 'SQLAgent$' + $SQLInstanceName
        $SqlInstance = $env:COMPUTERNAME + '\' + $SQLInstanceName
    }
    Write-Host "SQL Instance: $SqlInstance"
    Write-Host "Service Name: $ServiceName"
    Write-Host "Agent Service: $AgentService"

    # Log PID before any restart
    $svcBefore = Get-WmiObject Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
    $pidBefore = if ($svcBefore) { $svcBefore.ProcessId } else { 0 }
    Write-Host "SQL Server PID before: $pidBefore"

    # =========================================================================
    # WSFC Integration Check Function
    # Verifies that Enable-SqlAlwaysOn cmdlet ran successfully (not just registry).
    # The cmdlet creates HadrAgNameToIdMap in the WSFC cluster registry hive
    # (mounted at HKLM:\Cluster on cluster nodes). Without this key,
    # New-SqlAvailabilityGroup fails with error 41030.
    # =========================================================================
    function Test-WsfcHadrIntegration {
        Write-Host "--- Checking WSFC HADR Integration ---"
        $result = @{ Complete = $true; Details = @() }

        # Check 1: HadrAgNameToIdMap cluster registry key
        $hadrMapKey = 'HKLM:\Cluster\HadrAgNameToIdMap'
        if (Test-Path $hadrMapKey) {
            Write-Host "WSFC Check 1: HadrAgNameToIdMap key EXISTS"
        } else {
            Write-Host "WSFC Check 1: HadrAgNameToIdMap key MISSING"
            $result.Complete = $false
            $result.Details += 'HadrAgNameToIdMap missing'
        }

        # Check 2: AG resource type registered
        try {
            Import-Module FailoverClusters -ErrorAction Stop
            $agResType = Get-ClusterResourceType -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'SQL Server Availability Group' }
            if ($agResType) {
                Write-Host "WSFC Check 2: AG resource type registered"
            } else {
                Write-Host "WSFC Check 2: AG resource type NOT registered"
                $result.Complete = $false
                $result.Details += 'AG resource type not registered'
            }
        } catch {
            Write-Host "WSFC Check 2: FailoverClusters module error: $($_.Exception.Message)"
            $result.Complete = $false
            $result.Details += 'FailoverClusters module error'
        }

        Write-Host "WSFC Integration: $(if ($result.Complete) { 'COMPLETE' } else { 'INCOMPLETE - ' + ($result.Details -join ', ') })"
        return $result
    }

    # =========================================================================
    # Idempotency Check
    # If HADR is enabled AND WSFC integration is complete, skip everything.
    # If HADR is enabled but WSFC integration is incomplete (partial state),
    # re-run the cmdlet to fix it.
    # =========================================================================
    Write-Host "Checking if HADR is already enabled..."
    $hadrAlreadyEnabled = $false
    $partialEnablement = $false
    try {
        [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.Smo') | Out-Null
        $smo = New-Object Microsoft.SqlServer.Management.Smo.Server($SqlInstance)
        $smo.ConnectionContext.ConnectTimeout = 30
        if ($smo.IsHadrEnabled) {
            Write-Host "SMO reports IsHadrEnabled=True"
            # HADR is enabled at SQL level - but is WSFC integration complete?
            $wsfcCheck = Test-WsfcHadrIntegration
            if ($wsfcCheck.Complete) {
                Write-Host "HADR fully enabled with WSFC integration - nothing to do."
                $hadrAlreadyEnabled = $true
            } else {
                Write-Host "PARTIAL ENABLEMENT DETECTED: HADR enabled via registry but WSFC integration incomplete."
                Write-Host "This happens when Enable-SqlAlwaysOn cmdlet never ran successfully (e.g., CONN/MOF missing)."
                Write-Host "Will attempt to re-run Enable-SqlAlwaysOn cmdlet to fix WSFC integration."
                $partialEnablement = $true
            }
        } else {
            Write-Host "HADR is NOT enabled. Proceeding with enablement..."
        }
    } catch {
        Write-Host "WARNING: SMO check failed (SQL may not be running yet): $($_.Exception.Message)"
        Write-Host "Proceeding with enablement..."
    }

    if (-not $hadrAlreadyEnabled) {
        # =================================================================
        # WMI Provider Repair
        # After uninstall/reinstall, Enable-SqlAlwaysOn can fail with empty
        # WMI error. Re-register the MOF file from shared components path.
        # =================================================================
        Write-Host "--- WMI Provider Repair ---"
        $mofFile = $null

        # Method A: Use cmd dir /s /b (more reliable under SYSTEM context than Get-ChildItem)
        $mofSearchRoots = @(
            'C:\Program Files\Microsoft SQL Server',
            'C:\Program Files (x86)\Microsoft SQL Server',
            'E:\SQL\MSSQL',
            'E:\SQL'
        )
        foreach ($searchRoot in $mofSearchRoots) {
            if (Test-Path $searchRoot) {
                Write-Host "Searching for MOF in: $searchRoot"
                try {
                    $prevEAP = $ErrorActionPreference
                    $ErrorActionPreference = 'SilentlyContinue'
                    $dirResult = cmd.exe /c "dir /s /b `"$searchRoot\sqlmgmproviderxpsp2up.mof`" 2>nul"
                    $ErrorActionPreference = $prevEAP
                    if ($dirResult) {
                        $mofFile = ($dirResult -split "`n" | Select-Object -First 1).Trim()
                        if ($mofFile -and (Test-Path $mofFile)) {
                            Write-Host "Found via dir: $mofFile"
                            break
                        }
                        $mofFile = $null
                    }
                } catch { $ErrorActionPreference = $prevEAP }
            }
        }

        # Method B: Fallback - check well-known version paths directly
        # Includes AMI default instance paths (MSSQL16.MSSQLSERVER) since SQL 2022
        # removed CONN as a feature - shared components come from the pre-installed default instance.
        if (-not $mofFile) {
            $knownPaths = @(
                'C:\Program Files\Microsoft SQL Server\160\Shared\sqlmgmproviderxpsp2up.mof',
                'C:\Program Files\Microsoft SQL Server\150\Shared\sqlmgmproviderxpsp2up.mof',
                'C:\Program Files\Microsoft SQL Server\140\Shared\sqlmgmproviderxpsp2up.mof',
                'C:\Program Files\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQL\Binn\sqlmgmproviderxpsp2up.mof',
                ('C:\Program Files\Microsoft SQL Server\MSSQL16.' + $SQLInstanceName + '\MSSQL\Binn\sqlmgmproviderxpsp2up.mof'),
                ('E:\SQL\MSSQL\MSSQL16.' + $SQLInstanceName + '\MSSQL\Binn\sqlmgmproviderxpsp2up.mof')
            )
            foreach ($kp in $knownPaths) {
                if (Test-Path $kp) {
                    $mofFile = $kp
                    Write-Host "Found at known path: $mofFile"
                    break
                }
            }
        }

        if ($mofFile) {
            Write-Host "Re-registering WMI provider with: $mofFile"
            $mofResult = & mofcomp.exe $mofFile 2>&1
            Write-Host "mofcomp result: $mofResult"
        } else {
            # MOF not found - SQL 2022 removed CONN feature; MOF should come from AMI default instance
            $mofError = 'sqlmgmproviderxpsp2up.mof not found. '
            $mofError = $mofError + 'SQL 2022 removed CONN as a feature. The WMI provider MOF should exist from the AMI default instance. '
            $mofError = $mofError + 'Verify the AMI has SQL Server pre-installed and the default instance was not uninstalled.'
            if ($partialEnablement) {
                # On re-enablement path, MOF is required - throw
                throw $mofError
            } else {
                # On fresh enablement, log error but continue to Method 3 as last resort
                Write-Host "ERROR: $mofError"
            }
        }

        # =================================================================
        # Pre-check: ensure SQL Server is running before cmdlet attempt.
        # Restart it cleanly so the cmdlet gets a fresh process state.
        # =================================================================
        Write-Host "--- Pre-cmdlet: Verifying SQL Server is running ---"
        Write-Host "SQLInstanceName parameter: $SQLInstanceName"
        Write-Host "Resolved SqlInstance: $SqlInstance"
        Write-Host "Resolved ServiceName: $ServiceName"
        Write-Host "Resolved AgentService: $AgentService"
        Write-Host "COMPUTERNAME: $env:COMPUTERNAME"

        $preSvcStatus = (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue).Status
        Write-Host "SQL Server service status: $preSvcStatus"
        if ($preSvcStatus -ne 'Running') {
            Write-Host "SQL Server not running - starting it..."
            sc.exe start $ServiceName | ForEach-Object { Write-Host $_ }
            $preWait = 0
            while ($preWait -lt 90) {
                Start-Sleep -Seconds 5
                $preWait += 5
                $preStatus = (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue).Status
                if ($preStatus -eq 'Running') { Write-Host "SQL Server running after $preWait seconds."; break }
                Write-Host "Waiting for SQL to start... ($preWait s) Status: $preStatus"
            }
            Start-Sleep -Seconds 15
        }

        # Quick connectivity test before cmdlet
        Write-Host "Testing SQL connectivity to: $SqlInstance"
        try {
            # SECURITY NOTE: TrustServerCertificate = $true below disables TLS
            # certificate validation - the connection is still encrypted, but the
            # client accepts any certificate the server presents, so an attacker
            # on the network path could intercept or modify SQL traffic without
            # detection.
            #
            # It is set here because SQL Server presents a self-signed certificate
            # until one is provisioned, which is the case during this bootstrap.
            # It is NOT appropriate for production: install a CA-issued
            # certificate on each SQL Server instance, then remove this block so
            # validation applies.
            # See: https://learn.microsoft.com/sql/database-engine/configure-windows/configure-sql-server-encryption
            $trustParam = @{}
            $cmdInfo2 = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue
            if ($cmdInfo2 -and $cmdInfo2.Parameters.ContainsKey('TrustServerCertificate')) {
                $trustParam['TrustServerCertificate'] = $true
            }
            $connTest = Invoke-Sqlcmd -ServerInstance $SqlInstance -Query "SELECT @@SERVERNAME AS SN, @@VERSION AS V" @trustParam -ErrorAction Stop
            Write-Host "SQL connectivity OK: $($connTest.SN)"
        } catch {
            Write-Host "WARNING: SQL connectivity test failed: $($_.Exception.Message)"
        }

        # =================================================================
        # Method 1: Enable-SqlAlwaysOn -ServerInstance (preferred)
        # =================================================================
        $enabledByCmdlet = $false
        Write-Host "--- Method 1: Enable-SqlAlwaysOn -ServerInstance '$SqlInstance' ---"
        try {
            Enable-SqlAlwaysOn -ServerInstance $SqlInstance -NoServiceRestart -Force -ErrorAction Stop
            Write-Host "Method 1 succeeded."
            $enabledByCmdlet = $true
        } catch {
            Write-Host "Method 1 failed: $($_.Exception.Message)"
        }

        # =================================================================
        # Method 2: Enable-SqlAlwaysOn -Path (alternate syntax)
        # =================================================================
        if (-not $enabledByCmdlet) {
            $sqlPath = 'SQLSERVER:\SQL\' + $env:COMPUTERNAME + '\' + $SQLInstanceName
            Write-Host "--- Method 2: Enable-SqlAlwaysOn -Path '$sqlPath' ---"
            try {
                Enable-SqlAlwaysOn -Path $sqlPath -NoServiceRestart -Force -ErrorAction Stop
                Write-Host "Method 2 succeeded."
                $enabledByCmdlet = $true
            } catch {
                Write-Host "Method 2 failed: $($_.Exception.Message)"
            }
        }

        # =================================================================
        # Method 3: Registry Fallback
        # ONLY used on fresh enablement (not partial re-enablement).
        # Registry fallback does NOT create WSFC HadrAgNameToIdMap key,
        # so using it on partial state would leave us in the same broken state.
        # =================================================================
        if (-not $enabledByCmdlet -and -not $partialEnablement) {
            Write-Host "--- Method 3: Registry Fallback ---"
            $regBase = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'

            # Find the instance registry key (e.g., MSSQL16.<InstanceName>)
            $instanceRegName = $null
            try {
                $instNames = (Get-ItemProperty "$regBase\Instance Names\SQL" -ErrorAction Stop)
                $instanceRegName = $instNames.$SQLInstanceName
                Write-Host "Instance registry name: $instanceRegName"
            } catch {
                # Fallback: try common patterns
                $patterns = @("MSSQL16.$SQLInstanceName", "MSSQL15.$SQLInstanceName", "MSSQL14.$SQLInstanceName")
                foreach ($p in $patterns) {
                    if (Test-Path "$regBase\$p\MSSQLServer") {
                        $instanceRegName = $p
                        Write-Host "Found instance via pattern: $instanceRegName"
                        break
                    }
                }
            }

            if (-not $instanceRegName) {
                throw "Cannot find SQL Server instance registry key for $SQLInstanceName"
            }

            $mssqlServerPath = "$regBase\$instanceRegName\MSSQLServer"
            $hadrSubkeyPath = "$mssqlServerPath\HADR"

            # Set legacy HadrEnabled value (parent key)
            Write-Host "Setting $mssqlServerPath\HadrEnabled = 1"
            Set-ItemProperty -Path $mssqlServerPath -Name 'HadrEnabled' -Value 1 -Type DWord -Force

            # Set SQL 2022 HADR\HADR_Enabled value (subkey)
            if (-not (Test-Path $hadrSubkeyPath)) {
                Write-Host "Creating HADR subkey..."
                New-Item -Path $hadrSubkeyPath -Force | Out-Null
            }
            Write-Host "Setting $hadrSubkeyPath\HADR_Enabled = 1"
            Set-ItemProperty -Path $hadrSubkeyPath -Name 'HADR_Enabled' -Value 1 -Type DWord -Force

            # Verify both values
            $val1 = (Get-ItemProperty -Path $mssqlServerPath -Name 'HadrEnabled' -ErrorAction SilentlyContinue).HadrEnabled
            $val2 = (Get-ItemProperty -Path $hadrSubkeyPath -Name 'HADR_Enabled' -ErrorAction SilentlyContinue).HADR_Enabled
            Write-Host "Verification - HadrEnabled: $val1, HADR\HADR_Enabled: $val2"

            if ($val1 -ne 1 -or $val2 -ne 1) {
                throw "Registry values not set correctly. HadrEnabled=$val1, HADR_Enabled=$val2"
            }
            Write-Host "Method 3 (registry) succeeded."
        } elseif (-not $enabledByCmdlet -and $partialEnablement) {
            # Partial re-enablement: cmdlet failed and we cannot use registry fallback
            throw ('Enable-SqlAlwaysOn cmdlet failed on partial re-enablement. ' +
                   'WSFC integration requires the cmdlet - registry fallback cannot create HadrAgNameToIdMap. ' +
                   'Check that CONN feature is installed (sqlmgmproviderxpsp2up.mof must exist on disk).')
        }

        # =================================================================
        # Register AG cluster resource type (needed when using registry fallback)
        # Enable-SqlAlwaysOn cmdlet does this automatically, but Method 3 does not.
        # Without this, CREATE AVAILABILITY GROUP fails with error 41105.
        # =================================================================
        Write-Host "--- Registering AG Cluster Resource Type ---"
        try {
            Import-Module FailoverClusters -ErrorAction Stop
            $existingType = Get-ClusterResourceType -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'SQL Server Availability Group' }
            if ($existingType) {
                Write-Host "AG resource type already registered."
            } else {
                $sqlBinPath = $null
                $regBase = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
                $instNames = (Get-ItemProperty "$regBase\Instance Names\SQL" -ErrorAction SilentlyContinue)
                $instRegName = $instNames.$SQLInstanceName
                if ($instRegName) {
                    $sqlBinPath = (Get-ItemProperty "$regBase\$instRegName\Setup" -ErrorAction SilentlyContinue).SQLBinRoot
                }
                if (-not $sqlBinPath) { $sqlBinPath = 'E:\SQL\MSSQL\MSSQL16.' + $SQLInstanceName + '\MSSQL\Binn' }
                $hadrDll = Join-Path $sqlBinPath 'hadrres.dll'
                if (Test-Path $hadrDll) {
                    Write-Host "Registering AG resource type with: $hadrDll"
                    Add-ClusterResourceType -Name 'SQL Server Availability Group' -Dll $hadrDll -DisplayName 'SQL Server Availability Group' -ErrorAction Stop
                    Write-Host "AG resource type registered successfully."
                } else {
                    Write-Host "WARNING: hadrres.dll not found at $hadrDll - AG creation may fail with error 41105"
                }
            }
        } catch {
            Write-Host "WARNING: AG resource type registration failed (non-fatal): $($_.Exception.Message)"
        }

        # =================================================================
        # Restart SQL Server via sc.exe
        # Stop-Service/Start-Service silently fails under SSM SYSTEM context.
        # Must stop SQL Agent first (dependent service blocks sc.exe stop).
        # =================================================================
        Write-Host "--- Restarting SQL Server via sc.exe ---"

        # Stop SQL Agent first (dependent service)
        $agentSvc = Get-Service -Name $AgentService -ErrorAction SilentlyContinue
        if ($agentSvc -and $agentSvc.Status -eq 'Running') {
            Write-Host "Stopping SQL Agent: $AgentService"
            sc.exe stop $AgentService | ForEach-Object { Write-Host $_ }
            $agentWait = 0
            while ($agentWait -lt 60) {
                Start-Sleep -Seconds 3
                $agentWait += 3
                $agentStatus = (Get-Service -Name $AgentService -ErrorAction SilentlyContinue).Status
                if ($agentStatus -eq 'Stopped') { Write-Host "SQL Agent stopped."; break }
                Write-Host "Waiting for Agent to stop... ($agentWait s) Status: $agentStatus"
            }
        } else {
            Write-Host "SQL Agent not running or not found - skipping agent stop."
        }

        # Stop SQL Server
        Write-Host "Stopping SQL Server: $ServiceName"
        sc.exe stop $ServiceName | ForEach-Object { Write-Host $_ }
        $stopWait = 0
        while ($stopWait -lt 120) {
            Start-Sleep -Seconds 5
            $stopWait += 5
            $svcStatus = (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue).Status
            if ($svcStatus -eq 'Stopped') { Write-Host "SQL Server stopped after $stopWait seconds."; break }
            Write-Host "Waiting for SQL to stop... ($stopWait s) Status: $svcStatus"
        }

        # Verify stopped
        $finalStopStatus = (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue).Status
        if ($finalStopStatus -ne 'Stopped') {
            Write-Host "WARNING: SQL Server not stopped (Status: $finalStopStatus). Attempting taskkill..."
            $svcObj = Get-WmiObject Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
            if ($svcObj -and $svcObj.ProcessId -gt 0) {
                taskkill /PID $svcObj.ProcessId /F 2>&1 | ForEach-Object { Write-Host $_ }
                Start-Sleep -Seconds 10
            }
        }

        # Start SQL Server
        Write-Host "Starting SQL Server: $ServiceName"
        sc.exe start $ServiceName | ForEach-Object { Write-Host $_ }
        $startWait = 0
        while ($startWait -lt 120) {
            Start-Sleep -Seconds 5
            $startWait += 5
            $svcStatus = (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue).Status
            if ($svcStatus -eq 'Running') { Write-Host "SQL Server running after $startWait seconds."; break }
            Write-Host "Waiting for SQL to start... ($startWait s) Status: $svcStatus"
        }

        # Verify PID changed (proves restart actually happened)
        $svcAfter = Get-WmiObject Win32_Service -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
        $pidAfter = if ($svcAfter) { $svcAfter.ProcessId } else { 0 }
        Write-Host "SQL Server PID after: $pidAfter (was: $pidBefore)"
        if ($pidAfter -eq $pidBefore -and $pidBefore -ne 0) {
            Write-Host "WARNING: PID unchanged - restart may not have occurred."
        }

        # Start SQL Agent back up
        $agentSvc = Get-Service -Name $AgentService -ErrorAction SilentlyContinue
        if ($agentSvc) {
            Write-Host "Starting SQL Agent: $AgentService"
            sc.exe start $AgentService | ForEach-Object { Write-Host $_ }
            Start-Sleep -Seconds 10
        }

        # Wait for SQL to be fully ready
        Write-Host "Waiting 30 seconds for SQL Server to fully initialize..."
        Start-Sleep -Seconds 30

        # =================================================================
        # Verification via SMO
        # =================================================================
        Write-Host "--- Verifying HADR status via SMO ---"
        try {
            [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.Smo') | Out-Null
            $smo = New-Object Microsoft.SqlServer.Management.Smo.Server($SqlInstance)
            $smo.ConnectionContext.ConnectTimeout = 30
            $isEnabled = $smo.IsHadrEnabled
            Write-Host "IsHadrEnabled: $isEnabled"

            if (-not $isEnabled) {
                Write-Host "ERROR: HADR still not enabled after all methods."
                # Diagnostic info
                Write-Host "--- Diagnostic Info ---"
                $regBase = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
                $instNames = (Get-ItemProperty "$regBase\Instance Names\SQL" -ErrorAction SilentlyContinue)
                $instanceRegName = $instNames.$SQLInstanceName
                if ($instanceRegName) {
                    $mssqlServerPath = "$regBase\$instanceRegName\MSSQLServer"
                    $hadrSubkeyPath = "$mssqlServerPath\HADR"
                    $val1 = (Get-ItemProperty -Path $mssqlServerPath -Name 'HadrEnabled' -ErrorAction SilentlyContinue).HadrEnabled
                    $val2 = (Get-ItemProperty -Path $hadrSubkeyPath -Name 'HADR_Enabled' -ErrorAction SilentlyContinue).HADR_Enabled
                    Write-Host "Registry HadrEnabled: $val1"
                    Write-Host "Registry HADR\HADR_Enabled: $val2"
                }
                try {
                    $clusterState = Get-Cluster -ErrorAction Stop
                    Write-Host "Cluster: $($clusterState.Name)"
                    Get-ClusterNode -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  Node: $($_.Name) State: $($_.State)" }
                } catch {
                    Write-Host "Cluster check failed: $($_.Exception.Message)"
                }
                throw "HADR enablement failed - IsHadrEnabled is False after restart."
            }
        } catch {
            if ($_.Exception.Message -match 'HADR enablement failed') { throw }
            Write-Host "WARNING: SMO verification failed: $($_.Exception.Message)"
            Write-Host "Falling back to sqlcmd verification..."
            try {
                $result = sqlcmd -S $SqlInstance -E -Q "SELECT SERVERPROPERTY('IsHadrEnabled') AS IsHadrEnabled" -h -1 -W 2>&1
                Write-Host "sqlcmd IsHadrEnabled: $result"
            } catch {
                Write-Host "sqlcmd also failed: $($_.Exception.Message)"
            }
        }

        # =================================================================
        # Post-enablement WSFC Integration Verification
        # After cmdlet + restart, confirm WSFC integration is complete.
        # This catches the case where cmdlet reported success but WSFC
        # keys were not actually created.
        # =================================================================
        Write-Host "--- Post-enablement WSFC Integration Check ---"
        $postCheck = Test-WsfcHadrIntegration
        if (-not $postCheck.Complete) {
            if ($enabledByCmdlet) {
                Write-Host "WARNING: Enable-SqlAlwaysOn cmdlet succeeded but WSFC integration still incomplete."
                Write-Host "Missing: $($postCheck.Details -join ', ')"
                Write-Host "Create-AG may fail with error 41030. Consider destroy+redeploy if this persists."
            } else {
                Write-Host "NOTE: Registry fallback was used - WSFC integration will be incomplete."
                Write-Host "Missing: $($postCheck.Details -join ', ')"
                Write-Host "Create-AG may fail with error 41030. The Enable-SqlAlwaysOn cmdlet is required for full WSFC integration."
            }
        } else {
            Write-Host "WSFC integration verified: HadrAgNameToIdMap exists, AG resource type registered."
        }
    }

    Write-Host "=== Enable-AlwaysOn completed successfully ==="
}
catch {
    Write-Error "Enable-AlwaysOn FAILED: $_"
    Write-Host "Exception: $($_.Exception.Message)"
    Write-Host "Stack: $($_.ScriptStackTrace)"
    throw $_
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
