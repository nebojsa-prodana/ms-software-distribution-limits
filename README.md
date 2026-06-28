# ms-software-distribution-limits

Scripts to cap Windows Update download cache growth and install updates in controlled batches.

## Requirements

| Item | Notes |
|---|---|
| OS | Windows 10/11 |
| PowerShell | **5.1** (`powershell.exe`) — all scripts use `#Requires -Version 5.1` |
| Admin | Required for every script except `Get-WUFailureHistory.ps1` |

Use Windows PowerShell 5.1, not PowerShell 7, for update COM work. The scheduled cleanup task also runs under `powershell.exe`.

## First run

Open an elevated session (Start → **Windows Terminal (Admin)** or **PowerShell (Admin)**).

If you downloaded the scripts instead of cloning, unblock them once:

```powershell
Get-ChildItem *.ps1 | Unblock-File
```

## Cache management

Run once, in order:

1. **`Set-DOCachePolicy.ps1`** — cap Delivery Optimization peer cache (registry; works on Home editions without gpedit)
2. **`Clean-WUCache.ps1`** — clear `SoftwareDistribution\Download` and log space reclaimed
3. **`Register-WUCleanupTask.ps1`** — weekly scheduled cleanup as SYSTEM (Sunday 03:00 by default)

```powershell
.\Set-DOCachePolicy.ps1
.\Clean-WUCache.ps1
.\Register-WUCleanupTask.ps1
```

Optional parameters:

```powershell
.\Set-DOCachePolicy.ps1 -MaxCacheSizePercent 10 -AbsoluteMaxCacheSizeGB 5 -MaxCacheAgeDays 3
.\Clean-WUCache.ps1 -LogPath 'C:\ProgramData\WUCacheCleanup\cleanup.log'
.\Register-WUCleanupTask.ps1 -DayOfWeek Sunday -Time '03:00'
```

Remove the scheduled task:

```powershell
Unregister-ScheduledTask -TaskName 'WindowsUpdateCacheCleanup'
```

Revert DO policy: delete `DOMaxCacheSize`, `DOAbsoluteMaxCacheSize`, and `DOMaxCacheAge` under  
`HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization`.

## Update installer

**Use `Get-WUUpdates2.ps1`** — batching, COM timeouts, progress output, and heartbeat during long operations.

```powershell
.\Get-WUUpdates2.ps1 -MaxUpdatesPerBatch 5 -AutoAcceptEula
```

Common switches:

| Switch | Default | Purpose |
|---|---|---|
| `-MaxBatchSizeGB` | 2 | Max download size per batch |
| `-MaxUpdatesPerBatch` | 5 | Max updates per batch |
| `-AutoAcceptEula` | off | Accept update EULAs automatically |
| `-RefreshServices` | off | Restart `wuauserv` / `DoSvc` before scan |
| `-IncludeDrivers` | off | Include driver updates |
| `-IncludeOptional` | off | Include optional updates |

Elevated one-liner:

```powershell
Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File .\Get-WUUpdates2.ps1'
```

`Get-WUUpdates.ps1` is kept as a simpler legacy script without timeout protection.

## Troubleshooting

Start with failure history:

```powershell
.\Get-WUFailureHistory.ps1 -Days 30
```

Full guide: [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) — recovery ladder, `0x80240034` download loop, **SFC / DISM repair**, stuck installs, and common error codes.

Quick path when updates keep failing:

```powershell
.\Clean-WUCache.ps1
.\Reset-WUCatroot2.ps1
# then in elevated cmd:
sfc /scannow
DISM /Online /Cleanup-Image /RestoreHealth
# reboot, then:
.\Get-WUUpdates2.ps1 -RefreshServices -MaxUpdatesPerBatch 5 -AutoAcceptEula
```
