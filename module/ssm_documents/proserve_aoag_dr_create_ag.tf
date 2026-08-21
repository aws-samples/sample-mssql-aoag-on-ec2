# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# SSM Document: proserve_aoag_dr_create_ag
# Purpose: Create the DR Availability Group on the DR node for DAG
# Runs on: DR node only (after DR clustering completes)
# The DR AG is a standalone AG on the DR cluster, later linked via DAG
###############################################################################
resource "aws_ssm_document" "proserve_aoag_dr_create_ag" {
  provider      = aws.site
  document_type = "Automation"
  name          = "${local.name_prefix}proserve_aoag_dr_create_ag"

  tags = merge(var.tags, {
    Name = "proserve_aoag_dr_create_ag"
  })

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "AOAG DR Create AG - Creates DR Availability Group for Distributed AG"
    assumeRole    = "{{ AutomationAssumeRole }}"

    parameters = {
      AutomationAssumeRole = {
        type        = "String"
        description = "The ARN of the role that allows Automation to perform actions"
      }
      InstanceId = {
        type        = "String"
        description = "Instance Id of the DR node"
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
        description = "Secret ARN for SQL service account"
      }
      SQLInstanceName = {
        type        = "String"
        description = "SQL Server instance name"
      }
      AvailabilityGroupName = {
        type        = "String"
        description = "Name of the DR Availability Group"
      }
      ListenerName = {
        type        = "String"
        description = "DR AG Listener name"
      }
      ListenerPort = {
        type        = "String"
        description = "DR AG Listener port"
        default     = "1433"
      }
      ListenerIPsJson = {
        type        = "String"
        description = "JSON array of listener IPs with subnet masks"
      }
    }

    mainSteps = [
      {
        name   = "InitialSleep"
        action = "aws:sleep"
        inputs = { Duration = "PT15S" }
      },
      {
        name   = "EnableAlwaysOnDR"
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
              "    & C:\\aoag\\scripts\\ag\\Enable-AlwaysOn.ps1 -SQLInstanceName '{{ SQLInstanceName }}' -Role Primary",
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
        name   = "CreateDBMirroringEndpointDR"
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
              "    & C:\\aoag\\scripts\\ag\\Create-DBMirroringEndpoint.ps1 -SQLInstanceName '{{ SQLInstanceName }}'",
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
        name   = "CreateDRAvailabilityGroup"
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
              "    & C:\\aoag\\scripts\\ag\\Create-AG.ps1 -AvailabilityGroupName '{{ AvailabilityGroupName }}' -SQLInstanceName '{{ SQLInstanceName }}'",
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
        # See proserve_aoag_create_availability_group.tf for the rationale: the
        # DR-site listener VCO is created by the DR cluster's own CNO, so it hits
        # the same "Access is denied" (SQL Msg 19471 / event 1194) in any domain
        # that restricts computer-object creation. Prestage it the same way.
        name   = "PrestageDRListenerVCO"
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
              "    & C:\\aoag\\scripts\\ag\\Prestage-AGListenerVCO.ps1 -ListenerName '{{ ListenerName }}'",
              "    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw ('Script exited with code ' + $LASTEXITCODE) }",
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
      {
        name   = "CreateDRAGListener"
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
              "    & C:\\aoag\\scripts\\ag\\Create-AGListener.ps1 -AvailabilityGroupName '{{ AvailabilityGroupName }}' -ListenerName '{{ ListenerName }}' -SQLInstanceName '{{ SQLInstanceName }}' -ListenerPort {{ ListenerPort }} -ListenerIPsJson '{{ ListenerIPsJson }}'",
              "    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { throw ('Script exited with code ' + $LASTEXITCODE) }",
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
      {
        name   = "sleepend"
        action = "aws:sleep"
        inputs = { Duration = "PT5S" }
        isEnd  = true
      }
    ]
  })
}
