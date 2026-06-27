#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Windows Updates in controlled batches via the native COM API.

.NOTES
    Run as Administrator in Windows PowerShell 5.1 (powershell.exe).
    Uses Start-Job with explicit -ArgumentList (PS 3+); tested on PS 5.1. PS 7 may work interactively.
#>

[CmdletBinding()]
param(
    [int]$MaxBatchSizeGB = 2,
    [int]$MaxUpdatesPerBatch = 5,
    [switch]$AutoAcceptEula,
    [switch]$RefreshServices,
    [switch]$IncludeDrivers,
    [switch]$IncludeOptional
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:StartTime = Get-Date
$script:Installed = 0
$script:Failed = 0
$script:BatchesProcessed = 0
$script:RebootRequiredGlobal = $false

function Write-Log {
    param([string]$Message)
    Write-Verbose ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message)
}

function Test-IsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-HResultMessage {
    param([string]$HResult)
    switch ($HResult) {
        '0x80240022' { 'Windows Update disabled or restricted by policy' }
        '0x8024200D' { 'Update metadata corruption' }
        '0x800F081F' { 'Missing source files' }
        '0x80070005' { 'Access denied' }
        '0x8024402C' { 'Network or proxy issue' }
        '0x80240017' { 'No applicable updates' }
        '0x80246007' { 'Download incomplete' }
        '0x800F0922' { 'Servicing failure' }
        default { 'Unknown error' }
    }
}

function Get-ResultCodeText {
    # Maps the WUA OperationResultCode enum (NOT an HRESULT) to readable text.
    param([int]$ResultCode)
    switch ($ResultCode) {
        0 { 'Not Started' }
        1 { 'In Progress' }
        2 { 'Succeeded' }
        3 { 'Succeeded With Errors' }
        4 { 'Failed' }
        5 { 'Aborted' }
        default { 'Unknown' }
    }
}

function Get-UpdateCategory {
    param($Update)
    $cats = $Update.Categories -join ' '
    if ($cats -match 'Servicing Stack') { return 'Servicing Stack' }
    if ($cats -match 'Cumulative') { return 'Cumulative' }
    if ($cats -match '\.NET|Net Framework') { return '.NET' }
    if ($cats -match 'Defender|Security Intelligence') { return 'Defender' }
    if ($cats -match 'Driver') { return 'Drivers' }
    if ($cats -match 'Feature') { return 'Feature Updates' }
    if ($cats -match 'Optional') { return 'Optional' }
    return 'Other'
}

function Invoke-WithTimeout {
    param(
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 600,
        [string]$Name = 'Operation',
        [string]$ProgressFile = $null,
        [int]$PollSeconds = 2
    )

    $job = Start-Job -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
    $elapsedSeconds = 0
    $lastProgressText = $null
    $printedProgress = $false
    $lastHeartbeat = Get-Date

    try {
        while ($true) {
            $completed = Wait-Job -Job $job -Timeout $PollSeconds

            if (((Get-Date) - $lastHeartbeat).TotalSeconds -ge 15) {
                Write-Host ("[HEARTBEAT] {0:HH:mm:ss}" -f (Get-Date))
                $lastHeartbeat = Get-Date
            }

            if ($ProgressFile -and (Test-Path -LiteralPath $ProgressFile)) {
                $text = Get-Content -LiteralPath $ProgressFile -Raw -ErrorAction SilentlyContinue
                if ($text -and $text.Trim() -ne $lastProgressText) {
                    $display = "  $($text.Trim())"
                    Write-Host ("`r" + $display.PadRight(100)) -NoNewline
                    $lastProgressText = $text.Trim()
                    $printedProgress = $true
                }
            }

            if ($completed) { break }

            $elapsedSeconds += $PollSeconds
            if ($elapsedSeconds -ge $TimeoutSeconds) {
                throw "$Name timed out after $TimeoutSeconds seconds."
            }
        }

        if ($printedProgress) { Write-Host '' }

        if ($null -ne $job) {
            $raw = Receive-Job -Job $job -ErrorAction Stop
            if ($null -eq $raw) { return ,@() }
            return ,@($raw)
        } else {
            throw "Job is null."
        }
    }
    finally {
        Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        if ($ProgressFile) { Remove-Item -LiteralPath $ProgressFile -Force -ErrorAction SilentlyContinue }
    }
}

function Restart-UpdateServices {
    Write-Log 'Restarting wuauserv and DoSvc...'
    foreach ($svc in 'wuauserv', 'DoSvc') {
        try { Restart-Service -Name $svc -Force -ErrorAction Stop } catch { Write-Log $_ }
    }
    Start-Sleep -Seconds 5
}

