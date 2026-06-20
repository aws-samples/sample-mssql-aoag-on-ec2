# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $True)]
    [string]$GroupName,

    [Parameter(Mandatory = $True)]
    $Members,

    [Parameter(Mandatory = $True)]
    [string]$DomainDNSName
)

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\aoag\log\AddUserToGroup.ps1.txt -Append

try {
    Write-Host "=== AddUserToGroup: Adding members to local group ==="
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"

    foreach ($member in $Members.split(",")) {
        $DomainAccountName = $DomainDNSName, $member -Join "\"
        try {
            Add-LocalGroupMember -Group $GroupName -Member $DomainAccountName
        }
        catch {
            if ($_ -Match "already") {
                Write-Host "User $DomainAccountName already exists in $GroupName"
            }
            else {
                throw $_
            }
        }
    }
}
catch {
    Write-Error $_
    throw $_
}
