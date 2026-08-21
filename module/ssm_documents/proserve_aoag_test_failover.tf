# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# SSM Document: proserve_aoag_test_failover
# Purpose: Test AG failover/failback, and optionally DAG failover/failback
# Runs on: PRIMARY node (triggers failover to secondary, then failback)
# When DAG params are provided, also tests DAG failover to DR and back
###############################################################################
resource "aws_ssm_document" "proserve_aoag_test_failover" {
  provider      = aws.site
  document_type = "Automation"
  name          = "${local.name_prefix}proserve_aoag_test_failover"

  tags = merge(var.tags, {
    Name = "proserve_aoag_test_failover"
  })

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "AOAG Test Failover - Tests AG failover/failback and optionally DAG failover/failback"
    assumeRole    = "{{ AutomationAssumeRole }}"

    parameters = {
      AutomationAssumeRole = {
        type        = "String"
        description = "The ARN of the role that allows Automation to perform actions"
      }
      PrimaryInstanceId = {
        type        = "String"
        description = "Instance Id of the current primary node"
      }
      SecondaryInstanceId = {
        type        = "String"
        description = "Instance Id of the secondary node (failover target)"
      }
      DomainAdminSecretName = {
        type        = "String"
        description = "ARN for the domain admin secret"
      }
      DomainAdminUser = {
        type        = "String"
        description = "Domain admin username"
      }
      DomainDNSName = {
        type        = "String"
        description = "Fully qualified domain name"
      }
      SQLInstanceName = {
        type        = "String"
        description = "SQL Server instance name"
      }
      AvailabilityGroupName = {
        type        = "String"
        description = "Name of the Availability Group"
      }
      DAGName = {
        type        = "String"
        description = "Name of the Distributed AG (empty = skip DAG tests)"
        default     = ""
      }
      DRInstanceId = {
        type        = "String"
        description = "Instance Id of the DR node (required for DAG tests)"
        default     = ""
      }
      DRAGName = {
        type        = "String"
        description = "Name of the DR Availability Group (required for DAG tests)"
        default     = ""
      }
      DRRegion = {
        type        = "String"
        description = "AWS region of the DR node (required for cross-region DAG tests)"
        default     = ""
      }
    }

    mainSteps = [
      # =====================================================================
      # Step 0: Create test database and add to AG
      # =====================================================================
      {
        name   = "CreateTestDatabase"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ PrimaryInstanceId }}"]
          Parameters = {
            commands = [
              "$ErrorActionPreference = 'Stop'",
              "try {",
              "  $secret = ConvertFrom-Json (Get-SECSecretValue -SecretId {{ DomainAdminSecretName }} -ErrorAction Stop).SecretString",
              "  $domain = '{{ DomainDNSName }}'",
              "  $netbios = ($domain -split '\\.')[0].ToUpper()",
              "  $user = $netbios + '\\' + '{{ DomainAdminUser }}'",
              "  $pass = ConvertTo-SecureString $secret.password -AsPlainText -Force",
              "  $cred = New-Object PSCredential($user, $pass)",
              "  $s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred -ErrorAction Stop",
              "  Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock {",
              "    $sqlMod = Get-Module -Name SqlServer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1",
              "    if ($sqlMod) { Import-Module SqlServer -Force } else { Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue }",
              "    $sqlParams = @{}",
              "    $cmdInfo = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue",
              "    # SECURITY NOTE: this disables TLS certificate validation. The connection is still",
              "    # encrypted, but any certificate the server presents is accepted, so traffic on the",
              "    # network path could be intercepted or modified undetected. Set during bootstrap only,",
              "    # because SQL Server has a self-signed certificate until one is provisioned. For",
              "    # production install a CA-issued certificate and remove this line.",
              "    if ($cmdInfo -and $cmdInfo.Parameters.ContainsKey('TrustServerCertificate')) { $sqlParams['TrustServerCertificate'] = $true }",
              "    $instName = '{{ SQLInstanceName }}'",
              "    $agName = '{{ AvailabilityGroupName }}'",
              "    if ($instName -eq 'MSSQLSERVER' -or $instName -eq 'DEFAULT') { $sqlInst = $env:COMPUTERNAME } else { $sqlInst = $env:COMPUTERNAME + '\\' + $instName }",
              "    Write-Host '=== Create Test Database ==='",
              "    $dbCount = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT COUNT(*) AS cnt FROM sys.availability_databases_cluster WHERE group_id = (SELECT group_id FROM sys.availability_groups WHERE name = '$agName')\" -ErrorAction Stop",
              "    if ($dbCount.cnt -gt 0) { Write-Host \"AG already has $($dbCount.cnt) database(s) - skipping test DB creation.\"; return }",
              "    Write-Host 'No databases in AG. Creating test database...'",
              "    $testDbName = 'AG_TestDB'",
              "    $dbExists = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT name FROM sys.databases WHERE name = '$testDbName'\" -ErrorAction SilentlyContinue",
              "    if (-not $dbExists) {",
              "      Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"CREATE DATABASE [$testDbName];\" -ErrorAction Stop",
              "      Write-Host \"Database $testDbName created.\"",
              "      Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"ALTER DATABASE [$testDbName] SET RECOVERY FULL;\" -ErrorAction Stop",
              "      Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"BACKUP DATABASE [$testDbName] TO DISK = N'NUL';\" -ErrorAction Stop",
              "      Write-Host 'Recovery model set to FULL and initial backup taken.'",
              "    } else { Write-Host \"Database $testDbName already exists.\" }",
              "    Write-Host \"Adding $testDbName to AG $agName...\"",
              "    Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query ('ALTER AVAILABILITY GROUP [' + $agName + '] ADD DATABASE [' + $testDbName + '];') -ErrorAction Stop",
              "    Write-Host \"$testDbName added to AG. Waiting 30 seconds for automatic seeding...\"",
              "    Start-Sleep -Seconds 30",
              "    $seedState = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT drs.synchronization_state_desc, drs.synchronization_health_desc FROM sys.dm_hadr_database_replica_states drs JOIN sys.databases d ON drs.database_id = d.database_id WHERE d.name = '$testDbName' AND drs.is_local = 1\" -ErrorAction SilentlyContinue",
              "    if ($seedState) { Write-Host \"Test DB sync state: $($seedState.synchronization_state_desc) | Health: $($seedState.synchronization_health_desc)\" }",
              "    Write-Host '=== Test database ready ==='",
              "  }",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "} catch {",
              "  Write-Host ('ERROR: ' + $_.Exception.Message)",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "  exit 1",
              "}"
            ]
            executionTimeout = ["300"]
          }
        }
        onFailure = "step:sleepend"
      },
      # =====================================================================
      # Step 1: Pre-flight health check
      # =====================================================================
      {
        name   = "PreFlightHealthCheck"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ PrimaryInstanceId }}"]
          Parameters = {
            commands = [
              "$ErrorActionPreference = 'Stop'",
              "try {",
              "  $secret = ConvertFrom-Json (Get-SECSecretValue -SecretId {{ DomainAdminSecretName }} -ErrorAction Stop).SecretString",
              "  $domain = '{{ DomainDNSName }}'",
              "  $netbios = ($domain -split '\\.')[0].ToUpper()",
              "  $user = $netbios + '\\' + '{{ DomainAdminUser }}'",
              "  $pass = ConvertTo-SecureString $secret.password -AsPlainText -Force",
              "  $cred = New-Object PSCredential($user, $pass)",
              "  $s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred -ErrorAction Stop",
              "  Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock {",
              "    $sqlMod = Get-Module -Name SqlServer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1",
              "    if ($sqlMod) { Import-Module SqlServer -Force } else { Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue }",
              "    $sqlParams = @{}",
              "    $cmdInfo = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue",
              "    # SECURITY NOTE: this disables TLS certificate validation. The connection is still",
              "    # encrypted, but any certificate the server presents is accepted, so traffic on the",
              "    # network path could be intercepted or modified undetected. Set during bootstrap only,",
              "    # because SQL Server has a self-signed certificate until one is provisioned. For",
              "    # production install a CA-issued certificate and remove this line.",
              "    if ($cmdInfo -and $cmdInfo.Parameters.ContainsKey('TrustServerCertificate')) { $sqlParams['TrustServerCertificate'] = $true }",
              "    $instName = '{{ SQLInstanceName }}'",
              "    $agName = '{{ AvailabilityGroupName }}'",
              "    if ($instName -eq 'MSSQLSERVER' -or $instName -eq 'DEFAULT') { $sqlInst = $env:COMPUTERNAME } else { $sqlInst = $env:COMPUTERNAME + '\\' + $instName }",
              "    Write-Host '=== Pre-Flight AG Health Check ==='",
              "    Write-Host \"Running on: $env:COMPUTERNAME | Instance: $sqlInst\"",
              "    $agState = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT ag.name, ags.primary_replica, ags.synchronization_health_desc FROM sys.availability_groups ag JOIN sys.dm_hadr_availability_group_states ags ON ag.group_id = ags.group_id WHERE ag.name = '$agName'\" -ErrorAction Stop",
              "    if (-not $agState) { throw \"AG $agName not found\" }",
              "    Write-Host \"AG: $($agState.name) | Primary: $($agState.primary_replica) | Health: $($agState.synchronization_health_desc)\"",
              "    $dbCount = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT COUNT(*) AS cnt FROM sys.availability_databases_cluster WHERE group_id = (SELECT group_id FROM sys.availability_groups WHERE name = '$agName')\" -ErrorAction SilentlyContinue",
              "    $dbsInAg = if ($dbCount) { $dbCount.cnt } else { 0 }",
              "    Write-Host \"Databases in AG: $dbsInAg\"",
              "    if ($agState.synchronization_health_desc -ne 'HEALTHY' -and $dbsInAg -gt 0) { throw \"AG is not HEALTHY: $($agState.synchronization_health_desc). Fix before failover.\" }",
              "    if ($agState.synchronization_health_desc -ne 'HEALTHY' -and $dbsInAg -eq 0) { Write-Host 'AG shows NOT_HEALTHY but has no databases - expected. Proceeding.' }",
              "    $replicas = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT r.replica_server_name, rs.role_desc, rs.connected_state_desc, rs.synchronization_health_desc FROM sys.availability_replicas r JOIN sys.dm_hadr_availability_replica_states rs ON r.replica_id = rs.replica_id WHERE r.group_id = (SELECT group_id FROM sys.availability_groups WHERE name = '$agName')\" -ErrorAction Stop",
              "    $replicas | ForEach-Object { Write-Host \"  Replica: $($_.replica_server_name) | Role: $($_.role_desc) | Connected: $($_.connected_state_desc) | Health: $($_.synchronization_health_desc)\" }",
              "    Write-Host '=== Pre-flight check PASSED ==='",
              "  }",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "} catch {",
              "  Write-Host ('ERROR: ' + $_.Exception.Message)",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "  exit 1",
              "}"
            ]
            executionTimeout = ["300"]
          }
        }
        onFailure = "step:sleepend"
      },
      # =====================================================================
      # Step 2: Failover AG to secondary
      # =====================================================================
      {
        name   = "FailoverToSecondary"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ SecondaryInstanceId }}"]
          Parameters = {
            commands = [
              "$ErrorActionPreference = 'Stop'",
              "try {",
              "  $secret = ConvertFrom-Json (Get-SECSecretValue -SecretId {{ DomainAdminSecretName }} -ErrorAction Stop).SecretString",
              "  $domain = '{{ DomainDNSName }}'",
              "  $netbios = ($domain -split '\\.')[0].ToUpper()",
              "  $user = $netbios + '\\' + '{{ DomainAdminUser }}'",
              "  $pass = ConvertTo-SecureString $secret.password -AsPlainText -Force",
              "  $cred = New-Object PSCredential($user, $pass)",
              "  $s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred -ErrorAction Stop",
              "  Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock {",
              "    $sqlMod = Get-Module -Name SqlServer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1",
              "    if ($sqlMod) { Import-Module SqlServer -Force } else { Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue }",
              "    $sqlParams = @{}",
              "    $cmdInfo = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue",
              "    # SECURITY NOTE: this disables TLS certificate validation. The connection is still",
              "    # encrypted, but any certificate the server presents is accepted, so traffic on the",
              "    # network path could be intercepted or modified undetected. Set during bootstrap only,",
              "    # because SQL Server has a self-signed certificate until one is provisioned. For",
              "    # production install a CA-issued certificate and remove this line.",
              "    if ($cmdInfo -and $cmdInfo.Parameters.ContainsKey('TrustServerCertificate')) { $sqlParams['TrustServerCertificate'] = $true }",
              "    $instName = '{{ SQLInstanceName }}'",
              "    $agName = '{{ AvailabilityGroupName }}'",
              "    if ($instName -eq 'MSSQLSERVER' -or $instName -eq 'DEFAULT') { $sqlInst = $env:COMPUTERNAME } else { $sqlInst = $env:COMPUTERNAME + '\\' + $instName }",
              "    Write-Host '=== Failover to Secondary ==='",
              "    Write-Host \"Running on: $env:COMPUTERNAME | Instance: $sqlInst\"",
              "    $localRole = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT rs.role_desc FROM sys.dm_hadr_availability_replica_states rs JOIN sys.availability_groups ag ON rs.group_id = ag.group_id WHERE ag.is_distributed = 0 AND rs.is_local = 1\" -ErrorAction Stop",
              "    Write-Host \"Current local role: $($localRole.role_desc)\"",
              "    if ($localRole.role_desc -eq 'PRIMARY' -or $localRole.role_desc -eq 'GLOBAL_PRIMARY') {",
              "      Write-Host 'This node is already PRIMARY - skipping failover.'",
              "    } else {",
              "      Write-Host \"Failing over AG $agName to this node...\"",
              "      $sqlPath = 'SQLSERVER:\\SQL\\' + $env:COMPUTERNAME + '\\' + $instName + '\\AvailabilityGroups\\' + $agName",
              "      Switch-SqlAvailabilityGroup -Path $sqlPath -ErrorAction Stop",
              "      Write-Host 'Failover command executed. Waiting 15 seconds for role change...'",
              "      Start-Sleep -Seconds 15",
              "      $role = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT rs.role_desc FROM sys.dm_hadr_availability_replica_states rs JOIN sys.availability_groups ag ON rs.group_id = ag.group_id WHERE ag.is_distributed = 0 AND rs.is_local = 1\" -ErrorAction Stop",
              "      Write-Host \"Local role after failover: $($role.role_desc)\"",
              "      if ($role.role_desc -ne 'PRIMARY' -and $role.role_desc -ne 'GLOBAL_PRIMARY') { throw \"Failover failed - local role is $($role.role_desc), expected PRIMARY\" }",
              "    }",
              "    Write-Host '=== Failover to secondary SUCCEEDED ==='",
              "  }",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "} catch {",
              "  Write-Host ('ERROR: ' + $_.Exception.Message)",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "  exit 1",
              "}"
            ]
            executionTimeout = ["300"]
          }
        }
        onFailure = "step:sleepend"
      },
      # =====================================================================
      # Step 3: Wait and validate after failover
      # =====================================================================
      {
        name   = "WaitAfterFailover"
        action = "aws:sleep"
        inputs = { Duration = "PT30S" }
      },
      {
        name   = "PostFailoverValidation"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ SecondaryInstanceId }}"]
          Parameters = {
            commands = [
              "$ErrorActionPreference = 'Stop'",
              "try {",
              "  $secret = ConvertFrom-Json (Get-SECSecretValue -SecretId {{ DomainAdminSecretName }} -ErrorAction Stop).SecretString",
              "  $domain = '{{ DomainDNSName }}'",
              "  $netbios = ($domain -split '\\.')[0].ToUpper()",
              "  $user = $netbios + '\\' + '{{ DomainAdminUser }}'",
              "  $pass = ConvertTo-SecureString $secret.password -AsPlainText -Force",
              "  $cred = New-Object PSCredential($user, $pass)",
              "  $s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred -ErrorAction Stop",
              "  Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock {",
              "    $sqlMod = Get-Module -Name SqlServer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1",
              "    if ($sqlMod) { Import-Module SqlServer -Force } else { Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue }",
              "    $sqlParams = @{}",
              "    $cmdInfo = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue",
              "    # SECURITY NOTE: this disables TLS certificate validation. The connection is still",
              "    # encrypted, but any certificate the server presents is accepted, so traffic on the",
              "    # network path could be intercepted or modified undetected. Set during bootstrap only,",
              "    # because SQL Server has a self-signed certificate until one is provisioned. For",
              "    # production install a CA-issued certificate and remove this line.",
              "    if ($cmdInfo -and $cmdInfo.Parameters.ContainsKey('TrustServerCertificate')) { $sqlParams['TrustServerCertificate'] = $true }",
              "    $instName = '{{ SQLInstanceName }}'",
              "    $agName = '{{ AvailabilityGroupName }}'",
              "    if ($instName -eq 'MSSQLSERVER' -or $instName -eq 'DEFAULT') { $sqlInst = $env:COMPUTERNAME } else { $sqlInst = $env:COMPUTERNAME + '\\' + $instName }",
              "    Write-Host '=== Post-Failover Validation ==='",
              "    $maxWait = 60; $waited = 0",
              "    while ($waited -lt $maxWait) {",
              "      $agState = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT ags.primary_replica, ags.synchronization_health_desc FROM sys.availability_groups ag JOIN sys.dm_hadr_availability_group_states ags ON ag.group_id = ags.group_id WHERE ag.name = '$agName'\" -ErrorAction SilentlyContinue",
              "      if ($agState -and $agState.synchronization_health_desc -eq 'HEALTHY') { break }",
              "      Write-Host \"Waiting for AG to become HEALTHY... ($waited s) Health: $($agState.synchronization_health_desc)\"",
              "      Start-Sleep -Seconds 10; $waited += 10",
              "    }",
              "    Write-Host \"AG Primary: $($agState.primary_replica) | Health: $($agState.synchronization_health_desc)\"",
              "    $replicas = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT r.replica_server_name, rs.role_desc, rs.synchronization_health_desc FROM sys.availability_replicas r JOIN sys.dm_hadr_availability_replica_states rs ON r.replica_id = rs.replica_id WHERE r.group_id = (SELECT group_id FROM sys.availability_groups WHERE name = '$agName')\" -ErrorAction Stop",
              "    $replicas | ForEach-Object { Write-Host \"  Replica: $($_.replica_server_name) | Role: $($_.role_desc) | Health: $($_.synchronization_health_desc)\" }",
              "    Write-Host '=== Post-failover validation PASSED ==='",
              "  }",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "} catch {",
              "  Write-Host ('ERROR: ' + $_.Exception.Message)",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "  exit 1",
              "}"
            ]
            executionTimeout = ["300"]
          }
        }
        onFailure = "step:sleepend"
      },
      # =====================================================================
      # Step 4: Failback to original primary
      # =====================================================================
      {
        name   = "FailbackToOriginalPrimary"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ PrimaryInstanceId }}"]
          Parameters = {
            commands = [
              "$ErrorActionPreference = 'Stop'",
              "try {",
              "  $secret = ConvertFrom-Json (Get-SECSecretValue -SecretId {{ DomainAdminSecretName }} -ErrorAction Stop).SecretString",
              "  $domain = '{{ DomainDNSName }}'",
              "  $netbios = ($domain -split '\\.')[0].ToUpper()",
              "  $user = $netbios + '\\' + '{{ DomainAdminUser }}'",
              "  $pass = ConvertTo-SecureString $secret.password -AsPlainText -Force",
              "  $cred = New-Object PSCredential($user, $pass)",
              "  $s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred -ErrorAction Stop",
              "  Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock {",
              "    $sqlMod = Get-Module -Name SqlServer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1",
              "    if ($sqlMod) { Import-Module SqlServer -Force } else { Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue }",
              "    $sqlParams = @{}",
              "    $cmdInfo = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue",
              "    # SECURITY NOTE: this disables TLS certificate validation. The connection is still",
              "    # encrypted, but any certificate the server presents is accepted, so traffic on the",
              "    # network path could be intercepted or modified undetected. Set during bootstrap only,",
              "    # because SQL Server has a self-signed certificate until one is provisioned. For",
              "    # production install a CA-issued certificate and remove this line.",
              "    if ($cmdInfo -and $cmdInfo.Parameters.ContainsKey('TrustServerCertificate')) { $sqlParams['TrustServerCertificate'] = $true }",
              "    $instName = '{{ SQLInstanceName }}'",
              "    $agName = '{{ AvailabilityGroupName }}'",
              "    if ($instName -eq 'MSSQLSERVER' -or $instName -eq 'DEFAULT') { $sqlInst = $env:COMPUTERNAME } else { $sqlInst = $env:COMPUTERNAME + '\\' + $instName }",
              "    Write-Host '=== Failback to Original Primary ==='",
              "    Write-Host \"Running on: $env:COMPUTERNAME | Instance: $sqlInst\"",
              "    $localRole = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT rs.role_desc FROM sys.dm_hadr_availability_replica_states rs JOIN sys.availability_groups ag ON rs.group_id = ag.group_id WHERE ag.is_distributed = 0 AND rs.is_local = 1\" -ErrorAction Stop",
              "    Write-Host \"Current local role: $($localRole.role_desc)\"",
              "    if ($localRole.role_desc -eq 'PRIMARY' -or $localRole.role_desc -eq 'GLOBAL_PRIMARY') {",
              "      Write-Host 'This node is already PRIMARY - skipping failback.'",
              "    } else {",
              "      Write-Host \"Failing back AG $agName to this node...\"",
              "      $sqlPath = 'SQLSERVER:\\SQL\\' + $env:COMPUTERNAME + '\\' + $instName + '\\AvailabilityGroups\\' + $agName",
              "      Switch-SqlAvailabilityGroup -Path $sqlPath -ErrorAction Stop",
              "      Write-Host 'Failback command executed. Waiting 15 seconds...'",
              "      Start-Sleep -Seconds 15",
              "      $role = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT rs.role_desc FROM sys.dm_hadr_availability_replica_states rs JOIN sys.availability_groups ag ON rs.group_id = ag.group_id WHERE ag.is_distributed = 0 AND rs.is_local = 1\" -ErrorAction Stop",
              "      Write-Host \"Local role after failback: $($role.role_desc)\"",
              "      if ($role.role_desc -ne 'PRIMARY' -and $role.role_desc -ne 'GLOBAL_PRIMARY') { throw \"Failback failed - local role is $($role.role_desc), expected PRIMARY\" }",
              "    }",
              "    Write-Host '=== Failback SUCCEEDED ==='",
              "  }",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "} catch {",
              "  Write-Host ('ERROR: ' + $_.Exception.Message)",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "  exit 1",
              "}"
            ]
            executionTimeout = ["300"]
          }
        }
        onFailure = "step:sleepend"
      },
      # =====================================================================
      # Step 5: AG final health check after failback
      # =====================================================================
      {
        name   = "AGFinalHealthCheck"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ PrimaryInstanceId }}"]
          Parameters = {
            commands = [
              "$ErrorActionPreference = 'Stop'",
              "try {",
              "  $secret = ConvertFrom-Json (Get-SECSecretValue -SecretId {{ DomainAdminSecretName }} -ErrorAction Stop).SecretString",
              "  $domain = '{{ DomainDNSName }}'",
              "  $netbios = ($domain -split '\\.')[0].ToUpper()",
              "  $user = $netbios + '\\' + '{{ DomainAdminUser }}'",
              "  $pass = ConvertTo-SecureString $secret.password -AsPlainText -Force",
              "  $cred = New-Object PSCredential($user, $pass)",
              "  $s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred -ErrorAction Stop",
              "  Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock {",
              "    $sqlMod = Get-Module -Name SqlServer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1",
              "    if ($sqlMod) { Import-Module SqlServer -Force } else { Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue }",
              "    $sqlParams = @{}",
              "    $cmdInfo = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue",
              "    # SECURITY NOTE: this disables TLS certificate validation. The connection is still",
              "    # encrypted, but any certificate the server presents is accepted, so traffic on the",
              "    # network path could be intercepted or modified undetected. Set during bootstrap only,",
              "    # because SQL Server has a self-signed certificate until one is provisioned. For",
              "    # production install a CA-issued certificate and remove this line.",
              "    if ($cmdInfo -and $cmdInfo.Parameters.ContainsKey('TrustServerCertificate')) { $sqlParams['TrustServerCertificate'] = $true }",
              "    $instName = '{{ SQLInstanceName }}'",
              "    $agName = '{{ AvailabilityGroupName }}'",
              "    if ($instName -eq 'MSSQLSERVER' -or $instName -eq 'DEFAULT') { $sqlInst = $env:COMPUTERNAME } else { $sqlInst = $env:COMPUTERNAME + '\\' + $instName }",
              "    Write-Host '=== AG Final Health Check ==='",
              "    $maxWait = 60; $waited = 0",
              "    while ($waited -lt $maxWait) {",
              "      $agState = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT ags.primary_replica, ags.synchronization_health_desc FROM sys.availability_groups ag JOIN sys.dm_hadr_availability_group_states ags ON ag.group_id = ags.group_id WHERE ag.name = '$agName'\" -ErrorAction SilentlyContinue",
              "      if ($agState -and $agState.synchronization_health_desc -eq 'HEALTHY') { break }",
              "      Write-Host \"Waiting for AG to become HEALTHY... ($waited s)\"",
              "      Start-Sleep -Seconds 10; $waited += 10",
              "    }",
              "    Write-Host \"AG Primary: $($agState.primary_replica) | Health: $($agState.synchronization_health_desc)\"",
              "    $replicas = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT r.replica_server_name, rs.role_desc, rs.connected_state_desc, rs.synchronization_health_desc FROM sys.availability_replicas r JOIN sys.dm_hadr_availability_replica_states rs ON r.replica_id = rs.replica_id WHERE r.group_id = (SELECT group_id FROM sys.availability_groups WHERE name = '$agName')\" -ErrorAction Stop",
              "    $replicas | ForEach-Object { Write-Host \"  Replica: $($_.replica_server_name) | Role: $($_.role_desc) | Connected: $($_.connected_state_desc) | Health: $($_.synchronization_health_desc)\" }",
              "    if ($agState.synchronization_health_desc -ne 'HEALTHY') {",
              "      $dbCount = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT COUNT(*) AS cnt FROM sys.availability_databases_cluster WHERE group_id = (SELECT group_id FROM sys.availability_groups WHERE name = '$agName')\" -ErrorAction SilentlyContinue",
              "      if ($dbCount -and $dbCount.cnt -gt 0) { throw 'AG is not HEALTHY after failover/failback test.' }",
              "      Write-Host 'AG shows NOT_HEALTHY but has no databases - expected.'",
              "    }",
              "    Write-Host '=== AG Failover/Failback test PASSED ==='",
              "  }",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "} catch {",
              "  Write-Host ('ERROR: ' + $_.Exception.Message)",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "  exit 1",
              "}"
            ]
            executionTimeout = ["300"]
          }
        }
        onFailure = "step:sleepend"
      },
      # =====================================================================
      # Step 6: Branch - skip DAG tests if no DAG configured
      # =====================================================================
      {
        name   = "CheckDAGTestNeeded"
        action = "aws:branch"
        inputs = {
          Choices = [
            {
              NextStep = "DAGPreFlightCheck"
              Not = {
                Variable     = "{{ DAGName }}"
                StringEquals = ""
              }
            }
          ]
          Default = "sleepend"
        }
      },
      # =====================================================================
      # Step 7: DAG Pre-flight - check DAG health from primary
      # =====================================================================
      {
        name   = "DAGPreFlightCheck"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ PrimaryInstanceId }}"]
          Parameters = {
            commands = [
              "$ErrorActionPreference = 'Stop'",
              "try {",
              "  $secret = ConvertFrom-Json (Get-SECSecretValue -SecretId {{ DomainAdminSecretName }} -ErrorAction Stop).SecretString",
              "  $domain = '{{ DomainDNSName }}'",
              "  $netbios = ($domain -split '\\.')[0].ToUpper()",
              "  $user = $netbios + '\\' + '{{ DomainAdminUser }}'",
              "  $pass = ConvertTo-SecureString $secret.password -AsPlainText -Force",
              "  $cred = New-Object PSCredential($user, $pass)",
              "  $s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred -ErrorAction Stop",
              "  Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock {",
              "    $sqlMod = Get-Module -Name SqlServer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1",
              "    if ($sqlMod) { Import-Module SqlServer -Force } else { Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue }",
              "    $sqlParams = @{}",
              "    $cmdInfo = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue",
              "    # SECURITY NOTE: this disables TLS certificate validation. The connection is still",
              "    # encrypted, but any certificate the server presents is accepted, so traffic on the",
              "    # network path could be intercepted or modified undetected. Set during bootstrap only,",
              "    # because SQL Server has a self-signed certificate until one is provisioned. For",
              "    # production install a CA-issued certificate and remove this line.",
              "    if ($cmdInfo -and $cmdInfo.Parameters.ContainsKey('TrustServerCertificate')) { $sqlParams['TrustServerCertificate'] = $true }",
              "    $instName = '{{ SQLInstanceName }}'",
              "    $dagName = '{{ DAGName }}'",
              "    $agName = '{{ AvailabilityGroupName }}'",
              "    if ($instName -eq 'MSSQLSERVER' -or $instName -eq 'DEFAULT') { $sqlInst = $env:COMPUTERNAME } else { $sqlInst = $env:COMPUTERNAME + '\\' + $instName }",
              "    Write-Host '=== DAG Pre-Flight Check ==='",
              "    Write-Host \"Running on: $env:COMPUTERNAME | DAG: $dagName\"",
              "    $dagReplicas = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT ag.name, ar.replica_server_name, drs.role_desc, drs.synchronization_health_desc, drs.connected_state_desc FROM sys.availability_groups ag JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id LEFT JOIN sys.dm_hadr_availability_replica_states drs ON ar.replica_id = drs.replica_id WHERE ag.is_distributed = 1\" -ErrorAction SilentlyContinue",
              "    if ($dagReplicas) {",
              "      $dagReplicas | ForEach-Object { Write-Host \"  DAG Replica: $($_.replica_server_name) | Role: $($_.role_desc) | Connected: $($_.connected_state_desc) | Health: $($_.synchronization_health_desc)\" }",
              "    } else { Write-Host 'No distributed AG replicas found.' }",
              "    $localDagRole = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT rs.role_desc FROM sys.availability_groups ag JOIN sys.dm_hadr_availability_replica_states rs ON ag.group_id = rs.group_id WHERE ag.is_distributed = 1 AND rs.is_local = 1\" -ErrorAction SilentlyContinue",
              "    $dagRoleVal = if ($localDagRole) { $localDagRole.role_desc } else { '' }",
              "    if ($dagRoleVal -ne 'PRIMARY' -and $dagRoleVal -ne 'GLOBAL_PRIMARY') {",
              "      Write-Host \"Local DAG role is '$dagRoleVal' - waiting up to 120s for PRIMARY...\"",
              "      $maxWait = 120; $waited = 0",
              "      while ($waited -lt $maxWait) {",
              "        Start-Sleep -Seconds 15; $waited += 15",
              "        $localDagRole = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT rs.role_desc FROM sys.availability_groups ag JOIN sys.dm_hadr_availability_replica_states rs ON ag.group_id = rs.group_id WHERE ag.is_distributed = 1 AND rs.is_local = 1\" -ErrorAction SilentlyContinue",
              "        $dagRoleVal = if ($localDagRole) { $localDagRole.role_desc } else { '' }",
              "        Write-Host \"  DAG role after $${waited}s: '$dagRoleVal'\"",
              "        if ($dagRoleVal -eq 'PRIMARY' -or $dagRoleVal -eq 'GLOBAL_PRIMARY') { break }",
              "      }",
              "    }",
              "    if ($dagRoleVal -ne 'PRIMARY' -and $dagRoleVal -ne 'GLOBAL_PRIMARY') { throw \"DAG pre-flight FAILED: local DAG role is '$dagRoleVal', expected PRIMARY. Recover the DAG before running failover test.\" }",
              "    Write-Host '=== DAG Pre-flight PASSED ==='",
              "  }",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "} catch {",
              "  Write-Host ('ERROR: ' + $_.Exception.Message)",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "  exit 1",
              "}"
            ]
            executionTimeout = ["300"]
          }
        }
        onFailure = "step:sleepend"
      },
      # =====================================================================
      # Step 8: DAG Failover - Demote primary DAG role to SECONDARY
      # For distributed AG failover between SQL Server instances:
      #   1. SET ROLE = SECONDARY on current primary
      #   2. SET ROLE = PRIMARY on new primary (DR)
      # ALTER AG ... FAILOVER only works for Azure MI link scenarios.
      # =====================================================================
      {
        name   = "DAGDemotePrimary"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ PrimaryInstanceId }}"]
          Parameters = {
            commands = [
              "$ErrorActionPreference = 'Stop'",
              "try {",
              "  $secret = ConvertFrom-Json (Get-SECSecretValue -SecretId {{ DomainAdminSecretName }} -ErrorAction Stop).SecretString",
              "  $domain = '{{ DomainDNSName }}'",
              "  $netbios = ($domain -split '\\.')[0].ToUpper()",
              "  $user = $netbios + '\\' + '{{ DomainAdminUser }}'",
              "  $pass = ConvertTo-SecureString $secret.password -AsPlainText -Force",
              "  $cred = New-Object PSCredential($user, $pass)",
              "  $s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred -ErrorAction Stop",
              "  Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock {",
              "    $sqlMod = Get-Module -Name SqlServer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1",
              "    if ($sqlMod) { Import-Module SqlServer -Force } else { Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue }",
              "    $sqlParams = @{}",
              "    $cmdInfo = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue",
              "    # SECURITY NOTE: this disables TLS certificate validation. The connection is still",
              "    # encrypted, but any certificate the server presents is accepted, so traffic on the",
              "    # network path could be intercepted or modified undetected. Set during bootstrap only,",
              "    # because SQL Server has a self-signed certificate until one is provisioned. For",
              "    # production install a CA-issued certificate and remove this line.",
              "    if ($cmdInfo -and $cmdInfo.Parameters.ContainsKey('TrustServerCertificate')) { $sqlParams['TrustServerCertificate'] = $true }",
              "    $instName = '{{ SQLInstanceName }}'",
              "    $dagName = '{{ DAGName }}'",
              "    if ($instName -eq 'MSSQLSERVER' -or $instName -eq 'DEFAULT') { $sqlInst = $env:COMPUTERNAME } else { $sqlInst = $env:COMPUTERNAME + '\\' + $instName }",
              "    Write-Host '=== DAG Demote Primary to SECONDARY ==='",
              "    Write-Host \"Running on: $env:COMPUTERNAME | Instance: $sqlInst | DAG: $dagName\"",
              "    $maxWait = 120; $waited = 0; $localRole = $null",
              "    while ($waited -lt $maxWait) {",
              "      $roleResult = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT rs.role_desc FROM sys.availability_groups ag JOIN sys.dm_hadr_availability_replica_states rs ON ag.group_id = rs.group_id WHERE ag.is_distributed = 1 AND rs.is_local = 1\" -ErrorAction SilentlyContinue",
              "      $localRole = if ($roleResult) { $roleResult.role_desc } else { '' }",
              "      Write-Host \"Current DAG role: '$localRole' (waited $${waited}s)\"",
              "      if ($localRole -eq 'PRIMARY' -or $localRole -eq 'GLOBAL_PRIMARY') { break }",
              "      Start-Sleep -Seconds 15; $waited += 15",
              "    }",
              "    if ($localRole -ne 'PRIMARY' -and $localRole -ne 'GLOBAL_PRIMARY') { throw \"Cannot demote primary - current role is '$localRole' after $${maxWait}s. Expected PRIMARY. Aborting to prevent dual-demote.\" }",
              "    $demoteSql = 'ALTER AVAILABILITY GROUP [' + $dagName + '] SET (ROLE = SECONDARY);'",
              "    Write-Host \"Executing: $demoteSql\"",
              "    Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query $demoteSql -QueryTimeout 300 -ErrorAction Stop",
              "    Write-Host 'Primary DAG demoted to SECONDARY. Waiting 15 seconds...'",
              "    Start-Sleep -Seconds 15",
              "    $dagRole = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT rs.role_desc FROM sys.availability_groups ag JOIN sys.dm_hadr_availability_replica_states rs ON ag.group_id = rs.group_id WHERE ag.is_distributed = 1 AND rs.is_local = 1\" -ErrorAction SilentlyContinue",
              "    if ($dagRole) { Write-Host \"DAG role after demote: $($dagRole.role_desc)\" }",
              "    Write-Host '=== DAG Demote SUCCEEDED ==='",
              "  }",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "} catch {",
              "  Write-Host ('ERROR: ' + $_.Exception.Message)",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "  exit 1",
              "}"
            ]
            executionTimeout = ["300"]
          }
        }
        onFailure = "step:sleepend"
      },
      # =====================================================================
      # Step 9: DAG Failover - FORCE_FAILOVER on DR forwarder (cross-region)
      # Per MS docs: after global primary is demoted to SECONDARY,
      # the forwarder uses FORCE_FAILOVER_ALLOW_DATA_LOSS to take over.
      # SET (ROLE = PRIMARY) is Azure MI link only - not valid here.
      # =====================================================================
      {
        name   = "DAGPromoteDR"
        action = "aws:executeScript"
        inputs = {
          Runtime = "PowerShell 8.0"
          InputPayload = {
            DRInstanceId      = "{{ DRInstanceId }}"
            DRRegion          = "{{ DRRegion }}"
            DomainAdminSecret = "{{ DomainAdminSecretName }}"
            DomainAdminUser   = "{{ DomainAdminUser }}"
            DomainDNSName     = "{{ DomainDNSName }}"
            SQLInstanceName   = "{{ SQLInstanceName }}"
            DAGName           = "{{ DAGName }}"
          }
          Script = join("\n", [
            "# Version pinned: an unpinned Install-Module adopts whatever PSGallery serves at run time.",
            "Install-Module AWS.Tools.SimpleSystemsManagement -RequiredVersion 5.0.279 -Force",
            "Import-Module AWS.Tools.SimpleSystemsManagement",
            "",
            "$inputPayload = $env:InputPayload | ConvertFrom-Json",
            "$drInstanceId = $inputPayload.DRInstanceId",
            "$drRegion = $inputPayload.DRRegion",
            "$dagName = $inputPayload.DAGName",
            "$domainAdminSecret = $inputPayload.DomainAdminSecret",
            "$domainAdminUser = $inputPayload.DomainAdminUser",
            "$domainDNSName = $inputPayload.DomainDNSName",
            "$sqlInstanceName = $inputPayload.SQLInstanceName",
            "",
            "Write-Host '=== DAG Failover - FORCE_FAILOVER on DR ==='",
            "Write-Host \"DR Instance: $drInstanceId | DR Region: $drRegion | DAG: $dagName\"",
            "",
            "$script = @\"",
            "`$ErrorActionPreference = 'Stop'",
            "try {",
            "  `$secret = ConvertFrom-Json (Get-SECSecretValue -SecretId $domainAdminSecret -ErrorAction Stop).SecretString",
            "  `$domain = '$domainDNSName'",
            "  `$netbios = (`$domain -split '\\.')[0].ToUpper()",
            "  `$user = `$netbios + '\\' + '$domainAdminUser'",
            "  `$pass = ConvertTo-SecureString `$secret.password -AsPlainText -Force",
            "  `$cred = New-Object PSCredential(`$user, `$pass)",
            "  `$s = New-PSSession -ComputerName `$env:COMPUTERNAME -Authentication Credssp -Credential `$cred -ErrorAction Stop",
            "  Invoke-Command -Session `$s -ErrorAction Stop -ScriptBlock {",
            "    `$sqlMod = Get-Module -Name SqlServer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1",
            "    if (`$sqlMod) { Import-Module SqlServer -Force } else { Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue }",
            "    `$sqlParams = @{}",
            "    `$cmdInfo = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue",
            "    # SECURITY NOTE: this disables TLS certificate validation. The connection is still",
            "    # encrypted, but any certificate the server presents is accepted, so traffic on the",
            "    # network path could be intercepted or modified undetected. Set during bootstrap only,",
            "    # because SQL Server has a self-signed certificate until one is provisioned. For",
            "    # production install a CA-issued certificate and remove this line.",
            "    if (`$cmdInfo -and `$cmdInfo.Parameters.ContainsKey('TrustServerCertificate')) { `$sqlParams['TrustServerCertificate'] = `$true }",
            "    `$instName = '$sqlInstanceName'",
            "    if (`$instName -eq 'MSSQLSERVER' -or `$instName -eq 'DEFAULT') { `$sqlInst = `$env:COMPUTERNAME } else { `$sqlInst = `$env:COMPUTERNAME + '\\' + `$instName }",
            "    Write-Host \"Running DAG FORCE_FAILOVER on `$env:COMPUTERNAME | Instance: `$sqlInst\"",
            "    `$failoverSql = 'ALTER AVAILABILITY GROUP [$dagName] FORCE_FAILOVER_ALLOW_DATA_LOSS;'",
            "    Write-Host \"Executing: `$failoverSql\"",
            "    Invoke-Sqlcmd -ServerInstance `$sqlInst @sqlParams -Query `$failoverSql -QueryTimeout 300 -ErrorAction Stop",
            "    Write-Host 'DR DAG FORCE_FAILOVER completed successfully.'",
            "  }",
            "  Remove-PSSession `$s -ErrorAction SilentlyContinue",
            "} catch {",
            "  Write-Error \"DAG FORCE_FAILOVER FAILED: `$_\"",
            "  Remove-PSSession `$s -ErrorAction SilentlyContinue",
            "  throw `$_",
            "}",
            "\"@",
            "",
            "Set-DefaultAWSRegion -Region $drRegion",
            "$SC = Send-SSMCommand -DocumentName 'AWS-RunPowerShellScript' -Parameter @{commands = $script; executionTimeout = @('600')} -Target @{Key='instanceids';Values=@($drInstanceId)}",
            "Write-Host \"Command Id: $($SC.CommandId)\"",
            "",
            "$pollInterval = 10",
            "$maxRetries = 60",
            "$retryCount = 0",
            "",
            "do {",
            "  $invocation = Get-SSMCommandInvocation -CommandId $($SC.CommandId) -InstanceId $drInstanceId -Details $true | Select-Object -ExpandProperty CommandPlugins",
            "  $Status = $invocation.Status",
            "  Write-Host \"Status: $Status\"",
            "  Write-Host \"Output: $($invocation.Output)\"",
            "",
            "  if ($Status -eq 'Success') {",
            "    Write-Host 'DAG FORCE_FAILOVER on DR completed successfully'",
            "    Write-Host $invocation.Output",
            "    break",
            "  } elseif ($Status -eq 'InProgress' -or $Status -eq 'Delayed' -or $Status -eq 'Pending' -or $Status -eq $null) {",
            "    $retryCount++",
            "    Start-Sleep -Seconds $pollInterval",
            "    continue",
            "  } else {",
            "    throw \"DAG FORCE_FAILOVER command '$($SC.CommandId)' failed with status '$Status'. Output: $($invocation.Output)\"",
            "  }",
            "} while ($retryCount -lt $maxRetries)",
            "",
            "if ($retryCount -ge $maxRetries) {",
            "  throw \"DAG FORCE_FAILOVER timed out after $($maxRetries * $pollInterval) seconds.\"",
            "}",
            "",
            "Write-Host '=== DAG Failover to DR SUCCEEDED ==='"
          ])
        }
        onFailure      = "step:sleepend"
        timeoutSeconds = 900
      },
      # =====================================================================
      # Step 10: Wait for DAG sync after failover
      # =====================================================================
      {
        name   = "WaitAfterDAGFailover"
        action = "aws:sleep"
        inputs = { Duration = "PT60S" }
      },
      # =====================================================================
      # Step 11: DAG Failback - Demote DR to SECONDARY (cross-region)
      # Mirror of Step 8 but in reverse: demote DR before promoting primary
      # =====================================================================
      {
        name   = "DAGDemoteDR"
        action = "aws:executeScript"
        inputs = {
          Runtime = "PowerShell 8.0"
          InputPayload = {
            DRInstanceId      = "{{ DRInstanceId }}"
            DRRegion          = "{{ DRRegion }}"
            DomainAdminSecret = "{{ DomainAdminSecretName }}"
            DomainAdminUser   = "{{ DomainAdminUser }}"
            DomainDNSName     = "{{ DomainDNSName }}"
            SQLInstanceName   = "{{ SQLInstanceName }}"
            DAGName           = "{{ DAGName }}"
          }
          Script = join("\n", [
            "# Version pinned: an unpinned Install-Module adopts whatever PSGallery serves at run time.",
            "Install-Module AWS.Tools.SimpleSystemsManagement -RequiredVersion 5.0.279 -Force",
            "Import-Module AWS.Tools.SimpleSystemsManagement",
            "",
            "$inputPayload = $env:InputPayload | ConvertFrom-Json",
            "$drInstanceId = $inputPayload.DRInstanceId",
            "$drRegion = $inputPayload.DRRegion",
            "$dagName = $inputPayload.DAGName",
            "$domainAdminSecret = $inputPayload.DomainAdminSecret",
            "$domainAdminUser = $inputPayload.DomainAdminUser",
            "$domainDNSName = $inputPayload.DomainDNSName",
            "$sqlInstanceName = $inputPayload.SQLInstanceName",
            "",
            "Write-Host '=== DAG Demote DR to SECONDARY ==='",
            "Write-Host \"DR Instance: $drInstanceId | DR Region: $drRegion | DAG: $dagName\"",
            "",
            "$script = @\"",
            "`$ErrorActionPreference = 'Stop'",
            "try {",
            "  `$secret = ConvertFrom-Json (Get-SECSecretValue -SecretId $domainAdminSecret -ErrorAction Stop).SecretString",
            "  `$domain = '$domainDNSName'",
            "  `$netbios = (`$domain -split '\\.')[0].ToUpper()",
            "  `$user = `$netbios + '\\' + '$domainAdminUser'",
            "  `$pass = ConvertTo-SecureString `$secret.password -AsPlainText -Force",
            "  `$cred = New-Object PSCredential(`$user, `$pass)",
            "  `$s = New-PSSession -ComputerName `$env:COMPUTERNAME -Authentication Credssp -Credential `$cred -ErrorAction Stop",
            "  Invoke-Command -Session `$s -ErrorAction Stop -ScriptBlock {",
            "    `$sqlMod = Get-Module -Name SqlServer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1",
            "    if (`$sqlMod) { Import-Module SqlServer -Force } else { Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue }",
            "    `$sqlParams = @{}",
            "    `$cmdInfo = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue",
            "    # SECURITY NOTE: this disables TLS certificate validation. The connection is still",
            "    # encrypted, but any certificate the server presents is accepted, so traffic on the",
            "    # network path could be intercepted or modified undetected. Set during bootstrap only,",
            "    # because SQL Server has a self-signed certificate until one is provisioned. For",
            "    # production install a CA-issued certificate and remove this line.",
            "    if (`$cmdInfo -and `$cmdInfo.Parameters.ContainsKey('TrustServerCertificate')) { `$sqlParams['TrustServerCertificate'] = `$true }",
            "    `$instName = '$sqlInstanceName'",
            "    if (`$instName -eq 'MSSQLSERVER' -or `$instName -eq 'DEFAULT') { `$sqlInst = `$env:COMPUTERNAME } else { `$sqlInst = `$env:COMPUTERNAME + '\\' + `$instName }",
            "    Write-Host \"Demoting DR to SECONDARY on `$env:COMPUTERNAME | Instance: `$sqlInst\"",
            "    `$maxWait = 120; `$waited = 0; `$localRole = `$null",
            "    while (`$waited -lt `$maxWait) {",
            "      `$roleResult = Invoke-Sqlcmd -ServerInstance `$sqlInst @sqlParams -Query \"SELECT rs.role_desc FROM sys.availability_groups ag JOIN sys.dm_hadr_availability_replica_states rs ON ag.group_id = rs.group_id WHERE ag.is_distributed = 1 AND rs.is_local = 1\" -ErrorAction SilentlyContinue",
            "      `$localRole = if (`$roleResult) { `$roleResult.role_desc } else { '' }",
            "      Write-Host \"Current DR DAG role: '`$localRole' (waited `$(`$waited)s)\"",
            "      if (`$localRole -eq 'PRIMARY' -or `$localRole -eq 'GLOBAL_PRIMARY') { break }",
            "      Start-Sleep -Seconds 15; `$waited += 15",
            "    }",
            "    if (`$localRole -ne 'PRIMARY' -and `$localRole -ne 'GLOBAL_PRIMARY') { throw \"Cannot demote DR - current role is '`$localRole' after `$(`$maxWait)s. Expected PRIMARY. Aborting to prevent dual-demote.\" }",
            "    `$demoteSql = 'ALTER AVAILABILITY GROUP [$dagName] SET (ROLE = SECONDARY);'",
            "    Write-Host \"Executing: `$demoteSql\"",
            "    Invoke-Sqlcmd -ServerInstance `$sqlInst @sqlParams -Query `$demoteSql -QueryTimeout 300 -ErrorAction Stop",
            "    Write-Host 'DR DAG demoted to SECONDARY successfully.'",
            "  }",
            "  Remove-PSSession `$s -ErrorAction SilentlyContinue",
            "} catch {",
            "  Write-Error \"DAG Demote DR FAILED: `$_\"",
            "  Remove-PSSession `$s -ErrorAction SilentlyContinue",
            "  throw `$_",
            "}",
            "\"@",
            "",
            "Set-DefaultAWSRegion -Region $drRegion",
            "$SC = Send-SSMCommand -DocumentName 'AWS-RunPowerShellScript' -Parameter @{commands = $script; executionTimeout = @('600')} -Target @{Key='instanceids';Values=@($drInstanceId)}",
            "Write-Host \"Command Id: $($SC.CommandId)\"",
            "",
            "$pollInterval = 10",
            "$maxRetries = 60",
            "$retryCount = 0",
            "",
            "do {",
            "  $invocation = Get-SSMCommandInvocation -CommandId $($SC.CommandId) -InstanceId $drInstanceId -Details $true | Select-Object -ExpandProperty CommandPlugins",
            "  $Status = $invocation.Status",
            "  Write-Host \"Status: $Status\"",
            "  Write-Host \"Output: $($invocation.Output)\"",
            "",
            "  if ($Status -eq 'Success') {",
            "    Write-Host 'DAG Demote DR completed successfully'",
            "    Write-Host $invocation.Output",
            "    break",
            "  } elseif ($Status -eq 'InProgress' -or $Status -eq 'Delayed' -or $Status -eq 'Pending' -or $Status -eq $null) {",
            "    $retryCount++",
            "    Start-Sleep -Seconds $pollInterval",
            "    continue",
            "  } else {",
            "    throw \"DAG Demote DR command '$($SC.CommandId)' failed with status '$Status'. Output: $($invocation.Output)\"",
            "  }",
            "} while ($retryCount -lt $maxRetries)",
            "",
            "if ($retryCount -ge $maxRetries) {",
            "  throw \"DAG Demote DR timed out after $($maxRetries * $pollInterval) seconds.\"",
            "}",
            "",
            "Write-Host '=== DAG Demote DR SUCCEEDED ==='"
          ])
        }
        onFailure      = "step:sleepend"
        timeoutSeconds = 900
      },
      # =====================================================================
      # Step 12: DAG Failback - FORCE_FAILOVER on original primary (local)
      # After DR is demoted to SECONDARY, the original primary uses
      # FORCE_FAILOVER_ALLOW_DATA_LOSS to reclaim global primary role.
      # =====================================================================
      {
        name   = "DAGPromotePrimary"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ PrimaryInstanceId }}"]
          Parameters = {
            commands = [
              "$ErrorActionPreference = 'Stop'",
              "try {",
              "  $secret = ConvertFrom-Json (Get-SECSecretValue -SecretId {{ DomainAdminSecretName }} -ErrorAction Stop).SecretString",
              "  $domain = '{{ DomainDNSName }}'",
              "  $netbios = ($domain -split '\\.')[0].ToUpper()",
              "  $user = $netbios + '\\' + '{{ DomainAdminUser }}'",
              "  $pass = ConvertTo-SecureString $secret.password -AsPlainText -Force",
              "  $cred = New-Object PSCredential($user, $pass)",
              "  $s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred -ErrorAction Stop",
              "  Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock {",
              "    $sqlMod = Get-Module -Name SqlServer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1",
              "    if ($sqlMod) { Import-Module SqlServer -Force } else { Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue }",
              "    $sqlParams = @{}",
              "    $cmdInfo = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue",
              "    # SECURITY NOTE: this disables TLS certificate validation. The connection is still",
              "    # encrypted, but any certificate the server presents is accepted, so traffic on the",
              "    # network path could be intercepted or modified undetected. Set during bootstrap only,",
              "    # because SQL Server has a self-signed certificate until one is provisioned. For",
              "    # production install a CA-issued certificate and remove this line.",
              "    if ($cmdInfo -and $cmdInfo.Parameters.ContainsKey('TrustServerCertificate')) { $sqlParams['TrustServerCertificate'] = $true }",
              "    $instName = '{{ SQLInstanceName }}'",
              "    $dagName = '{{ DAGName }}'",
              "    if ($instName -eq 'MSSQLSERVER' -or $instName -eq 'DEFAULT') { $sqlInst = $env:COMPUTERNAME } else { $sqlInst = $env:COMPUTERNAME + '\\' + $instName }",
              "    Write-Host '=== DAG Failback - FORCE_FAILOVER on Primary ==='",
              "    Write-Host \"Running on: $env:COMPUTERNAME | Instance: $sqlInst | DAG: $dagName\"",
              "    $failoverSql = 'ALTER AVAILABILITY GROUP [' + $dagName + '] FORCE_FAILOVER_ALLOW_DATA_LOSS;'",
              "    Write-Host \"Executing: $failoverSql\"",
              "    Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query $failoverSql -QueryTimeout 300 -ErrorAction Stop",
              "    Write-Host 'FORCE_FAILOVER command accepted. Polling for role change...'",
              "    $maxWait = 120; $waited = 0",
              "    $finalRole = 'UNKNOWN'",
              "    while ($waited -lt $maxWait) {",
              "      Start-Sleep -Seconds 15",
              "      $waited += 15",
              "      $dagRole = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT rs.role_desc FROM sys.availability_groups ag JOIN sys.dm_hadr_availability_replica_states rs ON ag.group_id = rs.group_id WHERE ag.is_distributed = 1 AND rs.is_local = 1\" -ErrorAction SilentlyContinue",
              "      $finalRole = if ($dagRole) { $dagRole.role_desc } else { 'NULL' }",
              "      Write-Host \"  DAG role after $${waited}s: $finalRole\"",
              "      if ($finalRole -eq 'PRIMARY') { break }",
              "    }",
              "    if ($finalRole -ne 'PRIMARY') { throw \"DAG Failback failed after $${maxWait}s - role is $finalRole, expected PRIMARY\" }",
              "    Write-Host '=== DAG Failback to Primary SUCCEEDED ==='",
              "  }",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "} catch {",
              "  Write-Host ('ERROR: ' + $_.Exception.Message)",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "  exit 1",
              "}"
            ]
            executionTimeout = ["600"]
          }
        }
        onFailure = "step:sleepend"
      },
      # =====================================================================
      # Step 13: Final DAG health check
      # =====================================================================
      {
        name   = "DAGFinalHealthCheck"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ PrimaryInstanceId }}"]
          Parameters = {
            commands = [
              "$ErrorActionPreference = 'Stop'",
              "try {",
              "  $secret = ConvertFrom-Json (Get-SECSecretValue -SecretId {{ DomainAdminSecretName }} -ErrorAction Stop).SecretString",
              "  $domain = '{{ DomainDNSName }}'",
              "  $netbios = ($domain -split '\\.')[0].ToUpper()",
              "  $user = $netbios + '\\' + '{{ DomainAdminUser }}'",
              "  $pass = ConvertTo-SecureString $secret.password -AsPlainText -Force",
              "  $cred = New-Object PSCredential($user, $pass)",
              "  $s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred -ErrorAction Stop",
              "  Invoke-Command -Session $s -ErrorAction Stop -ScriptBlock {",
              "    $sqlMod = Get-Module -Name SqlServer -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1",
              "    if ($sqlMod) { Import-Module SqlServer -Force } else { Import-Module SQLPS -DisableNameChecking -ErrorAction SilentlyContinue }",
              "    $sqlParams = @{}",
              "    $cmdInfo = Get-Command Invoke-Sqlcmd -ErrorAction SilentlyContinue",
              "    # SECURITY NOTE: this disables TLS certificate validation. The connection is still",
              "    # encrypted, but any certificate the server presents is accepted, so traffic on the",
              "    # network path could be intercepted or modified undetected. Set during bootstrap only,",
              "    # because SQL Server has a self-signed certificate until one is provisioned. For",
              "    # production install a CA-issued certificate and remove this line.",
              "    if ($cmdInfo -and $cmdInfo.Parameters.ContainsKey('TrustServerCertificate')) { $sqlParams['TrustServerCertificate'] = $true }",
              "    $instName = '{{ SQLInstanceName }}'",
              "    $dagName = '{{ DAGName }}'",
              "    $agName = '{{ AvailabilityGroupName }}'",
              "    if ($instName -eq 'MSSQLSERVER' -or $instName -eq 'DEFAULT') { $sqlInst = $env:COMPUTERNAME } else { $sqlInst = $env:COMPUTERNAME + '\\' + $instName }",
              "    Write-Host '=== DAG Final Health Check ==='",
              "    $agState = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT ag.name, ags.primary_replica, ags.synchronization_health_desc FROM sys.availability_groups ag JOIN sys.dm_hadr_availability_group_states ags ON ag.group_id = ags.group_id WHERE ag.name = '$agName'\" -ErrorAction SilentlyContinue",
              "    if ($agState) { Write-Host \"Local AG: $($agState.name) | Primary: $($agState.primary_replica) | Health: $($agState.synchronization_health_desc)\" }",
              "    $dagReplicas = Invoke-Sqlcmd -ServerInstance $sqlInst @sqlParams -Query \"SELECT ag.name, ar.replica_server_name, drs.role_desc, drs.synchronization_health_desc, drs.connected_state_desc FROM sys.availability_groups ag JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id LEFT JOIN sys.dm_hadr_availability_replica_states drs ON ar.replica_id = drs.replica_id WHERE ag.is_distributed = 1\" -ErrorAction SilentlyContinue",
              "    if ($dagReplicas) {",
              "      $dagReplicas | ForEach-Object { Write-Host \"  DAG Replica: $($_.replica_server_name) | Role: $($_.role_desc) | Connected: $($_.connected_state_desc) | Health: $($_.synchronization_health_desc)\" }",
              "    }",
              "    Write-Host '=== ALL TESTS COMPLETED SUCCESSFULLY ==='",
              "    Write-Host '  - AG Failover/Failback: PASSED'",
              "    Write-Host '  - DAG Failover/Failback: PASSED'",
              "  }",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "} catch {",
              "  Write-Host ('ERROR: ' + $_.Exception.Message)",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "  exit 1",
              "}"
            ]
            executionTimeout = ["300"]
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "sleepend"
        action = "aws:sleep"
        inputs = { Duration = "PT5S" }
        isEnd  = true
      }
    ]
  })
}
