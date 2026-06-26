<#
.SYNOPSIS
    Registers a weekly Scheduled Task that runs Clean-WUCache.ps1 as SYSTEM,
    so C:\Windows\SoftwareDistribution\Download gets cleared out automatically
    instead of growing unchecked.

.PARAMETER ScriptPath
    Full path to Clean-WUCache.ps1. Default assumes it's sitting in the same
    folder as this script.

.PARAMETER DayOfWeek
    Day to run the cleanup. Default: Sunday.

.PARAMETER Time
    Time of day to run, 24h format. Default: 03:00.

.NOTES
    Run as Administrator. Safe to re-run — it replaces any existing task
    with the same name rather than erroring out.
#>

[CmdletBinding()]
param(
    [string]$ScriptPath = "$PSScriptRoot\Clean-WUCache.ps1",
    [string]$DayOfWeek = 'Sunday',
    [string]$Time = '03:00'
)

$ErrorActionPreference = 'Stop'
$taskName = 'WindowsUpdateCacheCleanup'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run as Administrator."
    exit 1
}

if (-not (Test-Path $ScriptPath)) {
    Write-Error "Can't find Clean-WUCache.ps1 at '$ScriptPath'. Pass -ScriptPath, or keep both scripts in the same folder."
    exit 1
}

# Replace any existing task with the same name so this is safe to re-run.
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
$trigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $DayOfWeek -At $Time
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd `
             -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings `
    -Description 'Weekly cleanup of C:\Windows\SoftwareDistribution\Download' | Out-Null

Write-Host "Scheduled task '$taskName' created: runs every $DayOfWeek at $Time as SYSTEM." -ForegroundColor Green
Write-Host "Log file will be at: C:\ProgramData\WUCacheCleanup\cleanup.log"
Write-Host "`nTo remove it later: Unregister-ScheduledTask -TaskName '$taskName'"
