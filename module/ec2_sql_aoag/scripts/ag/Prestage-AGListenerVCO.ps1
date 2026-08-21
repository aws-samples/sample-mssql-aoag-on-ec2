# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

<#
.SYNOPSIS
    Prestages the Virtual Computer Object (VCO) in Active Directory for an
    Always On availability group listener.

.DESCRIPTION
    When SQL Server runs ALTER AVAILABILITY GROUP ... ADD LISTENER, WSFC brings a
    Network Name resource online and creates the listener's computer object (the
    VCO) in AD. That create is performed by the CLUSTER IDENTITY (the CNO computer
    account) -- not by the credential that issued the T-SQL. If the CNO cannot
    create computer objects in its own container, the resource fails to come
    online and SQL reports:

        Msg 19471 - The WSFC cluster could not bring the Network Name resource
        with DNS name '<listener>' online.

    with FailoverClustering event 1194 in the System log naming the cluster
    identity and "Access is denied".

    In an unhardened domain this never surfaces, because the CNO is an
    authenticated principal and gets computer-object creation for free via the
    "Add workstations to a domain" right, bounded by ms-DS-MachineAccountQuota
    (default 10). Environments that harden that away -- including AWS Managed
    Microsoft AD, and any domain where the quota is set to 0 -- hit it on the
    first deployment.

    This script removes the dependency on the CNO being able to CREATE objects.
    Running under the domain credential the automation already uses for domain
    join, it:

      1. reads the live cluster name from the node (authoritative CNO name),
      2. creates the listener VCO, disabled, in the same container as the CNO,
      3. grants the CNO Full Control on that single object.

    WSFC then only needs to write to an object that already exists and that it
    controls. No OU-level ACL change is required, and nothing has to be
    re-delegated when the cluster or listener name changes.

    Idempotent: safe to re-run. An existing VCO is left in place and only has its
    disabled state and CNO permission reconciled.

.NOTES
    Requires the ActiveDirectory and FailoverClusters modules, and must run as a
    principal permitted to create computer objects in the CNO's container. That
    is the same permission the domain-join account already needs, so no extra
    delegation is introduced.

    Reference: Prestage cluster computer objects in Active Directory Domain Services
    https://learn.microsoft.com/en-us/windows-server/failover-clustering/prestage-cluster-adds
#>
[CmdletBinding()]
param(
    # Listener (VNN) name. Becomes the VCO's computer account name, so it is
    # subject to the 15-character NetBIOS limit.
    [Parameter(Mandatory = $true)]
    [string]$ListenerName,

    # Optional override for the CNO name. Leave empty to read it from the live
    # cluster, which is the reliable source: the cluster is created from the
    # Namespace value while var.clustername is threaded separately, so the two
    # can legitimately differ.
    [Parameter(Mandatory = $false)]
    [string]$ClusterName = ''
)

$ErrorActionPreference = 'Stop'
Start-Transcript -Path C:\aoag\log\Prestage-AGListenerVCO.ps1.log -Append

try {
    Write-Host "=== Prestage-AGListenerVCO ==="
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"

    Import-Module ActiveDirectory -ErrorAction Stop
    Import-Module FailoverClusters -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($ListenerName)) {
        throw "ListenerName is required."
    }
    if ($ListenerName.Length -gt 15) {
        throw "ListenerName '$ListenerName' is $($ListenerName.Length) characters. A VCO is a computer account and cannot exceed the 15-character NetBIOS limit."
    }

    # --- 1. Resolve the CNO ------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($ClusterName)) {
        $ClusterName = (Get-Cluster -ErrorAction Stop).Name
        Write-Host "Cluster name read from the live cluster: $ClusterName"
    }
    else {
        Write-Host "Cluster name supplied by caller: $ClusterName"
    }

    $cno = Get-ADComputer -Identity $ClusterName -ErrorAction Stop
    Write-Host "CNO object : $($cno.DistinguishedName)"
    Write-Host "CNO SID    : $($cno.SID)"

    # Container that holds the CNO. WSFC creates VCOs alongside the CNO, so the
    # VCO must be prestaged here for the cluster to find and adopt it.
    $targetOu = ($cno.DistinguishedName -split ',', 2)[1]
    Write-Host "Target OU  : $targetOu"

    # --- 2. Create (or adopt) the VCO -------------------------------------
    $vco = Get-ADComputer -Filter "Name -eq '$ListenerName'" -ErrorAction SilentlyContinue

    if ($vco) {
        Write-Host "VCO already exists: $($vco.DistinguishedName) - reconciling instead of creating."
    }
    else {
        Write-Host "Creating prestaged VCO '$ListenerName' (disabled) in $targetOu ..."
        New-ADComputer `
            -Name $ListenerName `
            -SAMAccountName "$ListenerName`$" `
            -Path $targetOu `
            -Enabled $false `
            -Description "Prestaged VCO for AG listener $ListenerName. Managed by WSFC cluster $ClusterName." `
            -ErrorAction Stop
        $vco = Get-ADComputer -Identity $ListenerName -ErrorAction Stop
        Write-Host "Created: $($vco.DistinguishedName)"
    }

    # WSFC expects to enable the account itself when it brings the resource
    # online. A prestaged VCO should be left disabled.
    if ($vco.Enabled) {
        Write-Host "VCO is enabled; disabling so WSFC can take ownership on resource online."
        Set-ADComputer -Identity $vco.DistinguishedName -Enabled $false -ErrorAction Stop
    }

    # --- 3. Grant the CNO Full Control on the VCO -------------------------
    $vcoPath = "AD:\$($vco.DistinguishedName)"
    $acl = Get-Acl -Path $vcoPath -ErrorAction Stop

    $already = $acl.Access | Where-Object {
        $_.IdentityReference -like "*$ClusterName*" -and
        $_.ActiveDirectoryRights -match 'GenericAll' -and
        $_.AccessControlType -eq 'Allow'
    }

    if ($already) {
        Write-Host "CNO already holds Full Control on the VCO - no ACL change needed."
    }
    else {
        Write-Host "Granting Full Control on the VCO to $ClusterName`$ ..."
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $cno.SID,
            [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
        Set-Acl -Path $vcoPath -AclObject $acl -ErrorAction Stop
        Write-Host "Granted."
    }

    # --- 4. Verify --------------------------------------------------------
    $final = Get-ADComputer -Identity $ListenerName -Properties Enabled, Description -ErrorAction Stop
    Write-Host ""
    Write-Host "--- Result ---"
    Write-Host "VCO DN     : $($final.DistinguishedName)"
    Write-Host "VCO Enabled: $($final.Enabled)  (expected False)"
    (Get-Acl -Path "AD:\$($final.DistinguishedName)").Access |
        Where-Object { $_.IdentityReference -like "*$ClusterName*" } |
        ForEach-Object {
            Write-Host ("ACE        : {0} {1} {2}" -f $_.IdentityReference, $_.ActiveDirectoryRights, $_.AccessControlType)
        }

    Write-Host "=== Prestage-AGListenerVCO completed ==="
}
catch {
    Write-Error ("Prestage-AGListenerVCO failed: " + $_.Exception.Message)
    throw $_
}
finally {
    Stop-Transcript
}
