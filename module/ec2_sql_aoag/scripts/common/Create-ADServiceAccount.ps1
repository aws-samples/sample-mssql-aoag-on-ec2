# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DomainAdminUser,

    [Parameter(Mandatory = $true)]
    [string]$DomainAdminSecretKey,

    [Parameter(Mandatory = $true)]
    [string]$DomainDNSName,

    [Parameter(Mandatory = $true)]
    [string]$ServiceAccountUser,

    [Parameter(Mandatory = $true)]
    [string]$ServiceAccountSecretKey
)

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\aoag\log\Create-ADServiceAccount.ps1.log -Append

try {
    Write-Host "=== Create-ADServiceAccount: Creating SQL service account ==="
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"

    if ($null -eq (Get-Module -Name ActiveDirectory -ListAvailable)) {
        Install-WindowsFeature -Name RSAT-AD-PowerShell
    }

    # Get domain admin credentials
    $AdminDomainAccountName = "$DomainDNSName\$DomainAdminUser"
    $AdminSecretObject = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $DomainAdminSecretKey | Select-Object -ExpandProperty 'SecretString')
    $AdminCreds = New-Object PSCredential($AdminDomainAccountName, (ConvertTo-SecureString $AdminSecretObject.password -AsPlainText -Force))

    # Get service account password
    $SvcSecretObject = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $ServiceAccountSecretKey | Select-Object -ExpandProperty 'SecretString')
    $SvcPassword = ConvertTo-SecureString $SvcSecretObject.password -AsPlainText -Force

    # Check if user already exists
    $existingUser = Get-ADUser -Filter { sAMAccountName -eq $ServiceAccountUser } -Credential $AdminCreds -ErrorAction SilentlyContinue

    if ($null -ne $existingUser) {
        Write-Host "Service account '$ServiceAccountUser' already exists in AD."

        # Validate password
        try {
            $SvcDomainAccount = "$DomainDNSName\$ServiceAccountUser"
            $SvcCreds = New-Object PSCredential($SvcDomainAccount, $SvcPassword)
            Get-ADUser -Identity $ServiceAccountUser -Credential $SvcCreds -ErrorAction Stop | Out-Null
            Write-Host "Password validated successfully for '$ServiceAccountUser'."
        }
        catch {
            Write-Warning "Password validation failed for '$ServiceAccountUser'. The account exists but the password may be incorrect."
            throw "The password for $ServiceAccountUser is incorrect, unable to proceed."
        }
    }
    else {
        Write-Host "Creating AD service account '$ServiceAccountUser'..."

        $UPN = "$ServiceAccountUser@$DomainDNSName"

        New-ADUser `
            -Name $ServiceAccountUser `
            -SamAccountName $ServiceAccountUser `
            -UserPrincipalName $UPN `
            -AccountPassword $SvcPassword `
            -Enabled $true `
            -PasswordNeverExpires $true `
            -CannotChangePassword $false `
            -Credential $AdminCreds `
            -ErrorAction Stop

        Write-Host "Service account '$ServiceAccountUser' created successfully."
    }
}
catch {
    Write-Error $_
    throw $_
}
