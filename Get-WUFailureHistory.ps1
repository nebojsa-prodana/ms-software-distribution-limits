<#
.SYNOPSIS
    Lists failed/aborted Windows Update history entries from the last N days,
    plus a summary grouped by error code — useful for spotting a recurring
    failure pattern (e.g. a download loop bloating SoftwareDistribution\Download).

.PARAMETER Days
    How many days back to look. Default: 30.

.NOTES
    Read-only. Does not require Administrator, though running elevated is fine too.
#>

[CmdletBinding()]
param(
    [int]$Days = 30
)

$session  = New-Object -ComObject Microsoft.Update.Session
$searcher = $session.CreateUpdateSearcher()
$history  = $searcher.QueryHistory(0, $searcher.GetTotalHistoryCount())
$cutoff   = (Get-Date).AddDays(-$Days)

# ResultCode: 2 = Succeeded, 3 = Succeeded with errors, 4 = Failed, 5 = Aborted
$failures = $history | Where-Object { $_.Date -ge $cutoff -and $_.ResultCode -in 4, 5 }

Write-Host "`n=== Failures in the last $Days day(s) ===" -ForegroundColor Yellow
$failures |
    Select-Object Date,
                  Title,
                  @{n='ErrorCode'; e={ '0x{0:X8}' -f $_.HResult }} |
    Sort-Object Date -Descending |
    Format-Table -AutoSize -Wrap

Write-Host "`n=== Summary by error code ===" -ForegroundColor Yellow
$failures |
    Group-Object { '0x{0:X8}' -f $_.HResult } |
    Sort-Object Count -Descending |
    Select-Object Count, Name |
    Format-Table -AutoSize
