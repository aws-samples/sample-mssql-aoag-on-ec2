# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$DomainDNSName
)

$ErrorActionPreference = "Stop"
Start-Transcript -Path C:\aoag\log\Update-DNSSuffixSearchList.ps1.log -Append

try {
    Write-Host "=== Update-DNSSuffixSearchList: Configuring DNS ==="
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"

    $DNSSuffixSearchList = Get-DnsClientGlobalSetting | Select-Object -ExpandProperty SuffixSearchList
    if ($DNSSuffixSearchList.Contains($DomainDNSName)) {
        $NewSearchList = @($DomainDNSName)
        for ($i = 0; $i -lt $DNSSuffixSearchList.Length; $i++) {
            if ($DNSSuffixSearchList[$i] -ne $DomainDNSName) {
                $NewSearchList += $DNSSuffixSearchList[$i]
            }
        }
        $DNSSuffixSearchList = $NewSearchList
    } else {
        $DNSSuffixSearchList = @($DomainDNSName) + $DNSSuffixSearchList
    }

    Write-Host "Updating DNS Suffix list"
    Set-DnsClientGlobalSetting -SuffixSearchList $DNSSuffixSearchList

    Write-Host "Adding DNS to the connection"
    $networkConfig = Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "ipenabled = 'true'"
    $networkConfig.SetDnsDomain($DomainDNSName)
    $networkConfig.SetDynamicDNSRegistration($true, $true)
    ipconfig /registerdns

    Write-Host "DNS Suffix updated successfully"
} catch {
    Write-Error ('Update-DNSSuffixSearchList failed: ' + $_.Exception.Message)
    throw $_
} finally {
    Stop-Transcript
}
