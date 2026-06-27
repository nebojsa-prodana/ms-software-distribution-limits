# Troubleshooting

Use an elevated **Windows PowerShell 5.1** (`powershell.exe`) session unless noted.  
Run [`Get-WUFailureHistory.ps1`](Get-WUFailureHistory.ps1) first when you are not sure what is failing:

```powershell
.\Get-WUFailureHistory.ps1 -Days 30
```

## Recovery ladder

Work through these steps in order. Reboot when a step asks for it before moving on.

| Step | Action | When |
|---|---|---|
| 1 | `Clean-WUCache.ps1` | Download folder bloated or repeated download failures |
| 2 | `Reset-WUCatroot2.ps1` | Same as above, especially `0x80240034` / `0x8024200D` |
| 3 | Restart services | Updates hang or stall at 0% |
| 4 | `sfc /scannow` | Suspected corrupt system files |
| 5 | DISM restore | SFC reports problems, or errors like `0x800F081F` / `0x800F0922` |
| 6 | Reboot | After SFC/DISM, failed install, or pending reboot |
| 7 | `Get-WUUpdates2.ps1` | Retry updates in small batches |

```powershell
# Steps 1–2 (script fixes)
.\Clean-WUCache.ps1
.\Reset-WUCatroot2.ps1

# Step 3 (services)
Restart-Service wuauserv, bits, cryptsvc -Force

# Step 7 (retry)
.\Get-WUUpdates2.ps1 -RefreshServices -MaxUpdatesPerBatch 5 -AutoAcceptEula
```

Confirm the loop is broken:

```powershell
.\Get-WUFailureHistory.ps1 -Days 1
```

---

## Download folder keeps growing (`0x80240034`)

**Symptom:** Repeated `0x80240034` (`WU_E_DOWNLOAD_FAILED`) in history.  
`C:\Windows\SoftwareDistribution\Download` grows but updates never finish.

**Cause:** Partial or corrupt downloads block the next attempt. Windows retries and disk use climbs.

**Fix:** Steps 1–2 from the ladder above, then step 7. If it still fails, continue with SFC/DISM below.

---

## SFC and DISM repair

Use these when cache resets are not enough, SFC/DISM errors appear in update logs, or you see codes like `0x800F081F`, `0x800F0922`, or CBS/servicing failures.

Run from an **elevated Command Prompt or PowerShell**. These are built-in Windows tools, not repo scripts.

### 1. System File Checker (SFC)

Scans protected Windows files and replaces corrupt ones from the component store.

```cmd
sfc /scannow
```

- Takes 10–30+ minutes.
- Do not close the window while it runs.
- Note the result: **did not find violations**, **repaired files**, or **could not repair**.

If SFC could not repair everything, run DISM next (even if SFC looked clean).

### 2. DISM — check component store health

Optional but useful before restore:

```cmd
DISM /Online /Cleanup-Image /ScanHealth
```

### 3. DISM — repair component store

Repairs the WinSxS store SFC uses as its source. **Run after SFC** if SFC reported errors or could not fix files.

```cmd
DISM /Online /Cleanup-Image /RestoreHealth
```

- Requires internet access to fetch replacement files.
- Can take 20–60+ minutes.

### 4. Re-run SFC (optional)

After DISM finishes successfully:

```cmd
sfc /scannow
```

### 5. Reboot and retry updates

```powershell
Restart-Computer
# after reboot, elevated session:
.\Get-WUUpdates2.ps1 -RefreshServices -MaxUpdatesPerBatch 5 -AutoAcceptEula
```

**Order summary:** `Clean-WUCache` → `Reset-WUCatroot2` → **`sfc /scannow`** → **`DISM /Online /Cleanup-Image /RestoreHealth`** → reboot → `Get-WUUpdates2.ps1`.

---

## `Get-WUUpdates2.ps1` appears stuck

COM calls cannot be stopped with Ctrl+C. That is expected.

**Still running:** `[HEARTBEAT] HH:mm:ss` every ~15 seconds during long operations.

**Actually hung:** end the session:

```powershell
Get-Process powershell | Stop-Process -Force   # Windows PowerShell 5.1
Get-Process pwsh | Stop-Process -Force         # PowerShell 7, if you used it
```

Then:

```powershell
Restart-Service wuauserv, bits -Force
.\Get-WUUpdates2.ps1 -RefreshServices -MaxUpdatesPerBatch 5
```

**Download stuck at 0%:**

```cmd
bitsadmin /reset /allusers
```

```powershell
Restart-Service bits -Force
```

**Install never completes:** reboot, then re-run the script.

---

## Other common checks

**Pending reboot** — many updates fail until you restart:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -ErrorAction SilentlyContinue
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -ErrorAction SilentlyContinue
```

If either exists, reboot before retrying.

**Low disk space** — Windows Update needs free space on the system drive (often 10–20 GB+ for feature updates). Clear the Download folder with `Clean-WUCache.ps1` first.

**Network / proxy** — codes like `0x8024402C`: check connectivity, VPN, proxy, and DNS. Try Windows Update from Settings once to rule out policy blocks (`0x80240022`).

**Delivery Optimization cache** — if `SoftwareDistribution` stays small but disk still fills, cap DO cache with `Set-DOCachePolicy.ps1`.

---

## Common error codes

| Code | Likely cause | Try |
|---|---|---|
| `0x80240034` | Download failed | Cache + catroot2 reset |
| `0x80240022` | WU disabled or policy blocked | Settings / Group Policy |
| `0x8024200D` | Metadata corruption | Cache + catroot2 reset |
| `0x800F081F` | Missing source files | DISM RestoreHealth, then SFC |
| `0x80070005` | Access denied | Run elevated |
| `0x8024402C` | Network or proxy | Connectivity / DNS / VPN |
| `0x800F0922` | CBS / servicing failure | DISM, reboot, retry |
| `0x80240016` | Install already in progress | Reboot, stop other WU activity |

---

## References

- [Microsoft Q&A — 0x80240034](https://learn.microsoft.com/en-us/answers/questions/f3c63fc3-909f-432b-acbd-bf25a4670286/windows-update-error-0x80240034?forum=windows-all)
- [Use DISM to repair Windows image](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/repair-a-windows-image)
