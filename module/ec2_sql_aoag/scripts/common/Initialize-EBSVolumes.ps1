# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

<#
.SYNOPSIS
    Initializes, partitions, and formats attached EBS volumes on Windows.
.DESCRIPTION
    Takes a JSON string describing the EBS volumes (drive_letter, volume_size,
    label_name, block_size) and matches them to RAW Amazon EBS disks by size.
    Each disk is brought online, GPT-initialized, partitioned, and NTFS-formatted.
.PARAMETER DriveConfig
    JSON array string, e.g.:
    [{"volume_size":100,"drive_letter":"E","label_name":"SQL-Data","block_size":65536},...]
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DriveConfig
)

$ErrorActionPreference = 'Stop'
$logDir = 'C:\aoag\log'
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
Start-Transcript -Path "$logDir\Initialize-EBSVolumes.ps1.log" -Append

try {
    Write-Host "=== Initialize-EBSVolumes: Starting EBS volume initialization ==="
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"

    $drives = $DriveConfig | ConvertFrom-Json
    if (!$drives -or $drives.Count -eq 0) {
        throw 'DriveConfig is empty or invalid'
    }

    Write-Host "Drive config received: $($drives.Count) volume(s)"
    $drives | Format-Table | Out-String | Write-Host

    # Quick check: if all requested drive letters already exist, skip entirely
    $allExist = $true
    foreach ($d in $drives) {
        $letter = $d.drive_letter.TrimEnd(':')
        if (-not (Test-Path "${letter}:\")) { $allExist = $false; break }
    }
    if ($allExist) {
        $existingLetters = ($drives | ForEach-Object { "$($_.drive_letter.TrimEnd(':')):" }) -join ', '
        Write-Host "All drives already exist ($existingLetters) - nothing to do"
        exit 0
    }

    # Get all Amazon EBS disks that need initialization:
    # - RAW disks (never initialized)
    # - Initialized disks with no partitions (auto-initialized by Windows but not formatted)
    $allEBSDisks = Get-Disk | Where-Object { $_.UniqueId -match 'Amazon Elastic Block Store' }
    
    # Filter: RAW disks OR disks with no assigned drive letters (unformatted)
    $rawDisks = @()
    foreach ($disk in $allEBSDisks) {
        if ($disk.PartitionStyle -eq 'RAW') {
            $rawDisks += $disk
        }
        else {
            # Check if this disk has any partitions with drive letters
            $partitions = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
                Where-Object { $_.DriveLetter -and $_.DriveLetter -ne [char]0 }
            if (-not $partitions) {
                $rawDisks += $disk
            }
        }
    }
    $rawDisks = $rawDisks | Sort-Object -Property Size

    Write-Host "Found $($rawDisks.Count) uninitialized/unformatted EBS disk(s)"
    Write-Host "All EBS disks on system:"
    $allEBSDisks | ForEach-Object { Write-Host "  Disk $($_.Number): Size=$([math]::Round($_.Size/1GB))GB PartitionStyle=$($_.PartitionStyle) IsOffline=$($_.IsOffline)" }

    if ($rawDisks.Count -eq 0) {
        Write-Host 'No uninitialized EBS disks found - volumes may already be initialized'
        exit 0
    }

    # Match each disk to a drive config entry by size
    foreach ($disk in $rawDisks) {
        if ($disk.IsOffline) {
            Set-Disk -Number $disk.Number -IsOffline $false
        }
        if ($disk.PartitionStyle -eq 'RAW') {
            Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction SilentlyContinue
        }
        if ($disk.IsReadOnly) {
            Set-Disk -Number $disk.Number -IsReadOnly $false
        }

        foreach ($drive in $drives) {
            $sizeGB = [math]::Round($disk.Size / 1GB)
            if ($sizeGB -eq $drive.volume_size -and -not ($drive.PSObject.Properties.Name -contains 'diskNumber')) {
                $drive | Add-Member -NotePropertyName diskNumber -NotePropertyValue $disk.Number
                Write-Host "Matched disk $($disk.Number) (${sizeGB}GB) -> $($drive.drive_letter): ($($drive.label_name))"
                break
            }
        }
    }

    # Partition and format each matched drive
    foreach ($drive in $drives) {
        if (-not ($drive.PSObject.Properties.Name -contains 'diskNumber')) {
            Write-Warning "No RAW disk matched for drive $($drive.drive_letter): ($($drive.volume_size)GB) - skipping"
            continue
        }

        $letter = $drive.drive_letter.TrimEnd(':')
        if (Test-Path "${letter}:\") {
            Write-Host "Drive ${letter}:\ already exists - skipping"
            continue
        }

        $blockSize = if ($drive.block_size) { $drive.block_size } else { 65536 }

        Write-Host "Creating partition on disk $($drive.diskNumber) -> ${letter}: label=$($drive.label_name) blockSize=$blockSize"
        $vol = New-Partition -DiskNumber $drive.diskNumber -UseMaximumSize -DriveLetter $letter |
            Format-Volume -FileSystem NTFS -AllocationUnitSize $blockSize -Force -NewFileSystemLabel $drive.label_name

        if ($vol.HealthStatus -eq 'Healthy' -and $vol.OperationalStatus -eq 'OK') {
            Write-Host "Volume $($drive.label_name) ($letter`:) created successfully"
        }
        else {
            throw "Volume $($drive.label_name) creation failed: Health=$($vol.HealthStatus) Status=$($vol.OperationalStatus)"
        }
    }

    Write-Host '=== EBS volume initialization complete ==='
}
catch {
    Write-Error "Initialize-EBSVolumes failed: $($_.Exception.Message)"
    throw $_
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
