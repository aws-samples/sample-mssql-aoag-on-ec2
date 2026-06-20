# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

<#
.SYNOPSIS
    Joins a secondary node to an existing WSFC cluster.
.DESCRIPTION
    Plain PowerShell - no DSC, no LCM, no AWSLaunchWizard.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdminSecret,

    [Parameter(Mandatory = $true)]
    [string]$DomainAdminUser,

    [Parameter(Mandatory = $true)]
    [string]$DomainDNSName,

    [Parameter(Mandatory = $false)]
    [string]$ClusterName,

    [Parameter(Mandatory = $false)]
    [string]$PrimaryNodeName
)

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\aoag\log\AdditionalNodeAddCluster.ps1.log -Append

try {
    Write-Host "=== AdditionalNodeAddCluster: Joining node to cluster ==="
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"

    $SecretObj = ConvertFrom-Json -InputObject (
        Get-SECSecretValue -SecretId $AdminSecret | Select-Object -ExpandProperty 'SecretString'
    )
    $DomainNetBIOS = ($DomainDNSName -split '\.')[0].ToUpper()
    $AdminUser = "$DomainNetBIOS\$DomainAdminUser"
    $AdminPass = ConvertTo-SecureString $SecretObj.password -AsPlainText -Force
    $AdminCred = New-Object PSCredential($AdminUser, $AdminPass)

    if (-not (Get-WindowsFeature -Name Failover-Clustering).Installed) {
        Write-Host "Installing Failover-Clustering..."
        Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools -ErrorAction Stop
    }

    if (-not (Get-WindowsFeature -Name RSAT-AD-PowerShell).Installed) {
        Write-Host "Installing RSAT-AD-PowerShell..."
        Install-WindowsFeature -Name RSAT-AD-PowerShell -ErrorAction Stop
    }

    try {
        $existing = Get-Cluster -ErrorAction Stop
        Write-Host "Already part of cluster: $($existing.Name) - skipping."
        exit 0
    } catch {
        Write-Host "Not part of any cluster - joining."
    }

    $Session = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $AdminCred

    Invoke-Command -Session $Session -ScriptBlock {
        param($NodeName, $ClusterName, $PrimaryNodeName)

        # Determine cluster target for Add-ClusterNode
        # Priority: 1) Discover via Get-Cluster -Domain, 2) Use PrimaryNodeName as fallback
        $clusterTarget = $null

        Write-Host "Discovering cluster to join..."
        $maxRetries = 10
        $retryCount = 0

        while ($null -eq $clusterTarget -and $retryCount -lt $maxRetries) {
            try {
                # If ClusterName is provided, use it directly instead of blind discovery
                if ($ClusterName) {
                    try {
                        $dnsResult = [System.Net.Dns]::GetHostAddresses($ClusterName)
                        $clusterTarget = $ClusterName
                        Write-Host "Using specified cluster name: $clusterTarget (resolves to $($dnsResult.IPAddressToString -join ', '))"
                    } catch {
                        Write-Host "Specified cluster '$ClusterName' does not resolve yet - retry $($retryCount+1)/$maxRetries..."
                        $retryCount++
                        Start-Sleep -Seconds 30
                        continue
                    }
                } else {
                    # Fallback: discover clusters in domain (legacy behavior)
                    $clusters = Get-Cluster -Domain $env:USERDNSDOMAIN -ErrorAction Stop
                    if ($clusters) {
                        $clusterObj = $clusters | Select-Object -First 1
                        $clusterTarget = $clusterObj.Name
                        Write-Host "Found cluster via discovery: $clusterTarget"

                        try {
                            $dnsResult = [System.Net.Dns]::GetHostAddresses($clusterTarget)
                            Write-Host "Cluster CNO resolves to: $($dnsResult.IPAddressToString -join ', ')"
                        } catch {
                            Write-Host "Cluster CNO '$clusterTarget' does not resolve in DNS - falling back to primary node name"
                            if ($PrimaryNodeName) {
                                $clusterTarget = $PrimaryNodeName
                                Write-Host "Using primary node name as cluster target: $clusterTarget"
                            }
                        }
                    }
                }
            } catch {
                $retryCount++
                Write-Host "Retry $retryCount/$maxRetries - waiting for cluster discovery..."
                Start-Sleep -Seconds 30
            }
        }

        # Final fallback to primary node name
        if ($null -eq $clusterTarget -and $PrimaryNodeName) {
            $clusterTarget = $PrimaryNodeName
            Write-Host "Using primary node name as cluster target (fallback): $clusterTarget"
        }

        if ($null -eq $clusterTarget) {
            throw "Could not discover any cluster in the domain after $maxRetries retries and no PrimaryNodeName provided."
        }

        # Retry Add-ClusterNode in case of transient failures
        $addRetry = 0
        $addMaxRetries = 5
        while ($addRetry -lt $addMaxRetries) {
            try {
                $addRetry++
                Write-Host "Adding node '$NodeName' to cluster '$clusterTarget' (attempt $addRetry of $addMaxRetries)..."
                Add-ClusterNode -Name $NodeName -Cluster $clusterTarget -NoStorage -ErrorAction Stop
                Write-Host "Node '$NodeName' added to cluster successfully."
                break
            } catch {
                Write-Host "Add-ClusterNode failed: $($_.Exception.Message)"
                if ($addRetry -lt $addMaxRetries) {
                    Write-Host "Waiting 30 seconds before retry..."
                    Start-Sleep -Seconds 30
                } else {
                    throw "Failed to add node to cluster after $addMaxRetries attempts: $($_.Exception.Message)"
                }
            }
        }
    } -ArgumentList $env:COMPUTERNAME, $ClusterName, $PrimaryNodeName

    Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
    Write-Host "=== AdditionalNodeAddCluster completed ==="
}
catch {
    Write-Error "AdditionalNodeAddCluster failed: $_"
    throw $_
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}