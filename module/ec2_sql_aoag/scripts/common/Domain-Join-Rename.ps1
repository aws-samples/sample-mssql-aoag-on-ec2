# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdminSecret,

    [Parameter(Mandatory = $true)]
    [string]$DomainAdminUser,

    [Parameter(Mandatory = $true)]
    [string]$HostName,

    [Parameter(Mandatory = $true)]
    [string]$DomainDNSName
)

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\aoag\log\Join-Domain.ps1.log -Append

try {
    $AdminDomainAccountName = $DomainDNSName, $DomainAdminUser -Join "\"
    Write-Host "=== Domain-Join-Rename: Starting domain join ==="
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"
    # Get current region from instance metadata (supports IMDSv2)
    try {
        $token = Invoke-RestMethod -Uri 'http://169.254.169.254/latest/api/token' -Method PUT -Headers @{'X-aws-ec2-metadata-token-ttl-seconds' = '300'} -UseBasicParsing
        $currentRegion = Invoke-RestMethod -Uri 'http://169.254.169.254/latest/meta-data/placement/region' -Headers @{'X-aws-ec2-metadata-token' = $token} -UseBasicParsing
        Write-Host "Detected region from IMDS: $currentRegion"
    }
    catch {
        $currentRegion = $null
        Write-Host "Could not get region from IMDS, using SDK default"
    }

    # Retrieve secret with retry (fresh instances may need time for network/DNS)
    $AdminSecretObject = $null
    $secretRetry = 0
    $secretMaxRetries = 5
    while ($secretRetry -lt $secretMaxRetries) {
        try {
            $secretRetry++
            Write-Host "Retrieving secret (attempt $secretRetry of $secretMaxRetries)..."
            if ($currentRegion) {
                $AdminSecretObject = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $AdminSecret -Region $currentRegion | Select-Object -ExpandProperty 'SecretString')
            } else {
                $AdminSecretObject = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $AdminSecret | Select-Object -ExpandProperty 'SecretString')
            }
            Write-Host "Secret retrieved successfully"
            break
        }
        catch {
            Write-Host "Secret retrieval failed: $($_.Exception.Message)"
            if ($secretRetry -lt $secretMaxRetries) {
                Write-Host "Waiting 30 seconds before retry..."
                Start-Sleep -Seconds 30
            } else {
                throw "Failed to retrieve secret after $secretMaxRetries attempts: $($_.Exception.Message)"
            }
        }
    }
    $AdminSecureCredentials = New-Object PSCredential($AdminDomainAccountName, (ConvertTo-SecureString $AdminSecretObject.password -AsPlainText -Force))

    $currentHostName = $env:COMPUTERNAME
    $alreadyInDomain = (Get-WmiObject Win32_ComputerSystem).Domain.ToLower() -eq $DomainDNSName.ToLower()

    if ($alreadyInDomain) {
        Write-Host "Server already in the domain $DomainDNSName"
        if ($currentHostName -ne $HostName) {
            Write-Host "Hostname mismatch: current='$currentHostName', desired='$HostName'. Renaming..."
            Rename-Computer -NewName $HostName -DomainCredential $AdminSecureCredentials -Force -ErrorAction Stop
            Write-Host "Renamed to $HostName. Reboot required."
        } else {
            Write-Host "Hostname already correct: $HostName"
        }
    }
    else {
        $RetryCount = 0
        while ($RetryCount -lt 5) {
            try {
                Add-Computer -DomainName $DomainDNSName -NewName $HostName -Credential $AdminSecureCredentials -ErrorAction Stop -Force
                Write-Host "Joined domain $DomainDNSName and set hostname to $HostName"
                break
            }
            catch {
                $msg = $_.Exception.Message
                # If error says already in domain, just rename and break
                if ($msg -match 'already in that domain') {
                    Write-Host "Already in domain (caught in retry). Renaming to $HostName..."
                    if ($currentHostName -ne $HostName) {
                        Rename-Computer -NewName $HostName -DomainCredential $AdminSecureCredentials -Force -ErrorAction Stop
                        Write-Host "Renamed to $HostName. Reboot required."
                    }
                    break
                }
                Write-Host "Failed to join domain: $msg"
                $RetryCount++
                Write-Host "Waiting 60 seconds before retrying. Attempts remaining: $((5 - $RetryCount))"
                Start-Sleep -Seconds 60
            }
        }
        if ($RetryCount -eq 5) { throw "Could not join domain in 5 retries" }
    }
}
catch {
    Write-Error $_
    throw $_
}
