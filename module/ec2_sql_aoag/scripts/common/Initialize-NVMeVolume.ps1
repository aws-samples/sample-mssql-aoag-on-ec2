# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

<#
.SYNOPSIS
    Initializes NVMe instance store volume(s) for SQL Server TempDB.
.DESCRIPTION
    Detects NVMe instance store (ephemeral) disks, initializes them as GPT,
    formats NTFS with 64KB allocation unit, and assigns the requested drive letter.
    Ephemeral drives lose data on stop/start, so this script must run on every boot.
    Idempotent: skips if the target drive letter already exists and is healthy.

    NVMe instance store disks are distinguished from NVMe EBS by checking the
    disk serial number pattern. EBS volumes have 'vol-' prefix; instance store
    disks use 'AWS' prefix or device name pattern like 'ephemeral'.

    If no NVMe instance store disks are found, the script exits cleanly (exit 0).
    This allows it to run safely on instance types without instance store.
.PARAMETER DriveLetter
    Drive letter to assign (default: T for TempDB).
.PARAMETER Label
    Volume label (default: SQL-TempDB).
.PARAMETER BlockSize
    NTFS allocation unit size in bytes (default: 65536 = 64KB, optimal for SQL).
.PARAMETER StripeSizeKB
    Stripe size in KB when creating a striped volume from multiple NVMe disks (default: 64).
    Only used when more than one NVMe instance store disk is detected.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)][string]$DriveLetter = 'T',
    [Parameter(Mandatory=$false)][string]$Label = 'SQL-TempDB',
    [Parameter(Mandatory=$false)][int]$BlockSize = 65536,
    [Parameter(Mandatory=$false)][int]$StripeSizeKB = 64
)

