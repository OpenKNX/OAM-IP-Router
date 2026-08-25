#!/usr/bin/env pwsh
<#
Open ■
┬────┴  Sync-TestLib
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: scripts/Test/Sync-TestLib.ps1

.SYNOPSIS
    Compares - and on request propagates - the shared conformance test library between
    OAM-IP-Interface and OAM-IP-Router.

.DESCRIPTION
    The suite lives as an identical copy in both product repositories: each stays
    self-contained and runnable on its own, at the price of a duplicate that has to be
    kept honest. This script is what keeps it honest.

    By default it only REPORTS: which files differ, which are missing on either side,
    and which are identical. Nothing is written without -Apply, and -Apply always states
    the direction explicitly - there is no "sync" that guesses which side is newer.

    Timestamps are deliberately NOT used to decide anything. A file edited later is not
    automatically the correct one, and silently overwriting the other repository on that
    assumption is how a fix gets lost.

.PARAMETER Other
    Path to the other product's scripts/Test directory. Defaults to the sibling
    OAM-IP-Router (or OAM-IP-Interface, depending on where this copy lives).

.PARAMETER Apply
    Push | Pull. Push copies THIS repository's files over the other one, Pull the
    reverse. Without it the script only reports.

.PARAMETER Force
    Required together with -Apply when a file differs on both sides in the same run -
    i.e. when the copy has genuinely diverged rather than one side simply being older.

.EXAMPLE
    ./Sync-TestLib.ps1
.EXAMPLE
    ./Sync-TestLib.ps1 -Apply Push
.EXAMPLE
    ./Sync-TestLib.ps1 -Other ../../OAM-IP-Router/scripts/Test -Apply Pull
#>

[CmdletBinding()]
param(
    [string]$Other = '',
    [ValidateSet('Push', 'Pull')]
    [string]$Apply = '',
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)  # scripts/Test root

# The files that make up the shared library. Product specific things (Reports, the
# existing hardening scripts, repro) are NOT part of it and are never touched.
$shared = @(
    'Run-Tests.ps1',
    'stress/Invoke-Stress.ps1',
    'README.md',
    'lib/KnxTest.psm1',
    'lib/Sync-TestLib.ps1',
    'lib/KnxSerial.psm1',
    'runners/Invoke-Conformance.ps1',
    'runners/Invoke-AllTests.ps1',
    'runners/Invoke-Endurance.ps1',
    'runners/Invoke-DeviceTests.ps1',
    'runners/Compare-Reference.ps1',
    'Features/Test-Features.ps1',
    'Features/Test-Busmonitor.ps1',
    'Suites/3-Core.Tests.ps1',
    'Suites/4-DeviceManagement.Tests.ps1',
    'Suites/5-Tunnelling.Tests.ps1',
    'Suites/6-Routing.Tests.ps1',
    'Suites/7-RemoteDiag.Tests.ps1',
    'Suites/8-IpMedium.Tests.ps1',
    'Suites/D-Device.Tests.ps1',
    'Tools/Clear-Reports.ps1',
    'Tools/Start-FakeKnxDevice.ps1'
)

function Get-FileHashOrNull {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash
}

Write-Host ''
Write-Host '  Open ■' -ForegroundColor Green
Write-Host '  ┬────┴  Shared test library sync' -ForegroundColor Green
Write-Host '  ■ KNX   2026 OpenKNX - Erkan Çolak' -ForegroundColor DarkGray
Write-Host ''

if (-not $Other) {
    # Guess the sibling product from where this copy lives.
    $repoRoot = Split-Path -Parent (Split-Path -Parent $here)
    $parent = Split-Path -Parent $repoRoot
    $selfName = Split-Path -Leaf $repoRoot
    $siblingName = if ($selfName -eq 'OAM-IP-Interface') { 'OAM-IP-Router' } else { 'OAM-IP-Interface' }
    $Other = Join-Path (Join-Path $parent $siblingName) 'scripts/Test'
}

