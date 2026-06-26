# Troubleshooting: Repeated 0x80240034 failures filling SoftwareDistribution\Download

## Symptom

- `Get-WUFailureHistory.ps1` (or Settings → Windows Update → Update history) shows
  repeated failures with the same code: `0x80240034`.
- Failures recur across both a feature update enablement entry (e.g. "Windows 11,
  version 25H2") and the latest cumulative security update.
- `C:\Windows\SoftwareDistribution\Download` grows by several GB a week even though
  no update is ever actually completing.

## Root cause

`0x80240034` is `WU_E_DOWNLOAD_FAILED` — Windows Update was unable to download the
update package it needs.

This turns into a self-reinforcing loop: corrupted or incomplete leftovers in
`SoftwareDistribution\Download` from a previous failed attempt block the next
download from completing cleanly. Windows retries, the retry fails the same way,
and the partial files stack on top of the old ones. That explains both the
identical error code repeating across unrelated updates and the runaway disk
usage — they're the same problem.

## Diagnose

Confirm the pattern before changing anything:

```powershell
.\Get-WUFailureHistory.ps1 -Days 30
```

If one error code dominates the summary table across multiple, otherwise
unrelated update titles, you're looking at this issue.

## Fix

Run in order, as Administrator:

1. **Clear the corrupted download cache.**
   ```powershell
   .\Clean-WUCache.ps1
   ```
   Stops `wuauserv`/`bits`, wipes `SoftwareDistribution\Download`, restarts the
   services, and logs the space reclaimed.

2. **Reset the signature cache.** `catroot2` corruption commonly rides along
   with this error and isn't touched by step 1.
   ```powershell
   .\Reset-WUCatroot2.ps1
   ```

3. **Rule out system file corruption**, only if failures continue after 1–2:
   ```powershell
   sfc /scannow
   DISM /Online /Cleanup-Image /RestoreHealth
   ```

4. Re-check for updates and confirm the update completes instead of failing at
   the same download stage.

5. Optional: re-run `Get-WUFailureHistory.ps1 -Days 1` after the next check to
   confirm the loop is actually broken rather than just reset for one cycle.

## Upstream references

- [Microsoft Q&A — Windows Update Error 0x80240034](https://learn.microsoft.com/en-us/answers/questions/f3c63fc3-909f-432b-acbd-bf25a4670286/windows-update-error-0x80240034?forum=windows-all)
- [PCRisk — Fix Windows Update Error 0x80240034](https://blog.pcrisk.com/windows/13453-fix-windows-update-error-0x80240034)
- [DiskInternals — Error 0x80240034 in Windows Update](https://www.diskinternals.com/partition-recovery/0x80240034/)
- [Renee.E Lab — How to Quickly Fix Windows Update Error 0x80240034](https://www.reneelab.com/error-0x80240034.html)