function Search-Updates {
    $criteria = "IsInstalled=0 AND IsHidden=0"
    if (-not $IncludeOptional) { $criteria += " AND Type='Software'" }

    return Invoke-WithTimeout -Name 'Search' -TimeoutSeconds 300 -ArgumentList @($criteria, [bool]$IncludeDrivers) -ScriptBlock {
        param($Criteria, $AllowDrivers)

        $ErrorActionPreference = 'Stop'
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $searchResult = $searcher.Search($Criteria)
        $output = @()

        foreach ($u in $searchResult.Updates) {
            if (-not $AllowDrivers -and $u.BrowseOnly) { continue }

            $categories = @($u.Categories | ForEach-Object { $_.Name })
            $estimatedSize = 0
            if ($u.BundledUpdates -and $u.BundledUpdates.Count -gt 0) {
                foreach ($b in $u.BundledUpdates) {
                    if ($b.IsApplicable) { $estimatedSize += $b.MaxDownloadSize }
                }
            }
            if ($estimatedSize -eq 0) { $estimatedSize = $u.MaxDownloadSize }

            $output += [PSCustomObject]@{
                Title         = $u.Title
                EstimatedSize = $estimatedSize
                Categories    = $categories
                EulaAccepted  = $u.EulaAccepted
            }
        }

        return ,$output
    }
}

function Build-Batches {
    param([array]$Updates)

    $batches = @()
    foreach ($group in ($Updates | Group-Object { Get-UpdateCategory $_ })) {
        $current = @()
        $currentSizeGB = 0

        foreach ($u in $group.Group) {
            $sizeGB = $u.EstimatedSize / 1GB
            if (($current.Count -ge $MaxUpdatesPerBatch -or ($currentSizeGB + $sizeGB) -gt $MaxBatchSizeGB) -and $current.Count -gt 0) {
                $batches += ,$current
                $current = @()
                $currentSizeGB = 0
            }
            $current += $u
            $currentSizeGB += $sizeGB
        }

        if ($current.Count -gt 0) { $batches += ,$current }
    }

    return ,$batches
}

function Download-Batch {
    param([array]$Updates, [int]$Index)

    $totalSizeMB = [math]::Round((($Updates | Measure-Object -Property EstimatedSize -Sum).Sum / 1MB), 1)
    Write-Host "Downloading batch $Index ($($Updates.Count) update(s), ~$totalSizeMB MB)"

    $titles = @($Updates | ForEach-Object { $_.Title })
    $progressFile = Join-Path $env:TEMP ("wu_progress_{0}.txt" -f [guid]::NewGuid())

    Invoke-WithTimeout -Name "Download batch $Index" -TimeoutSeconds 1800 -ProgressFile $progressFile -ArgumentList @($titles, $progressFile) -ScriptBlock {
        param($Titles, $ProgressFile)

        $ErrorActionPreference = 'Stop'
        Set-Content -LiteralPath $ProgressFile -Value 'Initializing update session...' -Force

        $session = New-Object -ComObject Microsoft.Update.Session
        if ($null -eq $session) { throw 'New-Object Microsoft.Update.Session returned null.' }

        $searcher = $session.CreateUpdateSearcher()
        if ($null -eq $searcher) { throw 'CreateUpdateSearcher() returned null.' }

        $searchResult = $searcher.Search('IsInstalled=0 AND IsHidden=0')
        if ($null -eq $searchResult) { throw 'Search() returned null.' }

        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        if ($null -eq $coll) { throw 'New-Object Microsoft.Update.UpdateColl returned null.' }

        foreach ($u in $searchResult.Updates) {
            if ($Titles -contains $u.Title) { [void]$coll.Add($u) }
        }

        if ($coll.Count -eq 0) { return }

        Set-Content -LiteralPath $ProgressFile -Value "Downloading $($coll.Count) update(s) (this can take a while, no live percent with this method)..." -Force

        $downloader = $session.CreateUpdateDownloader()
        if ($null -eq $downloader) { throw 'CreateUpdateDownloader() returned null.' }

        $downloader.Updates = $coll

        # Synchronous download instead of BeginDownload/EndDownload + GetProgress polling.
        # The async pattern was throwing a NullReferenceException around BeginDownload for
        # this update; Download() is the simpler, more reliable call used in most WUA scripts.
        $downloadResult = $downloader.Download()
        if ($null -eq $downloadResult) { throw 'Download() returned a null result.' }

        Set-Content -LiteralPath $ProgressFile -Value ("Download finished. ResultCode={0}" -f $downloadResult.ResultCode) -Force
    } | Out-Null
}

