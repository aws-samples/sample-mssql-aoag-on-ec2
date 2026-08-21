# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

<#
.SYNOPSIS
    Creates scoped Windows Firewall inbound rules for AOAG / WSFC.

.DESCRIPTION
    Replaces the previous approach of disabling the Windows Firewall outright.
    The firewall stays ENABLED and only the ports AOAG needs are opened, each
    restricted to a caller-supplied set of CIDRs (the VPC CIDR by default).

    Keeping the host firewall on preserves a second layer behind the security
    group: if the SG is widened, bypassed via peering/TGW, or an attacker is
    already inside the VPC, the host still refuses everything except these ports
    from these sources.

    Rules are grouped by purpose so each can be re-scoped independently:

      AOAG-Cluster-*  node-to-node WSFC and AG replication. Only ever needs to
                      reach the other cluster nodes.
      AOAG-SQL-*      client access to SQL and the AG listener. Widen this if
                      applications live outside the supplied CIDRs.
      AOAG-WinRM-*    remote management. Narrow this to a bastion range if you
                      have one. Note the automation's own CredSSP session runs
                      over loopback and does not depend on this rule.

    Only INBOUND rules are created. Outbound is left at the Windows default
    (allow), which the nodes need for Systems Manager, S3, KMS, Secrets Manager
    and Active Directory.

    Idempotent: existing rules with the same DisplayName are updated in place.

.NOTES
    Cross-region DAG: the DR node sits in a different VPC, so its address is not
    covered by the primary VPC CIDR. For a DAG deployment pass the peer VPC CIDR
    as well, or AG replication on the mirroring port will be dropped here.
#>
[CmdletBinding()]
param(
    # CIDRs allowed to reach the ports below. Accepts a comma-separated string
    # (as passed from an SSM document) or an array.
    [Parameter(Mandatory = $true)]
    [string[]]$AllowedCidrs,

    [Parameter(Mandatory = $false)]
    [int]$ListenerPort = 1433,

    [Parameter(Mandatory = $false)]
    [int]$MirroringPort = 5022
)

$ErrorActionPreference = 'Stop'
Start-Transcript -Path C:\aoag\log\Configure-AOAGFirewall.ps1.txt -Append

