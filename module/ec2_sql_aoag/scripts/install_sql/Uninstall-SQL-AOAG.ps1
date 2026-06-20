# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AMIID,

    [Parameter(Mandatory = $false)]
    [string]$SQLInstanceName = "MSSQLSERVER"
)

function Get-InstalledSQLInstanceName {
    $sqlInstances = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server" -ErrorAction SilentlyContinue
    if ($sqlInstances -and $sqlInstances.InstalledInstances) {
        return $sqlInstances.InstalledInstances | Select-Object -First 1
    }
    return $null
}

function Get-InstalledSoftwareFromRegistry {
    [CmdletBinding()]
    [OutputType([PSObject[]])]
    param(
        [Parameter(Mandatory = $True)]
        [string]$Path,
        [Parameter(Mandatory = $True)]
        [string]$DisplayName
    )
    $ChildItemList = New-Object System.Collections.Generic.List[PSObject]
    Get-ChildItem -Path $Path | Get-ItemProperty | Where-Object { $_.DisplayName -match $DisplayName } | ForEach-Object { $ChildItemList.Add($_) }
    return $ChildItemList.ToArray()
}

function Uninstall-SoftwareFromRegistryValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)][switch]$IsSqlNativeClient,
        [Parameter(Mandatory = $false)][switch]$PassiveFlagOnly,
        [Parameter(Mandatory = $True)][PSObject[]]$SoftwareUninstallList
    )
    foreach ($Application in $SoftwareUninstallList) {
        try {
            $UninstallString = $Application.UninstallString
            if ($UninstallString.StartsWith("MsiExec.exe /I", "CurrentCultureIgnoreCase")) {
                $RegexForKeyName = "{[A-Z0-9]{8}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{12}}"
                $UninstallKeyName = [regex]::matches($UninstallString, $RegexForKeyName).value
                if ($null -ne $UninstallKeyName) {
                    if ($PassiveFlagOnly.IsPresent) {
                        $arguments = "/X", "$UninstallKeyName", "/passive"
                    } else {
                        $arguments = "/X", "$UninstallKeyName", "/passive", "/qn"
                    }
                    try { Start-Process 'msiexec.exe' -ArgumentList $arguments -Wait -NoNewWindow }
                    catch { Write-Error ('Error uninstalling software: ' + $_.Exception.Message) }
                }
            } else {
                try { cmd.exe /c "$UninstallString /passive /qn" }
                catch { Write-Error ('Error uninstalling software: ' + $_.Exception.Message) }
            }
        } catch {
            throw ('Exception caught while attempting to uninstall software. ' + $_.Exception.Message)
        }
    }
}

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\aoag\log\Uninstall-SQL-AOAG.ps1.log -Append

