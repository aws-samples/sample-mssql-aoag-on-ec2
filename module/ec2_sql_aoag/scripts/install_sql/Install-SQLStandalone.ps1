# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

<#
.SYNOPSIS
    Installs SQL Server as a standalone instance for AOAG.
.DESCRIPTION
    Plain PowerShell - no DSC, no LCM, no AWSLaunchWizard.
    Uses ACTION=Install (not PrepareFailoverCluster like FCI).
    SQL 2022+ removed CONN as a separate feature.

    Supports two deployment modes:
      1. License-included AMI: setup.exe pre-installed at C:\SQLServerSetup\setup.exe
      2. BYOL: SQL media zip downloaded from S3 and extracted by node_common SSM doc
         to C:\SQLServerSetup\setup.exe (same path, different source)

    For BYOL, the AMI is a plain Windows Server image (no pre-installed SQL).
    The DisableDefaultInstance step in the SSM doc handles both modes gracefully.
    This script runs inside a CredSSP session (domain admin) from the SSM doc.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdminSecret,

    [Parameter(Mandatory = $true)]
    [string]$SqlUserSecret,

    [Parameter(Mandatory = $true)]
    [string]$AMIID,

    [Parameter(Mandatory = $true)]
    [string]$DomainAdminUser,

    [Parameter(Mandatory = $true)]
    [string]$DomainDNSName,

    [Parameter(Mandatory = $true)]
    [string]$SQLConfigBase64,

    [Parameter(Mandatory = $true)]
    [string]$Features,

    [Parameter(Mandatory = $false)]
    [string]$SQLInstanceName = 'MSSQLSERVER'
)

$ErrorActionPreference = 'Stop'
Start-Transcript -Path C:\aoag\log\Install-SQLStandalone.ps1.log -Append

