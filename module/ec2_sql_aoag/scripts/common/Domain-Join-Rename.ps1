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

    ###########################################################################
    # Pre-flight: is the target computer name already taken in AD?
    #
    # Add-Computer -NewName joins under the instance's current EC2 name and then
    # renames, and the rename also renames the AD computer object. sAMAccountName
    # must be unique, so if an object called <HostName> already exists - typically
    # an orphan from an earlier deployment, since terraform destroy does not remove
    # AD objects - the rename is refused with "The account already exists".
    #
    # That is a directory uniqueness constraint, not a permissions problem: domain
    # admin credentials do not help, and there is no override flag.
    #
    # Without this check the failure is slow and misleading. The first attempt
    # reports a *successful join* with a failed rename, which does not match the
    # 'already in that domain' case the retry loop handles, so it sleeps 60s. The
    # second attempt then matches, calls Rename-Computer, fails identically, and
    # because that call uses -ErrorAction Stop it throws out of the catch block and
    # kills the script. Re-running does not recover: the machine is now in the
    # domain, so it takes the rename path at the top and throws immediately.
    #
    # Queried over LDAP with System.DirectoryServices rather than Get-ADComputer,
    # so this works from a workgroup machine without the RSAT AD module.
    #
    # Deliberately fails OPEN: if the lookup itself cannot run we warn and continue,
    # so a diagnostic aid can never become a new failure mode.
    ###########################################################################
    if ($currentHostName -ne $HostName) {
        Write-Host "Pre-flight: checking whether a computer account named '$HostName' already exists..."

        # Collect the collision detail here rather than throwing inside the try,
        # so the catch below only ever sees genuine lookup failures.
        $nameCollision = $null

        try {
            $ldapRoot = New-Object System.DirectoryServices.DirectoryEntry(
                "LDAP://$DomainDNSName",
                $AdminDomainAccountName,
                $AdminSecretObject.password)

            $searcher = New-Object System.DirectoryServices.DirectorySearcher($ldapRoot)
            $searcher.Filter = "(&(objectClass=computer)(sAMAccountName=$HostName`$))"
            foreach ($p in 'distinguishedName', 'whenCreated', 'lastLogonTimestamp') {
                [void]$searcher.PropertiesToLoad.Add($p)
            }
            $hit = $searcher.FindOne()

            if ($hit) {
                $dn = $hit.Properties['distinguishedname'][0]
                $created = if ($hit.Properties['whencreated'].Count) { $hit.Properties['whencreated'][0] } else { 'unknown' }
                $lastLogon = 'never'
                if ($hit.Properties['lastlogontimestamp'].Count) {
                    $raw = [int64]$hit.Properties['lastlogontimestamp'][0]
                    if ($raw -gt 0) { $lastLogon = [DateTime]::FromFileTimeUtc($raw).ToString('u') }
                }
                $nameCollision = "DN: $dn; created: $created; lastLogon: $lastLogon"
            }
            else {
                Write-Host "Pre-flight OK: no existing computer account named '$HostName'."
            }
        }
        catch {
            Write-Host "WARNING: pre-flight name check could not run ($($_.Exception.Message)). Continuing to domain join."
        }

        if ($nameCollision) {
            throw ("A computer account named '$HostName' already exists in $DomainDNSName ($nameCollision). " +
                "Add-Computer cannot rename this node onto an existing account: sAMAccountName must be " +
                "unique, and domain admin rights do not override it. If it is an orphan from a previous " +
                "deployment, delete it from AD and re-run this step; otherwise choose a different node " +
                "name (the instances_data_map key). Note that terraform destroy leaves node computer " +
                "accounts, the cluster CNO and the listener VCO in the directory.")
        }
    }

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
