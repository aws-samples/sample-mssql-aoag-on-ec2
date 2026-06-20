# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# SSM Document 2: proserve_aoag_install_sql
# Purpose: Install SQL Server standalone instance on each node
# Runs on: ALL nodes in PARALLEL (after node_common completes)
#
# Supports two modes:
#   1. License-included AMI: setup.exe already at C:\SQLServerSetup\setup.exe
#   2. BYOL: SQL media zip placed in S3 under 'aoag/' prefix, downloaded and
#      extracted by node_common's DownloadScriptsFromS3 step to C:\SQLServerSetup\
#
# DisableDefaultInstance step gracefully handles both modes:
#   - License-included: stops and disables the pre-installed default instance
#   - BYOL: no-op (no default instance exists on plain Windows AMI)
###############################################################################
resource "aws_ssm_document" "proserve_aoag_install_sql" {
  provider      = aws.site
  document_type = "Automation"
  name          = "${local.name_prefix}proserve_aoag_install_sql"

  tags = merge(var.tags, {
    Name = "proserve_aoag_install_sql"
  })

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "AOAG Install SQL - Installs SQL Server standalone instance on each node"
    assumeRole    = "{{ AutomationAssumeRole }}"

    parameters = {
      AutomationAssumeRole = {
        type        = "String"
        description = "The ARN of the role that allows Automation to perform actions"
      }
      InstanceId = {
        type        = "String"
        description = "Instance Id of the node to configure"
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
      SQLServiceAccountSecret = {
        type        = "String"
        description = "ARN for SQL service account secret"
      }
      SQLInstanceName = {
        type        = "String"
        description = "SQL Server instance name"
      }
      SQLConfig = {
        type        = "String"
        description = "SQL installation configuration JSON"
      }
      Features = {
        type        = "String"
        description = "SQL Server features to install"
        default     = "SQLENGINE,REPLICATION,FULLTEXT"
      }
      AMIID = {
        type        = "String"
        description = "AMI ID (used to detect pre-installed SQL)"
      }
    }

    mainSteps = [
      {
        name   = "InitialSleep"
        action = "aws:sleep"
        inputs = { Duration = "PT15S" }
      },
      {
        name   = "VerifyCredSSPReady"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands = [
              "powershell.exe -Command '",
              "Write-Host \"Purging Kerberos ticket cache to pick up delegation trust changes...\"",
              "klist purge -li 0x3e7 2>&1 | ForEach-Object { Write-Host $_ }",
              "klist purge 2>&1 | ForEach-Object { Write-Host $_ }",
              "Write-Host \"Kerberos tickets purged.\"",
              "",
              "$secret = ConvertFrom-Json (Get-SECSecretValue -SecretId {{ DomainAdminSecretName }} -ErrorAction Stop).SecretString",
              "$domain = ''{{ DomainDNSName }}''",
              "$netbios = ($domain -split ''\\.'')[0].ToUpper()",
              "$user = $netbios + ''\\'' + ''{{ DomainAdminUser }}''",
              "$pass = ConvertTo-SecureString $secret.password -AsPlainText -Force",
              "$cred = New-Object PSCredential($user, $pass)",
              "$maxRetries = 20; $retryInterval = 15",
              "for ($i = 1; $i -le $maxRetries; $i++) {",
              "  try {",
              "    $s = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $cred -ErrorAction Stop",
              "    Remove-PSSession $s -ErrorAction SilentlyContinue",
              "    Write-Host \"CredSSP session verified (attempt $i)\"",
              "    exit 0",
              "  } catch {",
              "    Write-Host \"CredSSP not ready (attempt $i/$maxRetries): $($_.Exception.Message)\"",
              "    if ($i -lt $maxRetries) { Start-Sleep -Seconds $retryInterval }",
              "  }",
              "}",
              "Write-Host \"WARNING: CredSSP not confirmed after $maxRetries attempts - proceeding anyway\"",
              "'"
            ]
            executionTimeout = "600"
          }
        }
        onFailure = "Continue"
        nextStep  = "InstallSQLStandalone"
      },
      {
        name   = "InstallSQLStandalone"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
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
              "    $ErrorActionPreference = 'Stop'",
              "    & C:\\aoag\\scripts\\install_sql\\Install-SQLStandalone.ps1 -AdminSecret '{{ DomainAdminSecretName }}' -DomainDNSName '{{ DomainDNSName }}' -DomainAdminUser '{{ DomainAdminUser }}' -SqlUserSecret '{{ SQLServiceAccountSecret }}' -AMIID '{{ AMIID }}' -SQLInstanceName '{{ SQLInstanceName }}' -Features '{{ Features }}' -SQLConfigBase64 '{{ SQLConfig }}'",
              "    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw ('Script exited with code ' + $LASTEXITCODE) }",
              "  }",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "} catch {",
              "  Write-Host ('ERROR: ' + $_.Exception.Message)",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "  exit 1",
              "}"
            ]
            executionTimeout = ["7200"]
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "DisableDefaultInstance"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
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
              "    # Stop and disable the AMI default instance to free resources.",
              "    # On BYOL (plain Windows AMI), no default instance exists - this is a no-op.",
              "    $svc = Get-Service -Name MSSQLSERVER -ErrorAction SilentlyContinue",
              "    if ($svc) {",
              "      Write-Host 'Stopping and disabling default SQL instance (MSSQLSERVER)...'",
              "      $agentSvc = Get-Service -Name SQLSERVERAGENT -ErrorAction SilentlyContinue",
              "      if ($agentSvc -and $agentSvc.Status -eq 'Running') { sc.exe stop SQLSERVERAGENT | Out-Null; Start-Sleep -Seconds 5 }",
              "      if ($svc.Status -eq 'Running') { sc.exe stop MSSQLSERVER | Out-Null; Start-Sleep -Seconds 10 }",
              "      sc.exe config MSSQLSERVER start= disabled | Out-Null",
              "      sc.exe config SQLSERVERAGENT start= disabled | Out-Null",
              "      Write-Host 'Default instance disabled.'",
              "    } else { Write-Host 'No default instance found - nothing to disable.' }",
              "  }",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "} catch {",
              "  Write-Host ('ERROR: ' + $_.Exception.Message)",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "  exit 1",
              "}"
            ]
            executionTimeout = ["120"]
          }
        }
        onFailure = "Continue"
      },
      {
        name   = "RestartBeforeCU"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands         = ["powershell.exe -Command 'C:\\aoag\\scripts\\common\\Restart-Computer.ps1';if(!$?){exit 100}"]
            executionTimeout = "600"
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name           = "WaitForRestartBeforeCU"
        action         = "aws:waitForAwsResourceProperty"
        timeoutSeconds = 300
        inputs = {
          Service          = "ec2"
          Api              = "DescribeInstanceStatus"
          InstanceIds      = ["{{ InstanceId }}"]
          PropertySelector = "$.InstanceStatuses[0].InstanceState.Name"
          DesiredValues    = ["running"]
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "WaitAfterRestartBeforeCU"
        action = "aws:sleep"
        inputs = { Duration = "PT4M" }
      },
      {
        name   = "InstallSQLCU"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
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
              "    $ErrorActionPreference = 'Stop'",
              "    & C:\\aoag\\scripts\\install_sql\\Install-sqlcu.ps1",
              "    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw ('Script exited with code ' + $LASTEXITCODE) }",
              "  }",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "} catch {",
              "  Write-Host ('ERROR: ' + $_.Exception.Message)",
              "  Remove-PSSession $s -ErrorAction SilentlyContinue",
              "  exit 1",
              "}"
            ]
            executionTimeout = ["3600"]
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "RestartAfterCU"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands         = ["powershell.exe -Command 'C:\\aoag\\scripts\\common\\Restart-Computer.ps1';if(!$?){exit 100}"]
            executionTimeout = "600"
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name           = "WaitForRestartAfterCU"
        action         = "aws:waitForAwsResourceProperty"
        timeoutSeconds = 300
        inputs = {
          Service          = "ec2"
          Api              = "DescribeInstanceStatus"
          InstanceIds      = ["{{ InstanceId }}"]
          PropertySelector = "$.InstanceStatuses[0].InstanceState.Name"
          DesiredValues    = ["running"]
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "WaitAfterRestartAfterCU"
        action = "aws:sleep"
        inputs = { Duration = "PT4M" }
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
