# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

[CmdletBinding()]
param()

Start-Transcript -Path C:\aoag\log\Restart-Computer.ps1.txt -Append
$ErrorActionPreference = "SilentlyContinue"

Start-Process -FilePath "shutdown.exe" -ArgumentList @("/r", "/t 10") -Wait -NoNewWindow
