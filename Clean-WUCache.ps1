<#
.SYNOPSIS
    Stops the Windows Update services, clears stale content from
    C:\Windows\SoftwareDistribution\Download, restarts the services, and logs
    how much space was reclaimed.

.PARAMETER LogPath
    Where to write the log file. Default: C:\ProgramData\WUCacheCleanup\cleanup.log

.NOTES
    Run as Administrator. Safe to run anytime EXCEPT mid-update-install
    (avoid running while Windows is actively "Working on updates ___%").
#>

[CmdletBinding()]
param(
    [string]$LogPath = 'C:\ProgramData\WUCacheCleanup\cleanup.log'
)

$ErrorActionPreference = 'Stop'
$downloadFolder = 'C:\Windows\SoftwareDistribution\Download'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator."
    exit 1
}

$logDir = Split-Path $LogPath -Parent
if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }

function Write-Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -Path $LogPath -Value $line
    Write-Host $line
}

function Get-FolderSizeMB {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    $items = Get-ChildItem -Path $Path -Recurse -Force -File -ErrorAction SilentlyContinue
    if (-not $items) { return 0 }
    $bytes = ($items | Measure-Object -Property Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }
    return [math]::Round($bytes / 1MB, 1)
}

Write-Log "----- Cleanup run started -----"
$sizeBefore = Get-FolderSizeMB $downloadFolder
Write-Log "Current Download folder size: $sizeBefore MB"

try {
    Write-Log "Stopping wuauserv and bits..."
    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
    Stop-Service -Name bits -Force -ErrorAction SilentlyContinue

    Write-Log "Clearing contents of $downloadFolder ..."
    Get-ChildItem -Path $downloadFolder -Recurse -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
finally {
    Write-Log "Restarting wuauserv and bits..."
    Start-Service -Name bits -ErrorAction SilentlyContinue
    Start-Service -Name wuauserv -ErrorAction SilentlyContinue
}

$sizeAfter = Get-FolderSizeMB $downloadFolder
$reclaimed = [math]::Round($sizeBefore - $sizeAfter, 1)

Write-Log "New Download folder size: $sizeAfter MB"
Write-Log "Space reclaimed: $reclaimed MB"
Write-Log "----- Cleanup run finished -----`n"