try {
    if (-Not (Test-Path "HKLM:\Software\Microsoft\Microsoft SQL Server\*\SQL")) {
        Write-Output "SQL Installation not found - nothing to uninstall"
        exit 0
    }

    Write-Output "=== Uninstall-SQL-AOAG: SQL Server Uninstall ==="
    Write-Output "Running on node: $env:COMPUTERNAME ($(hostname))"
    Write-Output "SQL Installation found"
    Write-Output "AOAG deployment - uninstalling pre-installed SQL Server"

    $detectedInstance = Get-InstalledSQLInstanceName
    if ($detectedInstance) {
        Write-Output "Detected installed SQL instance: $detectedInstance (provided: $SQLInstanceName)"
        if ($detectedInstance -ne $SQLInstanceName) {
            Write-Output "Using detected instance name for uninstall"
            $SQLInstanceName = $detectedInstance
        }
    }

    Write-Output "Uninstalling SQL Server instance: $SQLInstanceName"

    # Capture ALL SQL install paths from registry BEFORE uninstall.
    # setup.exe /ACTION=Uninstall may remove registry keys, so we must read them now.
    $sqlRegRoot = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server"
    $instanceDirsToClean = @()
    $sharedDirsToClean = @()

    if (Test-Path $sqlRegRoot) {
        Get-ChildItem $sqlRegRoot -ErrorAction SilentlyContinue | ForEach-Object {
            $versionKey = $_.PSPath

            # Instance Setup keys (SQLDataRoot, SQLPath, SQLBinRoot, etc.)
            $setupKey = Join-Path $versionKey "Setup"
            if (Test-Path $setupKey) {
                $props = Get-ItemProperty $setupKey -ErrorAction SilentlyContinue
                @('SQLDataRoot', 'SQLPath', 'SQLProgramDir', 'SqlInstanceDir', 'SQLBinRoot') | ForEach-Object {
                    if ($props.$_) { $instanceDirsToClean += $props.$_ }
                }
                # Shared component dirs from Setup key
                @('SharedDir', 'SharedWOWDir') | ForEach-Object {
                    if ($props.$_) { $sharedDirsToClean += $props.$_ }
                }
            }

            # Tools\Setup key (shared tools paths)
            $toolsSetupKey = Join-Path $versionKey "Tools\Setup"
            if (Test-Path $toolsSetupKey) {
                $toolsProps = Get-ItemProperty $toolsSetupKey -ErrorAction SilentlyContinue
                @('SharedDir', 'SharedWOWDir', 'SQLPath', 'SQLSharePath') | ForEach-Object {
                    if ($toolsProps.$_) { $sharedDirsToClean += $toolsProps.$_ }
                }
            }
        }
    }
    $instanceDirsToClean = $instanceDirsToClean | Select-Object -Unique
    $sharedDirsToClean = $sharedDirsToClean | Select-Object -Unique
    Write-Output "Captured instance dirs: $($instanceDirsToClean -join ', ')"
    Write-Output "Captured shared dirs: $($sharedDirsToClean -join ', ')"

    $SetupPath = $null
    $PossiblePaths = @(
        "C:\SQLServerSetup\setup.exe",
        "C:\SQLServerFull\setup.exe"
    )

    $SQLVersionPaths = Get-ChildItem "C:\Program Files\Microsoft SQL Server" -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+$' } |
        Sort-Object { [int]$_.Name } -Descending

    foreach ($versionPath in $SQLVersionPaths) {
        $setupCandidate = Join-Path $versionPath.FullName "Setup Bootstrap\SQL*\setup.exe"
        $found = Get-Item $setupCandidate -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $PossiblePaths += $found.FullName }
    }

    foreach ($path in $PossiblePaths) {
        if (Test-Path $path) {
            $SetupPath = $path
            Write-Output "Found SQL Server setup at: $SetupPath"
            break
        }
    }

    if (-not $SetupPath) {
        Write-Output "SQL Server setup.exe not found in expected locations"
        Write-Output "Attempting to uninstall via Programs and Features"

        $UninstallRegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
        $SQLUninstallEntries = Get-ChildItem -Path $UninstallRegPath |
            Get-ItemProperty |
            Where-Object { $_.DisplayName -match "Microsoft SQL Server.*Database Engine" }

        if ($SQLUninstallEntries) {
            foreach ($entry in $SQLUninstallEntries) {
                Write-Output "Uninstalling: $($entry.DisplayName)"
                if ($entry.UninstallString) { cmd.exe /c "$($entry.UninstallString) /quiet" }
            }
        } else {
            Write-Output "No SQL Server uninstall entries found - may already be uninstalled"
        }
    } else {
        $arguments = '/q /ACTION="Uninstall" /SUPPRESSPRIVACYSTATEMENTNOTICE="True" /FEATURES="SQLENGINE,AS,RS,FULLTEXT,REPLICATION" /INSTANCENAME="{0}"' -f $SQLInstanceName
        Write-Output "Running: $SetupPath $arguments"

        $SQLUninstallProcess = Start-Process -FilePath $SetupPath -ArgumentList $arguments -PassThru -Wait -NoNewWindow
        Write-Output "Uninstall exit code: $($SQLUninstallProcess.ExitCode)"

        if ($SQLUninstallProcess.ExitCode -ne 0 -and $SQLUninstallProcess.ExitCode -ne 3010) {
            throw "Uninstall action failed; Exit code: $($SQLUninstallProcess.ExitCode)"
        }
    }

    # Clean up additional SQL components
    $UninstallRegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    if (Test-Path -Path $UninstallRegPath) {
        $OleDbDriverList = Get-InstalledSoftwareFromRegistry -Path $UninstallRegPath -DisplayName "Microsoft OLE DB Driver for SQL Server"
        $OdbcDriverList = Get-InstalledSoftwareFromRegistry -Path $UninstallRegPath -DisplayName "Microsoft ODBC Driver.+for SQL Server"
        $NativeClientList = Get-InstalledSoftwareFromRegistry -Path $UninstallRegPath -DisplayName "Microsoft SQL Server 2012 Native Client"

        if ($null -ne $OleDbDriverList -and $OleDbDriverList.Length -ne 0) {
            Write-Output "Uninstalling OLE DB Driver..."
            Uninstall-SoftwareFromRegistryValue -SoftwareUninstallList $OleDbDriverList
        }
        if ($null -ne $OdbcDriverList -and $OdbcDriverList.Length -ne 0) {
            Write-Output "Uninstalling ODBC Driver..."
            Uninstall-SoftwareFromRegistryValue -SoftwareUninstallList $OdbcDriverList
        }
        if ($null -ne $NativeClientList -and $NativeClientList.Length -ne 0) {
            Write-Output "Uninstalling Native Client..."
            Uninstall-SoftwareFromRegistryValue -SoftwareUninstallList $NativeClientList -IsSqlNativeClient -PassiveFlagOnly
        }
    }

    Write-Output "SQL Server uninstall completed successfully"

    # =========================================================================
    # Post-uninstall cleanup: registry keys, instance dirs, shared component dirs.
    # Uses paths captured from registry BEFORE uninstall (setup may have removed keys).
    # Also reads any remaining registry to catch anything missed.
    # =========================================================================
    Write-Output "--- Post-uninstall cleanup ---"

    # Clean instance directories (captured before uninstall)
    foreach ($dir in $instanceDirsToClean) {
        if ($dir -and (Test-Path $dir)) {
            Write-Output "Removing instance directory: $dir"
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Clean shared component Shared/Tools subdirs under each discovered shared root
    foreach ($dir in $sharedDirsToClean) {
        if (-not $dir -or -not (Test-Path $dir)) { continue }
        Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+$' } | ForEach-Object {
                $versionDir = $_.FullName
                @('Shared', 'Tools') | ForEach-Object {
                    $subDir = Join-Path $versionDir $_
                    if (Test-Path $subDir) {
                        Write-Output "Removing shared component directory: $subDir"
                        Remove-Item -Path $subDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
    }

    # Clean remaining SQL Server registry keys
    $sqlRegRoot = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server"
    if (Test-Path $sqlRegRoot) {
        # Remove instance registry keys
        $instanceNames = (Get-ItemProperty $sqlRegRoot -ErrorAction SilentlyContinue).InstalledInstances
        $instanceNamesPath = Join-Path $sqlRegRoot "Instance Names\SQL"
        if ($instanceNames -and (Test-Path $instanceNamesPath)) {
            foreach ($inst in $instanceNames) {
                $internalName = (Get-ItemProperty $instanceNamesPath -ErrorAction SilentlyContinue).$inst
                if ($internalName) {
                    $instanceKey = Join-Path $sqlRegRoot $internalName
                    if (Test-Path $instanceKey) {
                        Write-Output "Removing instance registry key: $instanceKey"
                        Remove-Item -Path $instanceKey -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
        Remove-ItemProperty -Path $sqlRegRoot -Name 'InstalledInstances' -ErrorAction SilentlyContinue
        $instNamesKey = Join-Path $sqlRegRoot "Instance Names"
        if (Test-Path $instNamesKey) {
            Remove-Item -Path $instNamesKey -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Remove ConfigurationState, SharedCode, Tools under each version key
        Get-ChildItem $sqlRegRoot -ErrorAction SilentlyContinue | ForEach-Object {
            $versionKey = $_.PSPath
            @('ConfigurationState', 'SharedCode', 'Tools') | ForEach-Object {
                $subKey = Join-Path $versionKey $_
                if (Test-Path $subKey) {
                    Write-Output "Removing registry key: $subKey"
                    Remove-Item -Path $subKey -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Write-Output "SQL Server cleanup completed"
} catch {
    Write-Error ('Error during SQL uninstall: ' + $_.Exception.Message)
    throw $_
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
