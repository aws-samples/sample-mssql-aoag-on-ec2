# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

<#
.SYNOPSIS
    Installs Windows features and PowerShell modules required for AOAG.
.DESCRIPTION
    Installs Failover-Clustering, RSAT-AD-PowerShell, .NET Framework 4.5.
    Installs SqlServer PowerShell module v21+ from PSGallery.
    Disables Windows Firewall. Reboots at the end (required by Failover-Clustering).
    Idempotent - checks existing state before each install.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Start-Transcript -Path C:\aoag\log\Install-WindowsFeatures.log -Append

try {
    Write-Host "=== Install-WindowsFeatures ==="
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"
    Write-Host "PowerShell version: $($PSVersionTable.PSVersion)"

    # -------------------------------------------------------------------------
    # Windows Features
    # -------------------------------------------------------------------------
    $requiredFeatures = @(
        'Failover-Clustering',
        'RSAT-Clustering-PowerShell',
        'RSAT-Clustering-Mgmt',
        'RSAT-AD-PowerShell',
        'NET-Framework-45-Core'
    )

    foreach ($feature in $requiredFeatures) {
        $f = Get-WindowsFeature -Name $feature
        if ($f.Installed) {
            Write-Host "$feature - already installed"
        } else {
            Write-Host "Installing $feature..."
            Install-WindowsFeature -Name $feature -IncludeManagementTools -ErrorAction Stop
            Write-Host "$feature - installed"
        }
    }

    # -------------------------------------------------------------------------
    # Windows Firewall
    # -------------------------------------------------------------------------
    # Deliberately left ENABLED. Scoped inbound rules for the AOAG/WSFC port set
    # are created later in the node_common workflow by the ConfigureAOAGFirewall
    # step, which runs Configure-AOAGFirewall.ps1 with the allowed CIDRs.
    #
    # Installing Failover-Clustering above also enables Windows' built-in
    # "Failover Clusters" rule group, so core cluster traffic is permitted from
    # this point on.
    Write-Host 'Leaving Windows Firewall enabled; scoped AOAG rules are applied by Configure-AOAGFirewall.ps1.'
    Get-NetFirewallProfile | Select-Object Name, Enabled | Format-Table -AutoSize | Out-String | Write-Host

    # -------------------------------------------------------------------------
    # PowerShell Modules - NuGet provider + SqlServer module
    # -------------------------------------------------------------------------
    Write-Host 'Setting up PowerShell modules...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # NuGet provider (required for Install-Module)
    $hasNuGet = $false
    try {
        $nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending | Select-Object -First 1
        if ($nuget -and $nuget.Version -ge [Version]'2.8.5.201') {
            Write-Host "NuGet provider already available: v$($nuget.Version)"
            $hasNuGet = $true
        } else {
            # Version pinned for the same reason as the SqlServer module below: -MinimumVersion
            # resolves to whatever the gallery serves at deploy time, including a future
            # compromised release. This provider bootstraps the module install, so it needs
            # the same supply-chain treatment.
            Install-PackageProvider -Name NuGet -RequiredVersion 2.8.5.208 -Force -ErrorAction Stop | Out-Null
            $hasNuGet = $true
            Write-Host 'NuGet provider installed.'
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    } catch {
        Write-Host "WARNING: NuGet provider install failed: $($_.Exception.Message)"
    }

    # SqlServer module (v21+ required for Enable-SqlAlwaysOn on PS 5.1)
    $sqlMod = Get-Module -Name SqlServer -ListAvailable |
        Sort-Object Version -Descending | Select-Object -First 1

    if ($sqlMod -and $sqlMod.Version.Major -ge 21) {
        Write-Host "SqlServer module already installed: v$($sqlMod.Version)"
    } elseif ($hasNuGet) {
        Write-Host 'Installing SqlServer module from PSGallery...'
        try {
            # Version pinned deliberately. An unpinned Install-Module adopts
            # whatever PSGallery serves at deploy time, so deployments are not
            # reproducible and a future compromised release would be picked up
            # automatically. Bump this after testing a newer version.
            Install-Module -Name SqlServer -RequiredVersion 22.3.0 -AllowClobber -Force -ErrorAction Stop
            $sqlMod = Get-Module -Name SqlServer -ListAvailable |
                Sort-Object Version -Descending | Select-Object -First 1
            Write-Host "SqlServer module installed: v$($sqlMod.Version)"
        } catch {
            Write-Host "WARNING: SqlServer module install failed: $($_.Exception.Message)"
        }
    } else {
        Write-Host 'WARNING: No NuGet provider - cannot install SqlServer module from PSGallery.'
    }

    # -------------------------------------------------------------------------
    # Summary - log what is available
    # -------------------------------------------------------------------------
    Write-Host ''
    Write-Host '--- Module Summary ---'
    $sqlMod = Get-Module -Name SqlServer -ListAvailable |
        Sort-Object Version -Descending | Select-Object -First 1
    $sqlps = Get-Module -Name SQLPS -ListAvailable | Select-Object -First 1

    if ($sqlMod) {
        Write-Host "SqlServer module: v$($sqlMod.Version) [OK]"
    } elseif ($sqlps) {
        Write-Host "SQLPS module: v$($sqlps.Version) [LEGACY - Enable-SqlAlwaysOn may have WMI issues]"
    } else {
        Write-Host 'WARNING: No SQL PowerShell module found. Enable-AlwaysOn will use registry fallback.'
    }

    # Verify SMO is loadable (needed by Enable-AlwaysOn, Create-AG, Join-AG scripts)
    try {
        $null = [System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.Smo')
        Write-Host 'SMO assembly: loaded [OK]'
    } catch {
        Write-Host "WARNING: SMO assembly not loadable: $($_.Exception.Message)"
    }

    Write-Host '--- Features Summary ---'
    foreach ($feature in $requiredFeatures) {
        $f = Get-WindowsFeature -Name $feature
        Write-Host "$feature : $($f.InstallState)"
    }

    Write-Host ''
    Write-Host '=== Install-WindowsFeatures completed ==='
}
catch {
    Write-Error "Install-WindowsFeatures failed: $_"
    throw $_
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}

# Reboot - Failover-Clustering feature requires it.
# Use shutdown.exe with a delay so the script process can exit cleanly (exit 0)
# before the reboot kills the SSM agent connection.
Write-Host 'Scheduling reboot in 5 seconds...'
shutdown.exe /r /t 5 /f
exit 0
