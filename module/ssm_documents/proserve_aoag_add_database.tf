# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# SSM Document: proserve_aoag_add_database
# Purpose: Day-2 operation. Add an existing database on the primary replica to
#          an Availability Group with the chosen seeding mode.
# Runs on: PRIMARY node. For MANUAL seeding the operator must have restored the
#          database WITH NORECOVERY on every secondary BEFORE invoking this doc.
# Invoked by: operator via console / CLI. NOT invoked by Terraform.
###############################################################################
resource "aws_ssm_document" "proserve_aoag_add_database" {
  provider      = aws.site
  document_type = "Automation"
  name          = "${local.name_prefix}proserve_aoag_add_database"

  tags = merge(var.tags, {
    Name = "proserve_aoag_add_database"
  })

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "AOAG Add Database - adds a database to an existing AG with AUTOMATIC or MANUAL seeding"
    assumeRole    = "{{ AutomationAssumeRole }}"

    parameters = {
      AutomationAssumeRole = {
        type        = "String"
        description = "ARN of the role that allows Automation to perform actions"
      }
      InstanceId = {
        type        = "String"
        description = "Instance Id of the primary AG replica"
      }
      DomainAdminSecretName = {
        type        = "String"
        description = "Secrets Manager ARN for domain admin credentials"
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
        description = "SQL Server instance name (e.g. MSSQLSERVER)"
      }
      AvailabilityGroupName = {
        type        = "String"
        description = "Name of the existing Availability Group"
      }
      DatabaseName = {
        type        = "String"
        description = "Name of the database to add. Must exist on the primary."
      }
      SeedingMode = {
        type          = "String"
        description   = "AUTOMATIC: SQL pushes data over the AG endpoint. MANUAL: operator pre-restored the DB WITH NORECOVERY on every secondary."
        default       = "AUTOMATIC"
        allowedValues = ["AUTOMATIC", "MANUAL"]
      }
      BackupPath = {
        type        = "String"
        description = "Local or UNC path used for the full + log backup taken on the primary (AUTOMATIC mode only)."
        default     = ""
      }
      SecondaryNodes = {
        type        = "String"
        description = "Comma-separated hostnames of secondary nodes. Required for MANUAL seeding; ignored for AUTOMATIC."
        default     = ""
      }
    }

    mainSteps = [
      {
        name   = "InitialSleep"
        action = "aws:sleep"
        inputs = { Duration = "PT5S" }
      },
      {
        name   = "AddDatabaseToAG"
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
              "    $args = @{",
              "      AvailabilityGroupName = '{{ AvailabilityGroupName }}'",
              "      DatabaseName          = '{{ DatabaseName }}'",
              "      SQLInstanceName       = '{{ SQLInstanceName }}'",
              "      SeedingMode           = '{{ SeedingMode }}'",
              "    }",
              "    if ('{{ BackupPath }}'     -ne '') { $args['BackupPath']     = '{{ BackupPath }}' }",
              "    if ('{{ SecondaryNodes }}' -ne '') { $args['SecondaryNodes'] = '{{ SecondaryNodes }}' }",
              "    & C:\\aoag\\scripts\\ag\\Add-DatabaseToAG.ps1 @args",
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
