# ms-software-distribution-limits

Om nom nom...

`SoftwareDistribution\Download` really likes to be sitting fat and happy on 20+ gigabytes
of update files nobody asked it to keep. 

Failed Windows updates can and will often pile unapplied downloads
instead of helping you address the core issue that caused the updates to fail in the first place.

## Usage

Open an elevated PowerShell session — right-click the Start button and
choose **Windows Terminal (Admin)** or **PowerShell (Admin)**, or launch
PowerShell normally and run `Start-Process powershell -Verb RunAs`.

If you downloaded these scripts rather than cloning the repo, unblock them
once before running anything:

```powershell
Get-ChildItem *.ps1 | Unblock-File
```

Run the three scripts in this order:

### 1. `Set-DOCachePolicy.ps1` — one-time setup

Caps the Delivery Optimization peer-cache via registry (the same settings
exposed in `gpedit.msc`), so it stops competing with everything else for
disk space.

```powershell
.\Set-DOCachePolicy.ps1 [-MaxCacheSizePercent <int>] [-AbsoluteMaxCacheSizeGB <int>] [-MaxCacheAgeDays <int>]
```

| Parameter | Default | Description |
|---|---|---|
| `-MaxCacheSizePercent` | 10 | Max % of disk the DO cache may use |
| `-AbsoluteMaxCacheSizeGB` | 5 | Hard cap in GB; overrides the percentage above |
| `-MaxCacheAgeDays` | 3 | Days before cached files expire |

### 2. `Clean-WUCache.ps1` — run once manually, then on schedule

Stops `wuauserv` and `bits`, clears `SoftwareDistribution\Download`,
restarts the services, and logs how much space was reclaimed.

```powershell
.\Clean-WUCache.ps1 [-LogPath <string>]
```

| Parameter | Default | Description |
|---|---|---|
| `-LogPath` | `C:\ProgramData\WUCacheCleanup\cleanup.log` | Where the run log is written |

### 3. `Register-WUCleanupTask.ps1` — automate it

Registers a weekly Scheduled Task that runs `Clean-WUCache.ps1` as SYSTEM,
so the folder never gets the chance to refill unattended.

```powershell
.\Register-WUCleanupTask.ps1 [-ScriptPath <string>] [-DayOfWeek <string>] [-Time <string>]
```

| Parameter | Default | Description |
|---|---|---|
| `-ScriptPath` | Same folder as this script | Path to `Clean-WUCache.ps1` |
| `-DayOfWeek` | Sunday | Day the task runs |
| `-Time` | 03:00 | Time of day (24h) the task runs |

## Undo

```powershell
Unregister-ScheduledTask -TaskName 'WindowsUpdateCacheCleanup'
```

To revert the Delivery Optimization policy, delete `DOMaxCacheSize`,
`DOAbsoluteMaxCacheSize`, and `DOMaxCacheAge` from
`HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization`.

## Troubleshooting

If `SoftwareDistribution\Download` keeps refilling despite regular cleanup,
check Windows Update history for a recurring error code first:

```powershell
.\Get-WUFailureHistory.ps1 -Days 30
```

See [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) for the most common pattern —
a `0x80240034` download-failure loop — and the scripts that fix it.

## Requirements

- Windows 10/11
- PowerShell 5.1+
- Administrator rights
