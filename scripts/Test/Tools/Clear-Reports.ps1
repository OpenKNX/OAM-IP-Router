#!/usr/bin/env pwsh
<#
Open ■
┬────┴  Clear-Reports
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: scripts/Test/Tools/Clear-Reports.ps1

.SYNOPSIS
    Removes test reports - after showing exactly what will go and asking.

.DESCRIPTION
    Reports pile up: every run writes a Markdown and a JSON, the comparison runs write a
    folder each, and the hardening stage writes into the OFM-FileTransferModule tree. After
    a week of certification work the directory is unreadable and the newest run is buried.

    Deleting is not undoable, so this never does it silently. It lists what it found per
    directory with counts, sizes and the date range, and asks once. -KeepLast keeps the
    newest runs, which is what you usually want: the last green run stays as the reference
    to compare the next one against.

    It only ever touches the report directories it knows, and only files a run produced.
    Nothing outside them is looked at - .last-run.json, the suites and the library live
    elsewhere and cannot be reached from here.

.PARAMETER KeepLast
    Keep the newest N reports per directory. Default 0 - remove everything.

.PARAMETER IncludeHardening
    Also clear the hardening reports in OFM-FileTransferModule. They belong to the same
    runs, so this defaults to on; pass -IncludeHardening:$false to leave that tree alone.

.PARAMETER Force
    Do not ask. For scripted use.

.PARAMETER DryRun
    Show what would go and stop.

.EXAMPLE
    ./Clear-Reports.ps1
.EXAMPLE
    ./Clear-Reports.ps1 -KeepLast 3
.EXAMPLE
    ./Clear-Reports.ps1 -DryRun
#>

[CmdletBinding()]
param(
    [int]$KeepLast = 0,
    [bool]$IncludeHardening = $true,
    [switch]$Force,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Show-Logo {
    Write-Host ''
    Write-Host '  Open ■' -ForegroundColor Green
    Write-Host '  ┬────┴  Clear test reports' -ForegroundColor Green
    Write-Host '  ■ KNX   2026 OpenKNX - Erkan Çolak' -ForegroundColor DarkGray
    Write-Host ''
}

function Get-ReportTargets {
    <#
    .SYNOPSIS
        Collects the report files and comparison folders of one directory, newest first.
    .DESCRIPTION
        A run writes <name>_<stamp>.md and .json; Compare-Reference additionally writes a
        folder of the same stem. Both are grouped under the stem so -KeepLast counts RUNS,
        not files - keeping "the last 3" must not leave a report without its data.
    #>
    param([string]$Directory)
    if (-not (Test-Path $Directory)) { return @() }
    $items = @(Get-ChildItem -Path $Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '_\d{8}-\d{6}' -or $_.Extension -in @('.md', '.json', '.log') })
    $groups = @()
    foreach ($g in ($items | Group-Object { ($_.BaseName -replace '\.(json|md|log)$', '') })) {
        $newest = ($g.Group | Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
        $bytes = 0
        foreach ($f in $g.Group) {
            if ($f.PSIsContainer) { $bytes += (Get-ChildItem $f.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }
            else { $bytes += $f.Length }
        }
        $groups += [pscustomobject]@{ Stem = $g.Name; Files = @($g.Group); When = $newest; Bytes = [int64]$bytes }
    }
    # No ", @(...)": the comma wraps the list in ANOTHER list, so the caller's foreach runs
    # once over the whole array and "$g.Bytes" then yields every size at once. Emitting the
    # elements is what @() at the call site expects.
    return @($groups | Sort-Object When -Descending)
}

function Format-Size {
    param([int64]$Bytes)
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

Show-Logo

$dirs = @(
    @{ Name = 'Test reports';      Path = (Join-Path $testRoot 'Reports') }
    @{ Name = 'Soak / tool logs';  Path = (Join-Path $testRoot 'logs') }
)
if ($IncludeHardening) {
    # The hardening stage writes next to its own runner, in the shared FTC module.
    $ftm = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $testRoot))) 'OFM-FileTransferModule/scripts/Hardening/Reports'
    $dirs += @{ Name = 'Hardening reports'; Path = $ftm }
}

$plan = @()
$totalFiles = 0
$totalBytes = [int64]0
foreach ($d in $dirs) {
    $groups = @(Get-ReportTargets -Directory $d.Path)
    $keep = @($groups | Select-Object -First $KeepLast)
    $drop = @($groups | Select-Object -Skip $KeepLast)
    $bytes = [int64]0
    $files = 0
    foreach ($g in $drop) { $bytes += $g.Bytes; $files += $g.Files.Count }
    $plan += [pscustomobject]@{ Name = $d.Name; Path = $d.Path; Drop = $drop; Keep = $keep; Files = $files; Bytes = $bytes }
    $totalFiles += $files
    $totalBytes += $bytes
}

foreach ($p in $plan) {
    if (-not (Test-Path $p.Path)) {
        Write-Host ("  {0,-20} (no such directory)" -f $p.Name) -ForegroundColor DarkGray
        continue
    }
    if ($p.Drop.Count -eq 0) {
        Write-Host ("  {0,-20} nothing to remove" -f $p.Name) -ForegroundColor DarkGray
        continue
    }
    $oldest = ($p.Drop | Select-Object -Last 1).When
    $newest = ($p.Drop | Select-Object -First 1).When
    Write-Host ("  {0,-20} {1} run(s), {2,-9} {3:yyyy-MM-dd} .. {4:yyyy-MM-dd}" -f `
                 $p.Name, $p.Drop.Count, (Format-Size -Bytes $p.Bytes), $oldest, $newest)
    Write-Host ("  {0,-20} {1}" -f '', $p.Path) -ForegroundColor DarkGray
    if ($p.Keep.Count -gt 0) {
        Write-Host ("  {0,-20} keeping the newest {1}: {2}" -f '', $p.Keep.Count, (($p.Keep | ForEach-Object { $_.Stem }) -join ', ')) -ForegroundColor Green
    }
}

Write-Host ''
if ($totalFiles -eq 0) {
    Write-Host '  Nothing to remove.' -ForegroundColor Green
    Write-Host ''
    exit 0
}
Write-Host ("  Total: {0} file(s)/folder(s), {1}" -f $totalFiles, (Format-Size -Bytes $totalBytes)) -ForegroundColor Cyan

if ($DryRun) {
    Write-Host '  -DryRun: nothing was removed.' -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

if (-not $Force) {
    Write-Host ''
    Write-Host '  This cannot be undone. Remove them? [y/N]' -ForegroundColor Yellow
    $answer = Read-Host '  >'
    if ("$answer".Trim() -notmatch '^(y|yes|j|ja)$') {
        Write-Host '  Nothing was removed.' -ForegroundColor Green
        Write-Host ''
        exit 0
    }
}

$removed = 0
$failed = @()
foreach ($p in $plan) {
    foreach ($g in $p.Drop) {
        foreach ($f in $g.Files) {
            try {
                Remove-Item -LiteralPath $f.FullName -Recurse -Force -ErrorAction Stop
                $removed++
            }
            catch { $failed += "$($f.Name): $($_.Exception.Message)" }
        }
    }
}

Write-Host ''
Write-Host ("  Removed {0} file(s)/folder(s), {1} freed." -f $removed, (Format-Size -Bytes $totalBytes)) -ForegroundColor Green
if ($failed.Count -gt 0) {
    Write-Host '  Could not remove:' -ForegroundColor Red
    foreach ($f in $failed) { Write-Host "    $f" -ForegroundColor Red }
}
Write-Host ''
exit $(if ($failed.Count -gt 0) { 1 } else { 0 })