$ErrorActionPreference = 'Stop'
$logDir = 'C:\aoag\log'
if (!(Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
Start-Transcript -Path "$logDir\Initialize-NVMeVolume.ps1.log" -Append

try {
    Write-Host '=== Initialize-NVMeVolume: NVMe Instance Store Initialization ==='
    Write-Host "Running on node: $env:COMPUTERNAME ($(hostname))"
    Write-Host "Target: ${DriveLetter}: | Label: $Label | BlockSize: $BlockSize"

    $letter = $DriveLetter.TrimEnd(':')

    # =========================================================================
    # Idempotency: if drive letter exists on NVMe and is healthy, skip.
    # If drive letter exists on EBS, we must reassign it to NVMe.
    # =========================================================================
    if (Test-Path "${letter}:\") {
        $existingVol = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
        if ($existingVol -and $existingVol.HealthStatus -eq 'Healthy') {
            # Check if the existing volume is on NVMe instance store (not EBS)
            $existingPartition = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
            $isOnEBS = $false
            if ($existingPartition) {
                $ownerDisk = Get-Disk -Number $existingPartition.DiskNumber -ErrorAction SilentlyContinue
                $isOnEBS = $ownerDisk -and ($ownerDisk.UniqueId -match 'Amazon Elastic Block Store')
            }
            if (-not $isOnEBS) {
                Write-Host "Drive ${letter}: already exists on NVMe and is healthy (Size: $([math]::Round($existingVol.Size/1GB))GB) - nothing to do."
                exit 0
            }
            Write-Host "Drive ${letter}: exists but is on EBS (Size: $([math]::Round($existingVol.Size/1GB))GB) - will reassign to NVMe."
        } else {
            Write-Host "Drive ${letter}: exists but health is $($existingVol.HealthStatus) - will re-initialize."
        }
    }

    # =========================================================================
    # Detect NVMe instance store disks
    # On Nitro instances, both EBS and instance store appear as NVMe.
    # EBS volumes: SerialNumber starts with 'vol' (e.g., vol0abc1234def56789)
    # Instance store: SerialNumber starts with 'AWS' or contains 'ephemeral'
    # Also check: EBS disks have AdapterSerialNumber matching 'Amazon Elastic Block Store'
    # =========================================================================
    Write-Host '--- Detecting NVMe instance store disks ---'

    # Get all physical disks
    $allDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue
    if (-not $allDisks) {
        Write-Host 'No physical disks found via Get-PhysicalDisk - exiting.'
        exit 0
    }

    # Log all disks for diagnostics
    Write-Host 'All physical disks:'
    $allDisks | ForEach-Object {
        Write-Host "  DeviceId=$($_.DeviceId) FriendlyName=$($_.FriendlyName) SerialNumber=$($_.SerialNumber) Size=$([math]::Round($_.Size/1GB))GB MediaType=$($_.MediaType) BusType=$($_.BusType)"
    }

    # Filter for NVMe instance store disks
    # Strategy: NVMe bus type + NOT an EBS volume (EBS serial starts with 'vol')
    $nvmeInstanceStore = @()
    foreach ($pd in $allDisks) {
        if ($pd.BusType -ne 'NVMe') { continue }

        $serial = $pd.SerialNumber
        # EBS volumes on Nitro have serial starting with 'vol'
        if ($serial -and $serial -match '^vol') { continue }

        # Cross-check with Get-Disk to filter out EBS
        $disk = Get-Disk -Number $pd.DeviceId -ErrorAction SilentlyContinue
        if ($disk -and $disk.UniqueId -match 'Amazon Elastic Block Store') { continue }

        # This is an NVMe instance store disk
        $nvmeInstanceStore += $pd
        Write-Host "  -> Instance store disk found: DeviceId=$($pd.DeviceId) Serial=$serial Size=$([math]::Round($pd.Size/1GB))GB"
    }

    if ($nvmeInstanceStore.Count -eq 0) {
        Write-Host 'No NVMe instance store disks detected - this instance type has no ephemeral storage.'
        Write-Host 'TempDB will use the EBS volume (if configured). Exiting cleanly.'
        exit 0
    }

    Write-Host "Found $($nvmeInstanceStore.Count) NVMe instance store disk(s)"

    # =========================================================================
    # Free the target drive letter if it is currently assigned to an EBS volume.
    # When switching from EBS-based TempDB to NVMe, the EBS volume may still
    # hold the T: letter from a previous boot. Remove the letter so we can
    # assign it to the NVMe volume instead.
    # =========================================================================
    $existingPartition = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
    if ($existingPartition) {
        $ownerDisk = Get-Disk -Number $existingPartition.DiskNumber -ErrorAction SilentlyContinue
        $isEBS = $ownerDisk -and ($ownerDisk.UniqueId -match 'Amazon Elastic Block Store')
        if ($isEBS) {
            Write-Host "Drive ${letter}: is currently on EBS disk $($existingPartition.DiskNumber) - removing letter to reassign to NVMe."
            Remove-PartitionAccessPath -DiskNumber $existingPartition.DiskNumber -PartitionNumber $existingPartition.PartitionNumber -AccessPath "${letter}:" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }

    # =========================================================================
    # Initialize NVMe disk(s)
    # Single disk: simple GPT + partition + format
    # Multiple disks: Storage Spaces striped virtual disk for combined IOPS
    # =========================================================================
    if ($nvmeInstanceStore.Count -eq 1) {
        Write-Host '--- Single NVMe disk: simple partition ---'
        $pd = $nvmeInstanceStore[0]
        $diskNum = [int]$pd.DeviceId
        $disk = Get-Disk -Number $diskNum -ErrorAction Stop

        # Bring online if offline
        if ($disk.IsOffline) {
            Write-Host "Bringing disk $diskNum online..."
            Set-Disk -Number $diskNum -IsOffline $false
        }
        if ($disk.IsReadOnly) {
            Set-Disk -Number $diskNum -IsReadOnly $false
        }

        # Clear and re-initialize (ephemeral data is gone after stop/start anyway)
        Write-Host "Initializing disk $diskNum as GPT..."
        if ($disk.PartitionStyle -ne 'RAW') {
            Clear-Disk -Number $diskNum -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
        }
        Initialize-Disk -Number $diskNum -PartitionStyle GPT -ErrorAction Stop

        Write-Host "Creating partition with drive letter ${letter}:..."
        $partition = New-Partition -DiskNumber $diskNum -UseMaximumSize -DriveLetter $letter -ErrorAction Stop

        Write-Host "Formatting as NTFS (BlockSize=$BlockSize, Label=$Label)..."
        Format-Volume -DriveLetter $letter -FileSystem NTFS -AllocationUnitSize $BlockSize -NewFileSystemLabel $Label -Force -Confirm:$false -ErrorAction Stop

        $vol = Get-Volume -DriveLetter $letter -ErrorAction Stop
        Write-Host "Volume created: ${letter}: Size=$([math]::Round($vol.Size/1GB))GB Health=$($vol.HealthStatus)"
    }
    else {
        Write-Host "--- Multiple NVMe disks ($($nvmeInstanceStore.Count)): creating striped volume via Storage Spaces ---"

        $poolName = 'NVMePool'
        $vdName = 'NVMeStriped'

        # Clean up any existing pool from previous boot
        $existingVD = Get-VirtualDisk -FriendlyName $vdName -ErrorAction SilentlyContinue
        if ($existingVD) {
            Write-Host 'Removing existing virtual disk...'
            Remove-VirtualDisk -FriendlyName $vdName -Confirm:$false -ErrorAction SilentlyContinue
        }
        $existingPool = Get-StoragePool -FriendlyName $poolName -ErrorAction SilentlyContinue
        if ($existingPool) {
            Write-Host 'Removing existing storage pool...'
            Remove-StoragePool -FriendlyName $poolName -Confirm:$false -ErrorAction SilentlyContinue
        }

        # Bring all NVMe disks online and clear them
        foreach ($pd in $nvmeInstanceStore) {
            $diskNum = [int]$pd.DeviceId
            $disk = Get-Disk -Number $diskNum -ErrorAction SilentlyContinue
            if ($disk) {
                if ($disk.IsOffline) { Set-Disk -Number $diskNum -IsOffline $false }
                if ($disk.IsReadOnly) { Set-Disk -Number $diskNum -IsReadOnly $false }
                if ($disk.PartitionStyle -ne 'RAW') {
                    Clear-Disk -Number $diskNum -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
        }

        # Get the physical disks that can be pooled (must be in primordial pool)
        $subsystem = Get-StorageSubSystem -FriendlyName '*Windows*' -ErrorAction Stop
        $canPool = $subsystem | Get-PhysicalDisk -CanPool $true -ErrorAction SilentlyContinue

        # Filter to only our NVMe instance store disks
        $nvmeSerials = $nvmeInstanceStore | ForEach-Object { $_.SerialNumber }
        $poolDisks = $canPool | Where-Object { $_.SerialNumber -in $nvmeSerials }

        if ($poolDisks.Count -lt 2) {
            Write-Host "WARNING: Only $($poolDisks.Count) disk(s) available for pooling. Falling back to single disk."
            # Use the first available NVMe disk as simple partition
            $diskNum = [int]$nvmeInstanceStore[0].DeviceId
            Initialize-Disk -Number $diskNum -PartitionStyle GPT -ErrorAction Stop
            New-Partition -DiskNumber $diskNum -UseMaximumSize -DriveLetter $letter -ErrorAction Stop
            Format-Volume -DriveLetter $letter -FileSystem NTFS -AllocationUnitSize $BlockSize -NewFileSystemLabel $Label -Force -Confirm:$false -ErrorAction Stop
        }
        else {
            Write-Host "Creating storage pool '$poolName' with $($poolDisks.Count) disks..."
            $pool = New-StoragePool -FriendlyName $poolName -StorageSubSystemFriendlyName $subsystem.FriendlyName -PhysicalDisks $poolDisks -ErrorAction Stop

            $stripeSizeBytes = $StripeSizeKB * 1024
            Write-Host "Creating striped virtual disk '$vdName' (Interleave=${StripeSizeKB}KB)..."
            $vd = New-VirtualDisk -StoragePoolFriendlyName $poolName -FriendlyName $vdName -UseMaximumSize -ResiliencySettingName Simple -NumberOfColumns $poolDisks.Count -Interleave $stripeSizeBytes -ErrorAction Stop

            Write-Host 'Initializing virtual disk...'
            $vd | Get-Disk | Initialize-Disk -PartitionStyle GPT -ErrorAction Stop

            $vdDiskNum = ($vd | Get-Disk).Number
            Write-Host "Creating partition on virtual disk (disk $vdDiskNum) -> ${letter}:..."
            New-Partition -DiskNumber $vdDiskNum -UseMaximumSize -DriveLetter $letter -ErrorAction Stop

            Write-Host "Formatting as NTFS (BlockSize=$BlockSize, Label=$Label)..."
            Format-Volume -DriveLetter $letter -FileSystem NTFS -AllocationUnitSize $BlockSize -NewFileSystemLabel $Label -Force -Confirm:$false -ErrorAction Stop
        }

        $vol = Get-Volume -DriveLetter $letter -ErrorAction Stop
        Write-Host "Volume created: ${letter}: Size=$([math]::Round($vol.Size/1GB))GB Health=$($vol.HealthStatus)"
    }

    # =========================================================================
    # Create SQL TempDB directory structure
    # SQL Server expects these directories to exist at startup.
    # =========================================================================
    Write-Host '--- Creating TempDB directory structure ---'
    $tempDbDirs = @(
        "${letter}:\SQL\MSSQL\DATA",
        "${letter}:\SQL\MSSQL\LOG"
    )
    foreach ($dir in $tempDbDirs) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Host "  Created: $dir"
        } else {
            Write-Host "  Exists: $dir"
        }
    }

    # =========================================================================
    # Verify final state
    # =========================================================================
    $finalVol = Get-Volume -DriveLetter $letter -ErrorAction Stop
    Write-Host "=== NVMe volume ready: ${letter}: | Size: $([math]::Round($finalVol.Size/1GB))GB | Health: $($finalVol.HealthStatus) ==="
}
catch {
    Write-Error "Initialize-NVMeVolume FAILED: $($_.Exception.Message)"
    Write-Host "Stack: $($_.ScriptStackTrace)"
    throw $_
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue
}
