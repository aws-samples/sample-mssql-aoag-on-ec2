# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# SSM Document 4: proserve_aoag_add_node_to_cluster
# Purpose: Add secondary nodes to the WSFC cluster
# Runs on: SECONDARY nodes only (after clustering completes)
###############################################################################
resource "aws_ssm_document" "proserve_aoag_add_node_to_cluster" {
  provider      = aws.site
  document_type = "Automation"
  name          = "${local.name_prefix}proserve_aoag_add_node_to_cluster"

  tags = merge(var.tags, {
    Name = "proserve_aoag_add_node_to_cluster"
  })

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "AOAG Add Node - Adds secondary node to existing WSFC cluster"
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
      ClusterName = {
        type        = "String"
        description = "WSFC cluster name to join"
      }
      PrimaryNodeName = {
        type        = "String"
        description = "Hostname of the primary cluster node (fallback if CNO does not resolve)"
        default     = ""
      }
    }

    mainSteps = [
      {
        name   = "InitialSleep"
        action = "aws:sleep"
        inputs = { Duration = "PT30S" }
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
        name   = "AddNodeToCluster"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands         = ["powershell.exe -Command 'C:\\aoag\\scripts\\ag\\AdditionalNodeAddCluster.ps1 -AdminSecret {{ DomainAdminSecretName }} -DomainDNSName ''{{ DomainDNSName }}'' -DomainAdminUser {{ DomainAdminUser }} -PrimaryNodeName ''{{ PrimaryNodeName }}'' -ClusterName ''{{ ClusterName }}'' ';if(!$?){exit 100}"]
            executionTimeout = "1800"
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name           = "WaitForInstanceAfterJoin"
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
        name   = "WaitAfterNodeAdd"
        action = "aws:sleep"
        inputs = { Duration = "PT30S" }
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