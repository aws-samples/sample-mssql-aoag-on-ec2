# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# SSM Document: proserve_aoag_dr_clustering
# Purpose: Create a separate WSFC cluster on the DR node for DAG architecture
# Runs on: DR node only (creates independent cluster, not joined to primary)
###############################################################################
resource "aws_ssm_document" "proserve_aoag_dr_clustering" {
  provider      = aws.site
  document_type = "Automation"
  name          = "${local.name_prefix}proserve_aoag_dr_clustering"

  tags = merge(var.tags, {
    Name = "proserve_aoag_dr_clustering"
  })

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "AOAG DR Clustering - Creates separate WSFC cluster on DR node for Distributed AG"
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
      ClusterName = {
        type        = "String"
        description = "WSFC cluster name for DR site"
      }
      Namespace = {
        type        = "String"
        description = "Namespace for stack identification"
      }
      ClusterStaticIP = {
        type        = "String"
        description = "Static IP for the DR WSFC cluster CNO"
        default     = ""
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
        name   = "CreateDRCluster"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands         = ["powershell.exe -Command 'C:\\aoag\\scripts\\ag\\Node1AddCluster.ps1 -AdminSecret {{ DomainAdminSecretName }} -DomainDNSName ''{{ DomainDNSName }}'' -Stackname {{ Namespace }} -ClusterStaticIP ''{{ ClusterStaticIP }}'' ';if(!$?){exit 100}"]
            executionTimeout = "1800"
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "WaitAfterClusterCreate"
        action = "aws:sleep"
        inputs = { Duration = "PT1M" }
      },
      {
        name   = "ConfigureDNSPTR"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands         = ["& Get-ClusterResource | Where-Object {$_.ResourceType.Name -eq 'Network Name'} | Set-ClusterParameter -Name PublishPTRRecords -Value 1; if(!$?){exit 100}"]
            executionTimeout = "120"
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