Write-Host "  This side  : $here"
Write-Host "  Other side : $Other"
Write-Host ''

if (-not (Test-Path $Other)) {
    Write-Host "  The other side does not exist yet: $Other" -ForegroundColor Yellow
    if ($Apply -ne 'Push') {
        Write-Host '  Run with -Apply Push to create it.' -ForegroundColor Yellow
        Write-Host ''
        exit 1
    }
    [void](New-Item -ItemType Directory -Path $Other -Force)
}

$same = 0; $diff = @(); $missingThere = @(); $missingHere = @()

foreach ($rel in $shared) {
    $a = Join-Path $here $rel
    $b = Join-Path $Other $rel
    $ha = Get-FileHashOrNull -Path $a
    $hb = Get-FileHashOrNull -Path $b

    if ($null -eq $ha -and $null -eq $hb) { continue }
    if ($null -eq $hb) { $missingThere += $rel; continue }
    if ($null -eq $ha) { $missingHere += $rel; continue }
    if ($ha -eq $hb) { $same++; continue }
    $diff += $rel
}

Write-Host "  identical      : $same"
Write-Host "  different      : $($diff.Count)" -ForegroundColor $(if ($diff.Count) { 'Yellow' } else { 'DarkGray' })
foreach ($f in $diff) { Write-Host "      $f" -ForegroundColor Yellow }
Write-Host "  missing there  : $($missingThere.Count)" -ForegroundColor $(if ($missingThere.Count) { 'Yellow' } else { 'DarkGray' })
foreach ($f in $missingThere) { Write-Host "      $f" -ForegroundColor Yellow }
Write-Host "  missing here   : $($missingHere.Count)" -ForegroundColor $(if ($missingHere.Count) { 'Yellow' } else { 'DarkGray' })
foreach ($f in $missingHere) { Write-Host "      $f" -ForegroundColor Yellow }
Write-Host ''

if (-not $Apply) {
    if ($diff.Count -eq 0 -and $missingThere.Count -eq 0 -and $missingHere.Count -eq 0) {
        Write-Host '  The two copies are in sync.' -ForegroundColor Green
        Write-Host ''
        exit 0
    }
    Write-Host '  Report only. Use -Apply Push or -Apply Pull to propagate.' -ForegroundColor Cyan
    Write-Host '  Check the differences first - the newer file is not automatically the right one.' -ForegroundColor DarkGray
    Write-Host ''
    exit 1
}

# Both sides have content that the other lacks: that is real divergence, not staleness.
if ($missingThere.Count -gt 0 -and $missingHere.Count -gt 0 -and -not $Force) {
    Write-Host '  Both copies contain files the other does not. That is divergence, not a stale copy.' -ForegroundColor Red
    Write-Host '  Review it and re-run with -Force if you really want to overwrite one side.' -ForegroundColor Red
    Write-Host ''
    exit 2
}

$src = $here; $dst = $Other
if ($Apply -eq 'Pull') { $src = $Other; $dst = $here }

$copied = 0
foreach ($rel in $shared) {
    $from = Join-Path $src $rel
    if (-not (Test-Path $from)) { continue }
    $to = Join-Path $dst $rel
    $toDir = Split-Path -Parent $to
    if (-not (Test-Path $toDir)) { [void](New-Item -ItemType Directory -Path $toDir -Force) }
    $hFrom = Get-FileHashOrNull -Path $from
    $hTo = Get-FileHashOrNull -Path $to
    if ($hFrom -eq $hTo) { continue }
    Copy-Item -Path $from -Destination $to -Force
    Write-Host "  $($Apply.ToLower()) $rel" -ForegroundColor Green
    $copied++
}

Write-Host ''
Write-Host "  $copied file(s) copied ($Apply)." -ForegroundColor Green
Write-Host '  Run Invoke-Conformance.ps1 -SelfTest on BOTH sides before trusting either.' -ForegroundColor Cyan
Write-Host ''
exit 0
