# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

<#
.SYNOPSIS
    Installs SQL Server Cumulative Update.
.DESCRIPTION
    Plain PowerShell - no DSC, no LCM, no AWSLaunchWizard.
    CU files expected at C:\aoag\sqlspcu\<version>\ (downloaded from S3).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\aoag\log\Install-sqlcu.ps1.log -Append

try {
    Write-Host "=== Install-sqlcu: SQL Server Cumulative Update ==="
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"

    $RootStatePath = "C:\aoag\sqlspcu\state.txt"
    if (Test-Path $RootStatePath) { Remove-Item $RootStatePath -Force }

    @("C:\aoag\sqlspcu\14","C:\aoag\sqlspcu\15","C:\aoag\sqlspcu\16","C:\aoag\sqlspcu\17") | ForEach-Object {
        $sf = Join-Path $_ "state.txt"
        if (Test-Path $sf) { Remove-Item $sf -Force }
    }

    $RootPathForSQL = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server"
    $SQLPatchLevel = $null

    $InstalledInstances = (Get-ItemProperty $RootPathForSQL -ErrorAction SilentlyContinue).InstalledInstances
    $SQLInstanceNamesPath = Join-Path $RootPathForSQL "Instance Names\SQL"

    if ((Test-Path $SQLInstanceNamesPath) -and ($InstalledInstances.Count -eq 1)) {
        $SQLInstanceName = (Get-ItemProperty $SQLInstanceNamesPath).$InstalledInstances
        if ($null -ne $SQLInstanceName) {
            $SetupHive = Join-Path $RootPathForSQL "$SQLInstanceName\Setup"
            if (Test-Path $SetupHive) {
                $SQLPatchLevel = (Get-ItemProperty $SetupHive).PatchLevel
            }
        }
    }

    if ($null -eq $SQLPatchLevel) {
        $versionPaths = @(
            (Join-Path $RootPathForSQL "130\SQLServer2016"),
            (Join-Path $RootPathForSQL "140\SQL2017"),
            (Join-Path $RootPathForSQL "150\SQL2019"),
            (Join-Path $RootPathForSQL "160\SQL2022"),
            (Join-Path $RootPathForSQL "170\SQL2025")
        )
        foreach ($vp in $versionPaths) {
            $cvPath = "$vp\CurrentVersion"
            if (Test-Path $cvPath) { $SQLPatchLevel = (Get-ItemProperty $cvPath).PatchLevel }
        }
    }

    if ($null -eq $SQLPatchLevel) { throw "Unable to identify installed SQL version." }
    Write-Host "Detected SQL Patch Level: $SQLPatchLevel"

    switch -regex ($SQLPatchLevel) {
        "^13" {
            Write-Host "SQL 2016 - no CU action required."
            exit 0
        }
        "^14" {
            $WorkingDirectory = "C:\aoag\sqlspcu\14"
            $CUFilename = "sql2017cu31.exe"
        }
        "^15" {
            $WorkingDirectory = "C:\aoag\sqlspcu\15"
            $CUFilename = "sql2019cu19.exe"
        }
        "^16" {
            $WorkingDirectory = "C:\aoag\sqlspcu\16"
            $cuFiles = Get-ChildItem $WorkingDirectory -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'state.txt' } | Sort-Object LastWriteTime
            if ($cuFiles) { $CUFilename = ($cuFiles | Select-Object -Last 1).Name }
        }
        "^17" {
            $WorkingDirectory = "C:\aoag\sqlspcu\17"
            $cuFiles = Get-ChildItem $WorkingDirectory -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'state.txt' } | Sort-Object LastWriteTime
            if ($cuFiles) { $CUFilename = ($cuFiles | Select-Object -Last 1).Name }
        }
        default {
            throw "No matching SQL version for: $SQLPatchLevel"
        }
    }

    if ([string]::IsNullOrEmpty($CUFilename)) {
        Write-Host "No CU file found in $WorkingDirectory - skipping CU install."
        exit 0
    }

    $CUFilePath = Join-Path $WorkingDirectory $CUFilename
    if (-not (Test-Path $CUFilePath)) {
        Write-Host "CU file $CUFilePath not found - skipping CU install."
        exit 0
    }

    $StateFile = New-Item -Path $WorkingDirectory -ItemType "File" -Name "state.txt" -Value 0 -Force -ErrorAction SilentlyContinue
    $CUFile = Get-Item $CUFilePath

    $productVersion = $CUFile.VersionInfo.ProductVersion
    if (-not $productVersion) { throw "Could not read ProductVersion from $CUFilePath" }
    Write-Host "CU Product Version: $productVersion"

    [System.Version]$SQLProductVersion = $productVersion
    [System.Version]$PatchLevel = $SQLPatchLevel

    if ($SQLProductVersion -le $PatchLevel) {
        Write-Host "Current patch level ($PatchLevel) >= CU ($SQLProductVersion). No update needed."
        exit 0
    }

    Write-Host "Updating from $PatchLevel to $SQLProductVersion..."

    $ExtractDir = Join-Path $WorkingDirectory "Setup"
    Remove-Item -Path $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path $ExtractDir -ItemType Directory -Force | Out-Null

    $extractProc = Start-Process -FilePath $CUFile.FullName -ArgumentList "/x:`"$ExtractDir`" /QUIET" -PassThru -Wait -WindowStyle Hidden
    if ($extractProc.ExitCode -ne 0) {
        Write-Host "CU extraction returned code $($extractProc.ExitCode) - trying direct execution."
        $SetupExe = $CUFile.FullName
    } else {
        $SetupExe = Join-Path $ExtractDir "Setup.exe"
        if (-not (Test-Path $SetupExe)) { $SetupExe = $CUFile.FullName }
    }

    $patchProc = Start-Process -FilePath $SetupExe `
        -ArgumentList "/QUIET /IAcceptSQLServerLicenseTerms /Action=Patch /AllInstances" `
        -PassThru -Wait -WindowStyle Hidden `
        -RedirectStandardOutput "C:\aoag\log\Install-sqlcu-PatchAllInstances.txt"

    if ($patchProc.ExitCode -ne 0 -and $patchProc.ExitCode -ne 3010) {
        throw "SQL CU patch failed with exit code: $($patchProc.ExitCode)"
    }
    Write-Host "SQL CU applied successfully. Exit code: $($patchProc.ExitCode)"

    Remove-Item -Path $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($StateFile -and (Test-Path $StateFile) -and (Get-Content $StateFile -ErrorAction SilentlyContinue) -eq '1') {
        Remove-Item $WorkingDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
catch {
    Write-Error "Install-sqlcu failed: $_"
    throw $_
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
