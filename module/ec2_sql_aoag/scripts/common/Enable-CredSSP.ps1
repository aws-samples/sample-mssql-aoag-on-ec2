# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$DomainNetBIOSName,

    [Parameter(Mandatory = $false)]
    [string]$DomainDNSName,

    [Parameter(Mandatory = $false)]
    [string]$ServerName = '*',

    [Parameter(Mandatory = $false)]
    [int]$MaxRetries = 5,

    [Parameter(Mandatory = $false)]
    [int]$RetryDelaySeconds = 30
)

function Add-RegistryEntry {
    param(
        [Parameter(Mandatory = $true)][string]$KeyPath,
        [Parameter(Mandatory = $true)][string]$KeyName
    )
    $FullPath = Join-Path $KeyPath $KeyName
    if (-Not (Test-Path -Path $FullPath)) {
        New-Item -Path $FullPath -Force -ErrorAction SilentlyContinue | Out-Null
        # Retry validation - GPO or antivirus can delay registry writes
        $retries = 0
        while ($retries -lt 5 -and -not (Test-Path -Path $FullPath)) {
            $retries++
            Write-Host "Waiting for registry key $FullPath (attempt $retries)..."
            Start-Sleep -Seconds 3
            # Re-create if still missing
            New-Item -Path $FullPath -Force -ErrorAction SilentlyContinue | Out-Null
        }
        if (-Not (Test-Path -Path $FullPath)) {
            Write-Warning "Registry key $FullPath could not be validated - continuing anyway"
        }
    }
}