function Install-Batch {
    param([array]$Updates, [int]$Index)

    Write-Host "Installing batch $Index"
    $titles = @($Updates | ForEach-Object { $_.Title })
    $progressFile = Join-Path $env:TEMP ("wu_progress_{0}.txt" -f [guid]::NewGuid())

    $results = Invoke-WithTimeout -Name "Install batch $Index" -TimeoutSeconds 1800 -ProgressFile $progressFile -ArgumentList @($titles, $progressFile, [bool]$AutoAcceptEula) -ScriptBlock {
        param($Titles, $ProgressFile, $AcceptEula)

        $ErrorActionPreference = 'Stop'
        Set-Content -LiteralPath $ProgressFile -Value 'Initializing update session...' -Force

        $session = New-Object -ComObject Microsoft.Update.Session
        if ($null -eq $session) { throw 'New-Object Microsoft.Update.Session returned null.' }

        $searcher = $session.CreateUpdateSearcher()
        if ($null -eq $searcher) { throw 'CreateUpdateSearcher() returned null.' }

        $searchResult = $searcher.Search('IsInstalled=0 AND IsHidden=0')
        if ($null -eq $searchResult) { throw 'Search() returned null.' }

        $coll = New-Object -ComObject Microsoft.Update.UpdateColl
        if ($null -eq $coll) { throw 'New-Object Microsoft.Update.UpdateColl returned null.' }

        foreach ($u in $searchResult.Updates) {
            if ($Titles -notcontains $u.Title) { continue }
            if ($AcceptEula -and -not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$coll.Add($u)
        }

        if ($coll.Count -eq 0) { return ,@() }

        Set-Content -LiteralPath $ProgressFile -Value "Installing $($coll.Count) update(s) (this can take a while, no live percent with this method)..." -Force

        $installer = $session.CreateUpdateInstaller()
        if ($null -eq $installer) { throw 'CreateUpdateInstaller() returned null.' }

        $installer.Updates = $coll

        # Synchronous install instead of BeginInstall/EndInstall + GetProgress polling,
        # for the same reliability reason as the download step above.
        $installResult = $installer.Install()
        if ($null -eq $installResult) { throw 'Install() returned a null result.' }

        Set-Content -LiteralPath $ProgressFile -Value 'Install finished.' -Force
        $output = @()
        for ($i = 0; $i -lt $coll.Count; $i++) {
            $r = $installResult.GetUpdateResult($i)
            $output += [PSCustomObject]@{
                Title          = $coll.Item($i).Title
                ResultCode     = $r.ResultCode
                HRESULT        = ('0x{0:X8}' -f $r.HResult)
                RebootRequired = $r.RebootRequired
            }
        }
        return ,$output
    }

    $processedOutput = @()
    foreach ($r in $results) {
        if ($r.RebootRequired) { $script:RebootRequiredGlobal = $true }

        $statusText = Get-ResultCodeText $r.ResultCode
        $isSuccess = ($r.ResultCode -eq 2 -or $r.ResultCode -eq 3)  # Succeeded or Succeeded With Errors
        if ($isSuccess) { $script:Installed++ } else { $script:Failed++ }

        $message = if ($isSuccess) {
            $statusText
        } else {
            "$statusText - $(Get-HResultMessage $r.HRESULT) ($($r.HRESULT))"
        }

        $processedOutput += [PSCustomObject]@{
            Title   = $r.Title
            HRESULT = $r.HRESULT
            Message = $message
            Reboot  = $r.RebootRequired
        }
    }

    return ,$processedOutput
}

try {
    if (-not (Test-IsAdministrator)) {
        throw 'Run as Administrator in Windows PowerShell 5.1 (powershell.exe).'
    }

    if ($RefreshServices) { Restart-UpdateServices }

    $updates = Search-Updates
    Write-Host "Found $($updates.Count) update(s)."

    if ($updates.Count -eq 0) { return }

    $batches = Build-Batches $updates
    Write-Host "`nBatch plan ($($batches.Count) batch(es)):"

    for ($b = 0; $b -lt $batches.Count; $b++) {
        $batchUpdates = $batches[$b]
        $batchSizeMB = [math]::Round((($batchUpdates | Measure-Object -Property EstimatedSize -Sum).Sum / 1MB), 1)
        Write-Host "  Batch $($b + 1): $($batchUpdates.Count) update(s), ~$batchSizeMB MB"
        foreach ($u in $batchUpdates) {
            $sizeMB = [math]::Round($u.EstimatedSize / 1MB, 1)
            Write-Host "    [$(Get-UpdateCategory $u)] $($u.Title) ($sizeMB MB)"
        }
    }
    Write-Host ''

    $i = 1
    foreach ($batch in $batches) {
        $script:BatchesProcessed++
        Download-Batch -Updates $batch -Index $i
        $results = Install-Batch -Updates $batch -Index $i

        foreach ($r in $results) {
            Write-Host "$($r.Title): $($r.Message)"
            if ($r.Reboot) { Write-Host '  Reboot required.' }
        }
        Write-Host ''

        if ($script:RebootRequiredGlobal) {
            Write-Host 'Reboot required. Re-run this script after restart.'
            exit 3010
        }

        $i++
    }

    $elapsed = (Get-Date) - $script:StartTime
    Write-Host "Done in $elapsed. Installed: $script:Installed, Failed: $script:Failed, Batches: $script:BatchesProcessed."
}
catch {
    $errorDetails = @"
Error:      $($_.Exception.Message)
Category:   $($_.CategoryInfo.Category)
Script:     $($_.InvocationInfo.ScriptName)
Line:       $($_.InvocationInfo.ScriptLineNumber)
StackTrace:
$($_.ScriptStackTrace)
"@
    Write-Error $errorDetails
    exit 1
}