try {
    Write-Output '=== Configure-AOAGFirewall ==='
    Write-Output "Running on node: $env:COMPUTERNAME"

    # Accept "10.0.0.0/16,10.1.0.0/16" as a single argument as well as an array.
    $cidrs = @(
        $AllowedCidrs |
            ForEach-Object { $_ -split ',' } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ }
    )
    if (-not $cidrs) { throw 'AllowedCidrs resolved to an empty set - refusing to create unscoped rules.' }
    Write-Output ("Allowed CIDRs: " + ($cidrs -join ', '))

    # Fail closed rather than silently creating an any-source rule.
    # Octets are range-checked (0-255) and the prefix is 0-32, so malformed input is
    # rejected here with a clear message instead of failing later inside
    # New-NetFirewallRule.
    $octet = '(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
    $cidrPattern = "^$octet(\.$octet){3}/(3[0-2]|[12][0-9]|[0-9])$"

    foreach ($c in $cidrs) {
        if ($c -eq 'Any') {
            throw "Refusing to scope AOAG firewall rules to 'Any'. Supply the VPC CIDR (or specific ranges) instead."
        }
        if ($c -notmatch $cidrPattern) {
            throw "'$c' is not a valid IPv4 CIDR. Expected a.b.c.d/prefix with each octet 0-255 and prefix 0-32."
        }
        # A /0 prefix matches every address regardless of the octets, so '10.0.0.0/0'
        # is just as broad as '0.0.0.0/0'. Reject the prefix rather than only the
        # literal string, otherwise the any-source guard is trivially bypassed.
        if ([int](($c -split '/')[1]) -eq 0) {
            throw "Refusing to scope AOAG firewall rules to '$c'. A /0 prefix permits any source, which is equivalent to disabling the host firewall. Supply the VPC CIDR (or specific ranges) instead."
        }
    }

    function Set-AoagRule {
        param(
            [string]$DisplayName,
            [string]$Protocol,
            [string[]]$LocalPort,
            [string[]]$RemoteAddress,
            [string]$Description
        )
        $existing = Get-NetFirewallRule -DisplayName $DisplayName -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Output "  updating : $DisplayName"
            $existing | Remove-NetFirewallRule -ErrorAction Stop
        }
        else {
            Write-Output "  creating : $DisplayName"
        }
        $params = @{
            DisplayName   = $DisplayName
            Direction     = 'Inbound'
            Action        = 'Allow'
            Protocol      = $Protocol
            RemoteAddress = $RemoteAddress
            Description   = $Description
            Enabled       = 'True'
            Profile       = 'Any'
            ErrorAction   = 'Stop'
        }
        if ($LocalPort) { $params['LocalPort'] = $LocalPort }
        New-NetFirewallRule @params | Out-Null
    }

    # --- node-to-node: WSFC + AG replication ------------------------------
    Set-AoagRule -DisplayName 'AOAG-Cluster-TCP' -Protocol TCP `
        -LocalPort @("$MirroringPort", '3343', '135', '445', '49152-65535') `
        -RemoteAddress $cidrs `
        -Description 'AOAG node-to-node: mirroring endpoint, WSFC, RPC endpoint mapper, SMB, dynamic RPC'

    Set-AoagRule -DisplayName 'AOAG-Cluster-UDP' -Protocol UDP `
        -LocalPort @('3343', '137', '138', '49152-65535') `
        -RemoteAddress $cidrs `
        -Description 'AOAG node-to-node: WSFC, NetBIOS name/datagram, dynamic RPC'

    # WSFC heartbeat relies on ICMP echo between nodes.
    Set-AoagRule -DisplayName 'AOAG-Cluster-ICMP' -Protocol ICMPv4 `
        -LocalPort $null -RemoteAddress $cidrs `
        -Description 'AOAG node-to-node: WSFC heartbeat (ICMPv4)'

    # --- client access to SQL and the AG listener -------------------------
    Set-AoagRule -DisplayName 'AOAG-SQL-TCP' -Protocol TCP `
        -LocalPort @("$ListenerPort") -RemoteAddress $cidrs `
        -Description 'SQL Server instance and AG listener - widen if clients are outside these CIDRs'

    # Named instances (the module default is INST01) do not listen on a fixed
    # port: SQL picks a dynamic port and clients must ask SQL Browser on UDP 1434
    # which port to use. Without this, node-to-node AG joins fail with
    # "error: 26 - Error Locating Server/Instance Specified". The dynamic port
    # itself falls in the 49152-65535 range already opened above.
    Set-AoagRule -DisplayName 'AOAG-SQL-Browser-UDP' -Protocol UDP `
        -LocalPort @('1434') -RemoteAddress $cidrs `
        -Description 'SQL Browser - resolves named instances to their dynamic TCP port'

    # --- remote management ------------------------------------------------
    Set-AoagRule -DisplayName 'AOAG-WinRM-TCP' -Protocol TCP `
        -LocalPort @('5985', '5986') -RemoteAddress $cidrs `
        -Description 'WinRM - narrow to a bastion range where possible'

    # --- ensure the firewall is actually on ------------------------------
    # The previous implementation disabled all profiles. Turn them back on in
    # case this runs against a node built by an earlier revision.
    Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled True -ErrorAction Stop

    Write-Output ''
    Write-Output '--- firewall profile state ---'
    Get-NetFirewallProfile |
        Select-Object Name, Enabled, DefaultInboundAction, DefaultOutboundAction |
        Format-Table -AutoSize | Out-String | Write-Output

    Write-Output '--- AOAG rules ---'
    Get-NetFirewallRule -DisplayName 'AOAG-*' |
        Select-Object DisplayName, Enabled, Direction, Action |
        Format-Table -AutoSize | Out-String | Write-Output

    Write-Output '=== Configure-AOAGFirewall completed ==='
}
catch {
    Write-Error "Failed to configure firewall: $($_.Exception.Message)"
    throw $_
}
finally {
    Stop-Transcript
}
