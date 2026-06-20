# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdminSecret,

    [Parameter(Mandatory = $true)]
    [string]$DomainAdminUser,

    [Parameter(Mandatory = $true)]
    [string]$DomainDNSName
)

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\aoag\log\SetDomain-TrustIdentity.ps1.log -Append

try {
    Write-Host "=== SetDomain-TrustIdentity: Configuring delegation ==="
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"

    $AdminDomainAccountName = $DomainDNSName, $DomainAdminUser -Join "\"
    $AdminSecretObject = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $AdminSecret | Select-Object -ExpandProperty 'SecretString')
    $AdminSecureCredentials = New-Object PSCredential($AdminDomainAccountName, (ConvertTo-SecureString $AdminSecretObject.password -AsPlainText -Force))

    Write-Host "Setting TrustedForDelegation on computer account: $env:COMPUTERNAME"
    Set-ADcomputer -Identity $env:COMPUTERNAME -TrustedForDelegation $true -Credential $AdminSecureCredentials -ErrorAction Stop

    Write-Host "Setting TrustedForDelegation on user account: $DomainAdminUser"
    Set-ADUser -Identity $DomainAdminUser -TrustedForDelegation $true -Credential $AdminSecureCredentials -ErrorAction Stop
}
catch {
    Write-Error $_
    throw $_
}
