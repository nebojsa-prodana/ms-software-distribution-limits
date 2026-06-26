<#
.SYNOPSIS
    Configures Delivery Optimization cache limits — the same settings found in
    gpedit.msc under Computer Configuration > Administrative Templates >
    Windows Components > Delivery Optimization — by writing the equivalent
    registry policy values directly. Useful on Home editions, which don't
    have gpedit.msc.

.PARAMETER MaxCacheSizePercent
    Max % of the disk DO's peer cache may use. Windows default is 20.

.PARAMETER AbsoluteMaxCacheSizeGB
    Hard cap in GB for the DO cache. If set, this overrides the percentage
    setting above.

.PARAMETER MaxCacheAgeDays
    How many days a cached file is kept before DO purges it. Windows default is 3.

.NOTES
    Run this in an elevated PowerShell window (Run as Administrator).
    No reboot required, though 'Restart-Service wuauserv' makes it take effect immediately.
#>

[CmdletBinding()]
param(
    [int]$MaxCacheSizePercent = 10,
    [int]$AbsoluteMaxCacheSizeGB = 5,
    [int]$MaxCacheAgeDays = 3
)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator. Right-click PowerShell -> 'Run as administrator' and try again."
    exit 1
}

$regPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'

if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}

$maxCacheAgeSeconds = $MaxCacheAgeDays * 86400

New-ItemProperty -Path $regPath -Name 'DOMaxCacheSize'         -Value $MaxCacheSizePercent   -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $regPath -Name 'DOAbsoluteMaxCacheSize' -Value $AbsoluteMaxCacheSizeGB -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $regPath -Name 'DOMaxCacheAge'          -Value $maxCacheAgeSeconds     -PropertyType DWord -Force | Out-Null

Write-Host "Delivery Optimization cache policy set:" -ForegroundColor Green
Write-Host "  Max Cache Size (percent)     : $MaxCacheSizePercent%"
Write-Host "  Absolute Max Cache Size (GB) : $AbsoluteMaxCacheSizeGB GB  (this wins if both are set)"
Write-Host "  Max Cache Age                : $MaxCacheAgeDays day(s) ($maxCacheAgeSeconds seconds)"
Write-Host "`nNo restart needed, but 'Restart-Service wuauserv' applies it immediately."
