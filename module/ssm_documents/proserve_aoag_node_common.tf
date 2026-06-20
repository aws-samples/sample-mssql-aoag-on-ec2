# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# SSM Document 1: proserve_aoag_node_common
# Purpose: Prepare all nodes with common configuration steps
# Runs on: ALL nodes (primary and secondary) in PARALLEL
#
# Scripts are downloaded from S3 bucket under 'aoag/scripts/common/' prefix.
# No DSC, no LCM, no AWSLaunchWizard dependencies.
###############################################################################
resource "aws_ssm_document" "proserve_aoag_node_common" {
  provider      = aws.site
  document_type = "Automation"
  name          = "${local.name_prefix}proserve_aoag_node_common"

  tags = merge(var.tags, {
    Name = "proserve_aoag_node_common"
  })

  content = jsonencode({
    schemaVersion = "0.3"
    description   = "AOAG Node Common - Downloads scripts, installs prerequisites, joins domain, configures node"
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
      BucketName = {
        type        = "String"
        description = "S3 bucket name for scripts"
      }
      S3Region = {
        type        = "String"
        description = "S3 bucket region"
      }
      DomainAdminSecretName = {
        type        = "String"
        description = "ARN for the domain admin secret"
      }
      DomainAdminUser = {
        type        = "String"
        description = "Domain admin username"
        default     = "administrator"
      }
      DomainDNSName = {
        type        = "String"
        description = "Fully qualified domain name"
      }
      ADDnsIpAddresses = {
        type        = "String"
        description = "DNS IP addresses (comma-separated)"
      }
      SQLServiceAccountKey = {
        type        = "String"
        description = "Secret ARN for SQL service account"
      }
      SQLAdminAccounts = {
        type        = "String"
        description = "SQL admin accounts (service account name)"
      }
      WindowsADMembers = {
        type        = "String"
        description = "AD users/groups to add to local admin"
        default     = "Domain Admins"
      }
      WindowsLocalGroup = {
        type        = "String"
        description = "Windows local group"
        default     = "Administrators"
      }
      HostName = {
        type        = "String"
        description = "Target hostname for the node (NetBIOS name)"
      }
      EBSDriveConfig = {
        type        = "String"
        description = "JSON array of EBS volume configs: [{volume_size, drive_letter, label_name, block_size}, ...]"
        default     = "[]"
      }
      UseNVMeTempDB = {
        type        = "String"
        description = "Set to 'true' to use NVMe instance store for TempDB instead of EBS. The instance type must have instance store volumes."
        default     = "false"
      }
      NVMeDriveLetter = {
        type        = "String"
        description = "Drive letter for NVMe instance store volume (used for TempDB)"
        default     = "T"
      }
    }

    mainSteps = [
      {
        name   = "InitialSleep"
        action = "aws:sleep"
        inputs = { Duration = "PT30S" }
      },
      {
        name   = "DownloadScriptsFromS3"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands = [
              "New-Item -Path C:\\aoag -ItemType Directory -Force | Out-Null",
              "New-Item -Path C:\\aoag\\log -ItemType Directory -Force | Out-Null",
              "Write-Host 'Downloading AOAG scripts from S3...'",
              "(Read-S3Object -BucketName {{ BucketName }} -Region {{ S3Region }} -KeyPrefix 'aoag' -Folder C:\\aoag);if(!$?){exit 100}",
              "Write-Host 'Listing downloaded scripts...'",
              "Get-ChildItem C:\\aoag\\scripts -Recurse | ForEach-Object { Write-Host $_.FullName }",
              "if (!(Test-Path C:\\aoag\\scripts\\common\\Domain-Join-Rename.ps1)) { throw 'Script download failed - Domain-Join-Rename.ps1 not found' }",
              "if (!(Test-Path C:\\aoag\\scripts\\install_sql\\Install-SQLStandalone.ps1)) { throw 'Script download failed - Install-SQLStandalone.ps1 not found' }",
              "Write-Host 'All scripts downloaded successfully'",
              "",
              "# BYOL: If a SQL Server media zip was downloaded, extract it to C:\\SQLServerSetup\\",
              "$sqlZip = Get-ChildItem -Path C:\\aoag -Filter 'SQL*.zip' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1",
              "if ($sqlZip) {",
              "  $setupDir = 'C:\\SQLServerSetup'",
              "  if (Test-Path \"$setupDir\\setup.exe\") {",
              "    Write-Host \"SQL Server setup media already extracted at $setupDir\\setup.exe - skipping.\"",
              "  } else {",
              "    Write-Host \"Found SQL media zip: $($sqlZip.FullName) ($([math]::Round($sqlZip.Length / 1MB, 2)) MB)\"",
              "    Write-Host \"Extracting to $setupDir...\"",
              "    Expand-Archive -LiteralPath $sqlZip.FullName -DestinationPath $setupDir -Force",
              "    # Handle nested folder: if setup.exe is one level deep, move contents up",
              "    if (-not (Test-Path \"$setupDir\\setup.exe\")) {",
              "      $nested = Get-ChildItem $setupDir -Directory | Select-Object -First 1",
              "      if ($nested -and (Test-Path \"$($nested.FullName)\\setup.exe\")) {",
              "        Write-Host \"Moving contents from nested folder: $($nested.Name)\"",
              "        Get-ChildItem $nested.FullName | Move-Item -Destination $setupDir -Force",
              "        Remove-Item $nested.FullName -Recurse -Force -ErrorAction SilentlyContinue",
              "      }",
              "    }",
              "    if (Test-Path \"$setupDir\\setup.exe\") {",
              "      Write-Host \"SQL Server media ready at $setupDir\\setup.exe\"",
              "    } else {",
              "      Write-Host 'WARNING: setup.exe not found after extraction - check zip structure.'",
              "    }",
              "    Remove-Item $sqlZip.FullName -Force -ErrorAction SilentlyContinue",
              "  }",
              "} else {",
              "  Write-Host 'No SQL media zip found in S3 download - using license-included AMI setup.'",
              "}",
              "",
              "# SSMS Offline Layout: If an SSMS offline layout zip was downloaded from S3, extract it.",
              "# To pre-stage: vs_SSMS.exe --layout C:\\SSMSLayout --all, then zip and upload as s3://<bucket>/aoag/SSMS*.zip",
              "# See: https://learn.microsoft.com/en-us/ssms/install/create-offline",
              "$ssmsZip = Get-ChildItem -Path C:\\aoag -Filter 'SSMS*.zip' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1",
              "if ($ssmsZip) {",
              "  $ssmsLayoutDir = 'C:\\aoag\\ssms_offline'",
              "  if (Test-Path \"$ssmsLayoutDir\\vs_SSMS.exe\") {",
              "    Write-Host \"SSMS offline layout already extracted at $ssmsLayoutDir - skipping.\"",
              "  } else {",
              "    Write-Host \"Found SSMS offline layout zip: $($ssmsZip.FullName) ($([math]::Round($ssmsZip.Length / 1MB, 2)) MB)\"",
              "    Write-Host \"Extracting to $ssmsLayoutDir...\"",
              "    Expand-Archive -LiteralPath $ssmsZip.FullName -DestinationPath $ssmsLayoutDir -Force",
              "    if (-not (Test-Path \"$ssmsLayoutDir\\vs_SSMS.exe\")) {",
              "      $nested = Get-ChildItem $ssmsLayoutDir -Directory | Select-Object -First 1",
              "      if ($nested -and (Test-Path \"$($nested.FullName)\\vs_SSMS.exe\")) {",
              "        Get-ChildItem $nested.FullName | Move-Item -Destination $ssmsLayoutDir -Force",
              "        Remove-Item $nested.FullName -Recurse -Force -ErrorAction SilentlyContinue",
              "      }",
              "    }",
              "    if (Test-Path \"$ssmsLayoutDir\\vs_SSMS.exe\") {",
              "      Write-Host \"SSMS offline layout ready at $ssmsLayoutDir\\vs_SSMS.exe\"",
              "    } else {",
              "      Write-Host 'WARNING: vs_SSMS.exe not found after extraction - check zip structure.'",
              "    }",
              "    Remove-Item $ssmsZip.FullName -Force -ErrorAction SilentlyContinue",
              "  }",
              "} else {",
              "  Write-Host 'No SSMS offline layout zip found in S3 - will download bootstrapper and create layout during install step.'",
              "}"
            ]
            executionTimeout = ["1800"]
          }
        }
        onFailure = "step:sleepend"
      },

      {
        name   = "InitializeEBSVolumes"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands = [
              "$driveConfig = '{{ EBSDriveConfig }}'",
              "Set-Content -Path C:\\aoag\\log\\ebs_drive_config.json -Value $driveConfig -Force",
              "& C:\\aoag\\scripts\\common\\Initialize-EBSVolumes.ps1 -DriveConfig $driveConfig; if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }"
            ]
            executionTimeout = ["600"]
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "InitializeNVMeVolume"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands = [
              "$useNVMe = '{{ UseNVMeTempDB }}'",
              "if ($useNVMe -ne 'true') { Write-Host 'NVMe TempDB not enabled - skipping.'; exit 0 }",
              "& C:\\aoag\\scripts\\common\\Initialize-NVMeVolume.ps1 -DriveLetter '{{ NVMeDriveLetter }}' -Label 'SQL-TempDB' -BlockSize 65536; if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }"
            ]
            executionTimeout = ["300"]
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "RegisterNVMeBootTask"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands = [
              "$useNVMe = '{{ UseNVMeTempDB }}'",
              "if ($useNVMe -ne 'true') { Write-Host 'NVMe TempDB not enabled - skipping boot task.'; exit 0 }",
              "$taskName = 'AOAG-InitNVMe'",
              "$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue",
              "if ($existing) { Write-Host 'Scheduled task already exists - updating.'; Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }",
              "$scriptPath = 'C:\\aoag\\scripts\\common\\Initialize-NVMeVolume.ps1'",
              "$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-ExecutionPolicy Bypass -File ' + $scriptPath + ' -DriveLetter {{ NVMeDriveLetter }} -Label SQL-TempDB -BlockSize 65536')",
              "$trigger = New-ScheduledTaskTrigger -AtStartup",
              "$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest",
              "$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)",
              "Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Re-initialize NVMe instance store for SQL TempDB on boot' | Out-Null",
              "Write-Host 'Scheduled task registered: AOAG-InitNVMe (runs at startup)'"
            ]
            executionTimeout = ["120"]
          }
        }
        onFailure = "Continue"
      },
      {
        name   = "InstallWindowsFeatures"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands         = ["powershell.exe -ExecutionPolicy RemoteSigned -Command 'C:\\aoag\\scripts\\common\\Install-WindowsFeatures.ps1';if(!$?){exit 100}"]
            executionTimeout = "1800"
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "WaitAfterFeaturesReboot"
        action = "aws:sleep"
        inputs = { Duration = "PT3M" }
      },
      {
        name   = "InstallAWSCli"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands = [
              "if (Test-Path 'C:\\Program Files\\Amazon\\AWSCLIV2\\aws.exe') { Write-Host 'AWS CLI already installed'; exit 0 }",
              "try { msiexec.exe /i https://awscli.amazonaws.com/AWSCLIV2.msi /qn } catch { Write-Host 'WARNING: AWS CLI install failed (no internet) - skipping' }"
            ]
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "InstallSSMS"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands = [
              "$ErrorActionPreference = 'Stop'",
              "try {",
              "  $ssmsReg = Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like '*SQL Server Management Studio*' -and $_.DisplayName -notlike '*preview*' } | Sort-Object { [version]($_.DisplayVersion -replace '[^0-9.]','') } -Descending | Select-Object -First 1",
              "  $targetMajor = 20",
              "  if ($ssmsReg) {",
              "    $installedVersion = $ssmsReg.DisplayVersion",
              "    Write-Host \"SSMS already installed: $($ssmsReg.DisplayName) v$installedVersion\"",
              "    try {",
              "      $instVer = [version]($installedVersion -replace '[^0-9.]','')",
              "      if ($instVer.Major -ge $targetMajor) {",
              "        Write-Host \"Installed SSMS ($instVer) is v$($instVer.Major) (>= $targetMajor) - skipping install.\"",
              "        exit 0",
              "      }",
              "      Write-Host \"Installed SSMS ($instVer) is older than target major version $targetMajor - upgrading.\"",
              "    } catch {",
              "      Write-Host \"Could not parse version, proceeding with install: $_\"",
              "    }",
              "  } else {",
              "    Write-Host 'SSMS not installed. Downloading and installing SSMS 22...'",
              "  }",
              "  # Prepare a clean temp directory for the VS Installer bootstrapper.",
              "  $ssmsTemp = 'C:\\aoag\\ssms_temp'",
              "  if (Test-Path $ssmsTemp) { Remove-Item $ssmsTemp -Recurse -Force -ErrorAction SilentlyContinue }",
              "  New-Item -Path $ssmsTemp -ItemType Directory -Force | Out-Null",
              "  $env:TEMP = $ssmsTemp; $env:TMP = $ssmsTemp",
              "",
              "  # Strategy: use offline layout if available, otherwise download bootstrapper",
              "  # and create a local layout before installing.",
              "  # Offline layout approach per: https://learn.microsoft.com/en-us/ssms/install/create-offline",
              "  $offlineLayout = 'C:\\aoag\\ssms_offline'",
              "  $installerPath = $null",
              "",
              "  if (Test-Path \"$offlineLayout\\vs_SSMS.exe\") {",
              "    # Path 1: Pre-staged offline layout from S3 (SSMS*.zip extracted earlier)",
              "    Write-Host 'SSMS offline layout detected at C:\\aoag\\ssms_offline - installing from local layout (no internet required).'",
              "    $installerPath = \"$offlineLayout\\vs_SSMS.exe\"",
              "  } else {",
              "    # Path 2: Download bootstrapper, create layout locally, then install from layout",
              "    Write-Host 'No offline layout found - downloading SSMS bootstrapper and creating local layout.'",
              "    $downloadUrl = 'https://aka.ms/ssms/22'",
              "    $bootstrapperPath = 'C:\\aoag\\vs_SSMS.exe'",
              "    Write-Host \"Downloading bootstrapper from $downloadUrl ...\"",
              "    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12",
              "    Invoke-WebRequest -Uri $downloadUrl -OutFile $bootstrapperPath -UseBasicParsing -MaximumRedirection 10 -ErrorAction Stop",
              "    if (-not (Test-Path $bootstrapperPath)) { throw 'SSMS bootstrapper download failed.' }",
              "    Unblock-File -Path $bootstrapperPath -ErrorAction SilentlyContinue",
              "    $fileSize = (Get-Item $bootstrapperPath).Length / 1MB",
              "    Write-Host \"Downloaded bootstrapper: $([math]::Round($fileSize,2)) MB\"",
              "",
              "    # Create offline layout with all components (same as: vs_SSMS.exe --layout C:\\path --all)",
              "    Write-Host \"Creating SSMS offline layout at $offlineLayout ...\"",
              "    $layoutProc = Start-Process -FilePath $bootstrapperPath -ArgumentList \"--layout $offlineLayout --all --wait --quiet\" -Wait -PassThru",
              "    Write-Host \"Layout creation exit code: $($layoutProc.ExitCode)\"",
              "    if ($layoutProc.ExitCode -ne 0 -and $layoutProc.ExitCode -ne 3010) {",
              "      Write-Host \"WARNING: Layout creation returned code $($layoutProc.ExitCode) - attempting install anyway.\"",
              "    }",
              "    Remove-Item $bootstrapperPath -Force -ErrorAction SilentlyContinue",
              "",
              "    if (Test-Path \"$offlineLayout\\vs_SSMS.exe\") {",
              "      $installerPath = \"$offlineLayout\\vs_SSMS.exe\"",
              "      Write-Host \"Layout created successfully - installing from $installerPath\"",
              "    } else {",
              "      throw 'SSMS layout creation failed - vs_SSMS.exe not found in layout directory.'",
              "    }",
              "  }",
              "",
              "  # Install from the offline layout",
              "  $installArgs = '--quiet --wait --norestart'",
              "  Write-Host \"Running: $installerPath $installArgs\"",
              "  $maxAttempts = 2",
              "  for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {",
              "    $proc = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru",
              "    Write-Host \"SSMS installer exit code: $($proc.ExitCode) (attempt $attempt)\"",
              "    if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) {",
              "      Write-Host 'SSMS 22 install completed successfully.'",
              "      break",
              "    } elseif ($proc.ExitCode -eq 3016) {",
              "      Write-Host 'WARNING: SSMS install requires a reboot first (3016) - will be available after next reboot.'",
              "      break",
              "    } elseif ($attempt -lt $maxAttempts) {",
              "      Write-Host 'Retrying SSMS install after 30 second wait...'",
              "      Start-Sleep -Seconds 30",
              "    } else {",
              "      Write-Host \"WARNING: SSMS install failed after $maxAttempts attempts with code $($proc.ExitCode) - non-fatal, continuing.\"",
              "    }",
              "  }",
              "  Remove-Item $ssmsTemp -Recurse -Force -ErrorAction SilentlyContinue",
              "} catch {",
              "  Write-Host \"WARNING: SSMS install failed: $($_.Exception.Message) - non-fatal, continuing.\"",
              "}"
            ]
            executionTimeout = ["1800"]
          }
        }
        onFailure = "Continue"
      },
      {
        name   = "UpdateDNSSuffix"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands         = ["powershell.exe -Command 'C:\\aoag\\scripts\\common\\Update-DNSSuffixSearchList.ps1 -DomainDNSName ''{{ DomainDNSName }}'' ';if(!$?){exit 100}"]
            executionTimeout = "120"
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "JoinDomainAndRename"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands         = ["powershell.exe -Command 'C:\\aoag\\scripts\\common\\Domain-Join-Rename.ps1 -DomainDNSName ''{{ DomainDNSName }}'' -HostName ''{{ HostName }}'' -AdminSecret {{ DomainAdminSecretName }} -DomainAdminUser {{ DomainAdminUser }} ';if(!$?){exit 100}"]
            executionTimeout = "600"
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "RestartAfterDomainJoin"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands         = ["powershell.exe -Command 'C:\\aoag\\scripts\\common\\Restart-Computer.ps1';if(!$?){exit 100}"]
            executionTimeout = "120"
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "WaitAfterDomainJoin"
        action = "aws:sleep"
        inputs = { Duration = "PT4M" }
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
        name   = "OpenWSFCPorts"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands         = ["powershell.exe -ExecutionPolicy RemoteSigned -Command 'C:\\aoag\\scripts\\common\\OpenWSFCPorts.ps1';if(!$?){exit 100}"]
            executionTimeout = "120"
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "AddDomainAdminToLocalGroup"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands         = ["powershell.exe -ExecutionPolicy RemoteSigned -Command 'C:\\aoag\\scripts\\common\\AddUserToGroup.ps1 -Members ''{{ WindowsADMembers }}'' -DomainDNSName ''{{ DomainDNSName }}'' -GroupName {{ WindowsLocalGroup }} ';if(!$?){exit 100}"]
            executionTimeout = "120"
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "CreateSQLServiceAccount"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands         = ["powershell.exe -Command 'C:\\aoag\\scripts\\common\\Create-ADServiceAccount.ps1 -DomainAdminUser {{ DomainAdminUser }} -DomainAdminSecretKey {{ DomainAdminSecretName }} -DomainDNSName ''{{ DomainDNSName }}'' -ServiceAccountUser {{ SQLAdminAccounts }} -ServiceAccountSecretKey {{ SQLServiceAccountKey }} ';if(!$?){exit 100}"]
            executionTimeout = "300"
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "WaitForADReplication"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands         = ["powershell.exe -ExecutionPolicy RemoteSigned -Command 'C:\\aoag\\scripts\\common\\Test-ADUser.ps1 -UserName {{ SQLAdminAccounts }} -Wait -TimeoutMinutes 60 -IntervalMinutes 1';if(!$?){exit 100}"]
            executionTimeout = "3900"
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "AddSQLServiceAccountToLocalGroup"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands         = ["powershell.exe -ExecutionPolicy RemoteSigned -Command 'C:\\aoag\\scripts\\common\\AddUserToGroup.ps1 -Members ''{{ SQLAdminAccounts }}'' -DomainDNSName ''{{ DomainDNSName }}'' -GroupName ''Administrators'' ';if(!$?){exit 100}"]
            executionTimeout = "120"
          }
        }
        onFailure = "step:sleepend"
      },
      {
        name   = "SetDomainTrustIdentity"
        action = "aws:runCommand"
        inputs = {
          DocumentName = "AWS-RunPowerShellScript"
          InstanceIds  = ["{{ InstanceId }}"]
          Parameters = {
            commands         = ["powershell.exe -Command 'C:\\aoag\\scripts\\common\\SetDomain-TrustIdentity.ps1 -DomainDNSName ''{{ DomainDNSName }}'' -AdminSecret {{ DomainAdminSecretName }} -DomainAdminUser {{ DomainAdminUser }}';if(!$?){exit 100}"]
            executionTimeout = "300"
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