try {
    Write-Host '=== Install-SQLStandalone: SQL Server Installation for AOAG ==='
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"

    # Idempotency: check if SQL instance is already installed
    $regPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'
    if (Test-Path $regPath) {
        $instanceCheck = if ($SQLInstanceName -eq 'MSSQLSERVER') { 'MSSQLSERVER' } else { $SQLInstanceName }
        $installedVal = (Get-ItemProperty $regPath -ErrorAction SilentlyContinue).$instanceCheck
        if ($installedVal) {
            Write-Host "SQL Server instance '$SQLInstanceName' is already installed - skipping installation."
            exit 0
        }
    }

    # =========================================================================
    # Retrieve credentials
    # =========================================================================
    Write-Host 'Retrieving domain admin credentials...'
    $adminSecretObj = ConvertFrom-Json (Get-SECSecretValue -SecretId $AdminSecret -ErrorAction Stop).SecretString
    $netbios = ($DomainDNSName -split '\.')[0].ToUpper()
    $domainAdmin = $netbios + '\' + $DomainAdminUser
    Write-Host "Domain admin: $domainAdmin"

    Write-Host 'Retrieving SQL service account credentials...'
    $sqlSecretObj = ConvertFrom-Json (Get-SECSecretValue -SecretId $SqlUserSecret -ErrorAction Stop).SecretString
    $sqlSvcUser = $netbios + '\' + $sqlSecretObj.username
    $sqlSvcPass = $sqlSecretObj.password
    Write-Host "SQL service account: $sqlSvcUser"

    # =========================================================================
    # Decode SQL configuration from Base64
    # =========================================================================
    Write-Host 'Decoding SQL configuration...'
    $configJson = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($SQLConfigBase64))
    Write-Host "SQL Config decoded: $configJson"
    $config = $configJson | ConvertFrom-Json

    $INSTALLSHAREDDIR    = $config.INSTALLSHAREDDIR
    $INSTALLSHAREDWOWDIR = $config.INSTALLSHAREDWOWDIR
    $INSTANCEDIR         = $config.INSTANCEDIR
    $INSTALLSQLDATADIR   = $config.INSTALLSQLDATADIR
    $SQLUSERDBDIR        = $config.SQLUSERDBDIR
    $SQLUSERDBLOGDIR     = $config.SQLUSERDBLOGDIR
    $SQLTEMPDBDIR        = $config.SQLTEMPDBDIR
    $SQLTEMPDBLOGDIR     = $config.SQLTEMPDBLOGDIR

    # =========================================================================
    # Create required directories
    # =========================================================================
    Write-Host 'Creating SQL Server directories...'
    $directories = @(
        $INSTALLSHAREDDIR,
        $INSTALLSHAREDWOWDIR,
        $INSTANCEDIR,
        $INSTALLSQLDATADIR,
        $SQLUSERDBDIR,
        $SQLUSERDBLOGDIR,
        $SQLTEMPDBDIR,
        $SQLTEMPDBLOGDIR
    )
    foreach ($dir in $directories) {
        if ($dir -and -not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  Created: $dir"
        }
    }

    # =========================================================================
    # Build setup.exe arguments
    # ACTION=Install for standalone AOAG (not PrepareFailoverCluster like FCI)
    # No CONN feature - SQL 2022 removed it. Shared components come from AMI.
    # =========================================================================
    Write-Host 'Building SQL Server setup arguments...'
    Write-Host "SQL Instance: $SQLInstanceName | Features: $Features"

    $sysAdminAccounts = $DomainDNSName + '\' + $DomainAdminUser

    $setupArgs = @(
        '/ACTION="Install"',
        ('/INSTANCEID="{0}"' -f $SQLInstanceName),
        ('/INSTANCENAME="{0}"' -f $SQLInstanceName),
        ('/FEATURES="{0}"' -f $Features),
        ('/AGTSVCACCOUNT="{0}"' -f $sqlSvcUser),
        ('/AGTSVCPASSWORD="{0}"' -f $sqlSvcPass),
        '/AGTSVCSTARTUPTYPE="Automatic"',
        ('/SQLSVCACCOUNT="{0}"' -f $sqlSvcUser),
        ('/SQLSVCPASSWORD="{0}"' -f $sqlSvcPass),
        '/SQLSVCSTARTUPTYPE="Automatic"',
        '/SQLSVCINSTANTFILEINIT="True"',
        ('/SQLSYSADMINACCOUNTS="{0}"' -f $sysAdminAccounts),
        ('/INSTALLSHAREDDIR="{0}"' -f $INSTALLSHAREDDIR),
        ('/INSTALLSHAREDWOWDIR="{0}"' -f $INSTALLSHAREDWOWDIR),
        ('/INSTANCEDIR="{0}"' -f $INSTANCEDIR),
        ('/INSTALLSQLDATADIR="{0}"' -f $INSTALLSQLDATADIR),
        ('/SQLUSERDBDIR="{0}"' -f $SQLUSERDBDIR),
        ('/SQLUSERDBLOGDIR="{0}"' -f $SQLUSERDBLOGDIR),
        ('/SQLTEMPDBDIR="{0}"' -f $SQLTEMPDBDIR),
        ('/SQLTEMPDBLOGDIR="{0}"' -f $SQLTEMPDBLOGDIR),
        '/TCPENABLED="1"',
        '/NPENABLED="0"',
        '/ENU="True"',
        '/QUIET="True"',
        '/INDICATEPROGRESS="False"',
        '/IAcceptSQLServerLicenseTerms="True"',
        '/SUPPRESSPRIVACYSTATEMENTNOTICE="True"',
        '/UpdateEnabled="False"',
        '/UpdateSource="MU"',
        '/USEMICROSOFTUPDATE="False"'
    )

    # License check: License-included AMI vs BYOL
    # RunInstances:0002 = SQL license-included AMI (suppress paid edition notice)
    # RunInstances (or other) = BYOL / plain Windows AMI (no special flags needed)
    try {
        $amiUsage = (Get-EC2Image $AMIID -ErrorAction Stop).UsageOperation
        Write-Host "AMI UsageOperation: $amiUsage"
        if ($amiUsage -eq 'RunInstances:0002') {
            $setupArgs += '/SUPPRESSPAIDEDITIONNOTICE="True"'
            $setupArgs += '/IACCEPTROPENLICENSETERMS="False"'
            Write-Host 'License-included AMI detected - adding license suppression flags.'
        } else {
            Write-Host 'BYOL / plain Windows AMI detected - no license suppression flags needed.'
        }
    } catch {
        Write-Host "WARNING: Could not check AMI license type: $($_.Exception.Message) - proceeding without license flags."
    }

    $setupArgsString = $setupArgs -join ' '

    # =========================================================================
    # Execute setup.exe
    # =========================================================================
    Write-Host 'Starting SQL Server installation...'
    $setupExe = 'C:\SQLServerSetup\setup.exe'
    if (-not (Test-Path $setupExe)) {
        throw "SQL Server setup media not found at $setupExe"
    }

    $installProc = Start-Process -FilePath $setupExe -ArgumentList $setupArgsString -Wait -PassThru -WindowStyle Hidden
    $exitCode = $installProc.ExitCode
    Write-Host "SQL Server standalone installation completed. Exit code: $exitCode"

    # Clean up sensitive data
    Remove-Variable -Name setupArgsString, sqlSvcPass -ErrorAction SilentlyContinue
    [System.GC]::Collect()

    # Exit code handling: 0 = success, 3010 = success pending reboot
    if ($exitCode -ne 0 -and $exitCode -ne 3010) {
        Write-Host 'Check SQL setup logs: C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log'
        throw "SQL Server installation failed with exit code: $exitCode"
    }

    if ($exitCode -eq 3010) {
        Write-Host 'Exit code 3010: Success, reboot required (will be handled by SSM workflow).'
    }

    Write-Host '=== Install-SQLStandalone completed successfully ==='
}
catch {
    Write-Error "Install-SQLStandalone FAILED: $_"
    Write-Host "Exception: $($_.Exception.Message)"
    Write-Host "Stack: $($_.ScriptStackTrace)"
    throw $_
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
