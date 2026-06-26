<#
.SYNOPSIS
    Resets the Windows Update signature cache (catroot2), which frequently
    accompanies 0x80240034 (WU_E_DOWNLOAD_FAILED) and similar repeated
    update-download failures. Intended to run after Clean-WUCache.ps1.

.NOTES
    Run as Administrator. Windows rebuilds catroot2 automatically on the
    next update check.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$catroot2 = 'C:\Windows\System32\catroot2'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator."
    exit 1
}

Write-Host "Stopping cryptsvc..." -ForegroundColor Yellow
Stop-Service -Name cryptsvc -Force -ErrorAction SilentlyContinue

if (Test-Path $catroot2) {
    $backupPath = "$catroot2.old.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Write-Host "Renaming $catroot2 -> $backupPath" -ForegroundColor Yellow
    Rename-Item -Path $catroot2 -NewName (Split-Path $backupPath -Leaf)
}
else {
    Write-Host "$catroot2 not found - nothing to reset."
}

Write-Host "Starting cryptsvc..." -ForegroundColor Yellow
Start-Service -Name cryptsvc

Write-Host "Done. Windows will rebuild catroot2 automatically." -ForegroundColor Green