function Wait-ForWinRM {
    param([int]$TimeoutSeconds = 120)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try {
            $winrmService = Get-Service -Name WinRM -ErrorAction Stop
            if ($winrmService.Status -eq 'Running') {
                $listeners = winrm enumerate winrm/config/listener 2>&1
                if ($listeners -notlike "*WSManFault*" -and $listeners -notlike "*Error*") {
                    Write-Output "WinRM is ready"
                    return $true
                }
            }
        } catch { Write-Output "Waiting for WinRM service..." }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Enable-CredSSPWithRetry {
    param(
        [string]$DelegateComputer,
        [string]$Role,
        [int]$MaxRetries,
        [int]$RetryDelaySeconds
    )
    $attempt = 0
    $success = $false
    while (-not $success -and $attempt -lt $MaxRetries) {
        $attempt++
        try {
            Write-Output "Attempt $attempt of $MaxRetries`: Enabling CredSSP $Role for $DelegateComputer..."
            if ($Role -eq "Client") {
                Enable-WSManCredSSP -Role Client -DelegateComputer $DelegateComputer -Force -ErrorAction Stop
            } else {
                Enable-WSManCredSSP -Role Server -Force -ErrorAction Stop
            }
            $success = $true
            Write-Output "Successfully enabled CredSSP $Role"
        } catch {
            Write-Warning "Attempt $attempt failed: $($_.Exception.Message)"
            if ($attempt -lt $MaxRetries) {
                Write-Output "Waiting $RetryDelaySeconds seconds before retry..."
                Start-Sleep -Seconds $RetryDelaySeconds
                try { Restart-Service WinRM -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 10 }
                catch { Write-Warning "Could not restart WinRM: $($_.Exception.Message)" }
            } else {
                throw "Failed to enable CredSSP $Role after $MaxRetries attempts: $($_.Exception.Message)"
            }
        }
    }
    return $success
}

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\aoag\log\EnableCredSsp.ps1.txt -Append

try {
    Write-Host "=== Enable-CredSSP: Configuring CredSSP ==="
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"

    # Ensure network profile is not Public
    $networkProfiles = Get-NetConnectionProfile -ErrorAction SilentlyContinue
    foreach ($profile in $networkProfiles) {
        if ($profile.NetworkCategory -eq 'Public') {
            Set-NetConnectionProfile -InterfaceAlias $profile.InterfaceAlias -NetworkCategory Private -ErrorAction SilentlyContinue
        }
    }

    # Ensure WinRM service is running
    $winrmService = Get-Service -Name WinRM -ErrorAction SilentlyContinue
    if ($null -eq $winrmService) { throw "WinRM service not found" }
    if ($winrmService.Status -ne 'Running') {
        Set-Service -Name WinRM -StartupType Automatic
        Start-Service -Name WinRM
        Start-Sleep -Seconds 10
    }

    if (-not (Wait-ForWinRM -TimeoutSeconds 120)) {
        Write-Warning "WinRM may not be fully ready, attempting to configure anyway..."
        winrm quickconfig -quiet 2>&1 | Out-Null
        Start-Sleep -Seconds 10
    }

    Enable-CredSSPWithRetry -DelegateComputer $ServerName -Role "Client" -MaxRetries $MaxRetries -RetryDelaySeconds $RetryDelaySeconds
    if ($DomainNetBIOSName) { Enable-CredSSPWithRetry -DelegateComputer "*.$DomainNetBIOSName" -Role "Client" -MaxRetries $MaxRetries -RetryDelaySeconds $RetryDelaySeconds }
    if ($DomainDNSName) { Enable-CredSSPWithRetry -DelegateComputer "*.$DomainDNSName" -Role "Client" -MaxRetries $MaxRetries -RetryDelaySeconds $RetryDelaySeconds }
    Enable-CredSSPWithRetry -DelegateComputer "" -Role "Server" -MaxRetries $MaxRetries -RetryDelaySeconds $RetryDelaySeconds

    # Registry entries for CredSSP delegation policy.
    # After domain join + reboot, GPO may still be processing the Policies hive,
    # causing "registry key marked for deletion" errors. Retry with backoff.
    $regMaxRetries = 10
    $regRetryDelay = 15
    for ($regAttempt = 1; $regAttempt -le $regMaxRetries; $regAttempt++) {
        try {
            Write-Host "Configuring CredSSP registry delegation (attempt $regAttempt/$regMaxRetries)..."

            # Force a GPO refresh and wait for it to settle before touching the Policies hive
            if ($regAttempt -eq 1) {
                gpupdate /force /wait:0 2>&1 | Out-Null
                Start-Sleep -Seconds 5
            }

            $ParentKey = "hklm:\SOFTWARE\Policies\Microsoft\Windows"
            $CredDelegationKey = "$ParentKey\CredentialsDelegation"
            $AllowFreshKey = "$CredDelegationKey\AllowFreshCredentials"
            $AllowFreshNTLMKey = "$CredDelegationKey\AllowFreshCredentialsWhenNTLMOnly"

            Add-RegistryEntry -KeyPath $ParentKey -KeyName 'CredentialsDelegation'
            New-ItemProperty -Path $CredDelegationKey -Name AllowFreshCredentials -Value 1 -PropertyType Dword -Force | Out-Null
            New-ItemProperty -Path $CredDelegationKey -Name ConcatenateDefaults_AllowFresh -Value 1 -PropertyType Dword -Force | Out-Null
            New-ItemProperty -Path $CredDelegationKey -Name AllowFreshCredentialsWhenNTLMOnly -Value 1 -PropertyType Dword -Force | Out-Null
            New-ItemProperty -Path $CredDelegationKey -Name ConcatenateDefaults_AllowFreshNTLMOnly -Value 1 -PropertyType Dword -Force | Out-Null

            Add-RegistryEntry -KeyPath $CredDelegationKey -KeyName 'AllowFreshCredentials'
            Add-RegistryEntry -KeyPath $CredDelegationKey -KeyName 'AllowFreshCredentialsWhenNTLMOnly'

            New-ItemProperty -Path $AllowFreshKey -Name 1 -Value "WSMAN/$ServerName" -PropertyType String -Force | Out-Null
            New-ItemProperty -Path $AllowFreshNTLMKey -Name 1 -Value "WSMAN/$ServerName" -PropertyType String -Force | Out-Null

            if ($DomainNetBIOSName) {
                New-ItemProperty -Path $AllowFreshKey -Name 2 -Value "WSMAN/*.$DomainNetBIOSName" -PropertyType String -Force | Out-Null
                New-ItemProperty -Path $AllowFreshNTLMKey -Name 2 -Value "WSMAN/*.$DomainNetBIOSName" -PropertyType String -Force | Out-Null
            }
            if ($DomainDNSName) {
                New-ItemProperty -Path $AllowFreshKey -Name 3 -Value "WSMAN/*.$DomainDNSName" -PropertyType String -Force | Out-Null
                New-ItemProperty -Path $AllowFreshNTLMKey -Name 3 -Value "WSMAN/*.$DomainDNSName" -PropertyType String -Force | Out-Null
            }

            Write-Host "CredSSP registry delegation configured successfully."
            break
        } catch {
            if ($_.Exception.Message -match 'marked for deletion') {
                Write-Host "Registry hive busy (GPO processing) - attempt $regAttempt/$regMaxRetries, retrying in ${regRetryDelay}s..."
                if ($regAttempt -lt $regMaxRetries) {
                    Start-Sleep -Seconds $regRetryDelay
                } else {
                    throw "CredSSP registry configuration failed after $regMaxRetries attempts: $_"
                }
            } else {
                throw
            }
        }
    }

    Write-Output "CredSSP configuration completed successfully"
}
catch {
    Write-Error "CredSSP configuration failed: $_"
    throw $_
}
finally {
    Stop-Transcript
}
