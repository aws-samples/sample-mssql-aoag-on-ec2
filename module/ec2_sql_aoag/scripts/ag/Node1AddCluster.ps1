# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

<#
.SYNOPSIS
    Creates a Windows Server Failover Cluster from the primary node.
.DESCRIPTION
    Plain PowerShell - no DSC, no LCM, no AWSLaunchWizard.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DomainDnsName,

    [Parameter(Mandatory = $true)]
    [string]$AdminSecret,

    [Parameter(Mandatory = $true)]
    [string]$StackName,

    [Parameter(Mandatory = $false)]
    [string]$ClusterStaticIP
)

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\aoag\log\Node1AddCluster.ps1.log -Append

try {
    Write-Host "=== Node1AddCluster: Creating WSFC Cluster ==="
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"

    # Retrieve domain admin credentials from Secrets Manager
    $SecretObj = ConvertFrom-Json -InputObject (
        Get-SECSecretValue -SecretId $AdminSecret | Select-Object -ExpandProperty 'SecretString'
    )
    $DomainNetBIOS = ($DomainDnsName -split '\.')[0].ToUpper()
    $AdminUser = "$DomainNetBIOS\$($SecretObj.username)"
    $AdminPass = ConvertTo-SecureString $SecretObj.password -AsPlainText -Force
    $AdminCred = New-Object PSCredential($AdminUser, $AdminPass)

    # Ensure Failover Clustering is installed
    if (-not (Get-WindowsFeature -Name Failover-Clustering).Installed) {
        Write-Host "Installing Failover-Clustering..."
        Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools -ErrorAction Stop
    }

    if (-not (Get-WindowsFeature -Name RSAT-AD-PowerShell).Installed) {
        Write-Host "Installing RSAT-AD-PowerShell..."
        Install-WindowsFeature -Name RSAT-AD-PowerShell -ErrorAction Stop
    }

    # Cluster name (max 15 chars NetBIOS)
    $ClusterName = $StackName
    if ($ClusterName.Length -gt 15) { $ClusterName = $ClusterName.Substring(0, 15) }

    Write-Host "Cluster Name: $ClusterName"
    Write-Host "Current Node: $env:COMPUTERNAME"

    # Check if already in a cluster
    try {
        $existing = Get-Cluster -ErrorAction Stop
        Write-Host "Already part of cluster: $($existing.Name)"
        exit 0
    } catch {
        Write-Host "Not part of any cluster - creating."
    }

    # Create cluster via CredSSP session
    $Session = New-PSSession -ComputerName $env:COMPUTERNAME -Authentication Credssp -Credential $AdminCred

    Invoke-Command -Session $Session -ScriptBlock {
        param($ClusterName, $NodeName, $StaticIP)
        if ($StaticIP) {
            Write-Host "Creating cluster with static IP: $StaticIP"
            New-Cluster -Name $ClusterName -Node $NodeName -StaticAddress $StaticIP -NoStorage -Force -ErrorAction Stop
        } else {
            New-Cluster -Name $ClusterName -Node $NodeName -NoStorage -Force -ErrorAction Stop
        }
        Write-Host "Cluster '$ClusterName' created."
        Set-ClusterQuorum -NodeMajority -ErrorAction SilentlyContinue
        Write-Host "Quorum set to Node Majority."
    } -ArgumentList $ClusterName, $env:COMPUTERNAME, $ClusterStaticIP

    Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
    Write-Host "=== Node1AddCluster completed ==="
}
catch {
    Write-Error "Node1AddCluster failed: $_"
    throw $_
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
