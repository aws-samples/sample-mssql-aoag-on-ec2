# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# SSM Document 6: proserve_aoag_join_secondary
# Purpose: Join secondary replicas to the Availability Group
# Runs on: SECONDARY nodes only (after AG created)
###############################################################################
resource "aws_ssm_document" "proserve_aoag_join_secondary" {
  provider      = aws.site
  document_type = "Automation"
  name          = "${local.name_prefix}proserve_aoag_join_secondary"

  tags = merge(var.tags, {
    Name = "proserve_aoag_join_secondary"
  })

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "AOAG Join Secondary - Joins secondary replica to the Availability Group"
    assumeRole    = "{{ AutomationAssumeRole }}"

    parameters = {
      AutomationAssumeRole = {
        type        = "String"
        description = "The ARN of the role that allows Automation to perform actions"
      }
      InstanceId = {
        type        = "String"
        description = "Instance Id of the secondary node"
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
        description = "Name of the Availability Group to join"
      }
      PrimaryNodeName = {
        type        = "String"
        description = "Hostname of the primary node"
      }
    }
    mainSteps = [
      {
        name   = "InitialSleep"
        action = "aws:sleep"
        inputs = { Duration = "PT30S" }
      },
      {
        name   = "EnableAlwaysOnSecondary"
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
              "    & C:\\aoag\\scripts\\ag\\Enable-AlwaysOn.ps1 -SQLInstanceName '{{ SQLInstanceName }}' -Role Secondary",
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
        name   = "CreateDBMirroringEndpointSecondary"
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
              "    & C:\\aoag\\scripts\\ag\\Create-DBMirroringEndpoint-Secondary.ps1 -SQLInstanceName '{{ SQLInstanceName }}'",
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
        name   = "JoinAvailabilityGroup"
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
              "    & C:\\aoag\\scripts\\ag\\Join-AG.ps1 -AvailabilityGroupName '{{ AvailabilityGroupName }}' -PrimaryNodeName '{{ PrimaryNodeName }}' -SQLInstanceName '{{ SQLInstanceName }}'",
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
        name   = "sleepend"
        action = "aws:sleep"
        inputs = { Duration = "PT5S" }
        isEnd  = true
      }
    ]
  })
}
