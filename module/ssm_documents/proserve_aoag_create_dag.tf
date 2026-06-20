# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# SSM Document: proserve_aoag_create_dag
# Purpose: Create or Join a Distributed Availability Group
# Runs on: PRIMARY node (to create DAG) or DR node (to join DAG)
# The Action parameter controls whether this creates or joins the DAG
###############################################################################
resource "aws_ssm_document" "proserve_aoag_create_dag" {
  provider      = aws.site
  document_type = "Automation"
  name          = "${local.name_prefix}proserve_aoag_create_dag"

  tags = merge(var.tags, {
    Name = "proserve_aoag_create_dag"
  })

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "AOAG DAG - Creates or Joins a Distributed Availability Group"
    assumeRole    = "{{ AutomationAssumeRole }}"

    parameters = {
      AutomationAssumeRole = {
        type        = "String"
        description = "The ARN of the role that allows Automation to perform actions"
      }
      InstanceId = {
        type        = "String"
        description = "Instance Id of the node"
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
      DAGName = {
        type        = "String"
        description = "Name of the Distributed Availability Group"
      }
      PrimaryAGName = {
        type        = "String"
        description = "Name of the primary site AG"
      }
      DRAGName = {
        type        = "String"
        description = "Name of the DR site AG"
      }
      PrimaryListenerName = {
        type        = "String"
        description = "FQDN of the primary AG listener"
      }
      DRListenerName = {
        type        = "String"
        description = "FQDN of the DR AG listener"
      }
      DAGAction = {
        type          = "String"
        description   = "Action: Create (on primary) or Join (on DR)"
        default       = "Create"
        allowedValues = ["Create", "Join"]
      }
      SeedingMode = {
        type          = "String"
        description   = "Initial database copy mode for the DAG. AUTOMATIC = SQL pushes data over the AG endpoint (default, best for small DBs on fast links). MANUAL = operator pre-restores the database WITH NORECOVERY on the receiving side (required for VLDBs and on-prem extension)."
        default       = "AUTOMATIC"
        allowedValues = ["AUTOMATIC", "MANUAL"]
      }
    }

    mainSteps = [
      {
        name   = "InitialSleep"
        action = "aws:sleep"
        inputs = { Duration = "PT15S" }
      },
      {
        name   = "EnableCredSSP"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands         = ["powershell.exe -ExecutionPolicy RemoteSigned -Command 'C:\\aoag\\scripts\\common\\Enable-CredSSP.ps1';if(!$?){exit 100}"]
            executionTimeout = "300"
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "CreateOrJoinDAG"
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
              "    & C:\\aoag\\scripts\\ag\\Create-DAG.ps1 -Action '{{ DAGAction }}' -DAGName '{{ DAGName }}' -PrimaryAGName '{{ PrimaryAGName }}' -DRAGName '{{ DRAGName }}' -PrimaryListenerName '{{ PrimaryListenerName }}' -DRListenerName '{{ DRListenerName }}' -SQLInstanceName '{{ SQLInstanceName }}' -SeedingMode '{{ SeedingMode }}'",
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
