#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Get-DeviceCoverage
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Tools/Get-DeviceCoverage.ps1

<#
.SYNOPSIS
    Counts which application services a KNX device has to answer, and how many of them the
    device suite actually exercises.

.DESCRIPTION
    "The suite covers everything" is a claim, not a fact, unless the surface is enumerated. Both
    sides of the comparison are read from source, never from a list kept by hand:

      surface  - the services the stack dispatches on RECEIVE (knx/src/knx/application_layer.cpp),
                 resolved to numbers through the ApduType enum in knx_types.h
      covered  - the services the suite sends ($K.Apci.* in Suites/D-Device.Tests.ps1), resolved
                 through the same numbers

    Matching is by NUMBER, not by name: the harness and the stack spell the services differently,
    and a hand-written name table would drift the moment either side is renamed.

    The application layer is not the whole story - transport layer, interface objects, the load
    state machine, datapoint types and the operator-guided flows are counted separately and are
    listed at the end as what this tool does NOT measure.

.PARAMETER KnxSrc
    Path to knx/src/knx. Default: resolved relative to this repository.

.PARAMETER Detailed
    List every service, not just the summary.

.EXAMPLE
    ./Tools/Get-DeviceCoverage.ps1 -Detailed
#>

[CmdletBinding()]
param(
    [string]$KnxSrc = '',
    [switch]$Detailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)   # scripts/Test
# Through the product's own symlink, so the tool always measures the knx the product builds against.
if (-not $KnxSrc) { $KnxSrc = Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'lib/knx/src/knx' }

. (Join-Path $PSScriptRoot '../lib/KnxLogo.ps1')
Write-KnxLogo -Title 'Device suite coverage'

$typesFile = Join-Path $KnxSrc 'knx_types.h'
$dispatchFile = Join-Path $KnxSrc 'application_layer.cpp'
foreach ($f in @($typesFile, $dispatchFile)) {
    if (-not (Test-Path $f)) { Write-Host "  not found: $f" -ForegroundColor Red; exit 1 }
}

# 1) ApduType: name -> number
$byName = @{}
$inEnum = $false
foreach ($line in (Get-Content $typesFile)) {
    if ($line -match 'enum\s+ApduType') { $inEnum = $true; continue }
    if ($inEnum -and $line -match '^\s*\}') { break }
    if ($inEnum -and $line -match '^\s*([A-Za-z_][A-Za-z_0-9]*)\s*=\s*0[xX]([0-9A-Fa-f]+)') {
        $byName[$Matches[1]] = [Convert]::ToInt32($Matches[2], 16)
    }
}
if ($byName.Count -eq 0) { Write-Host '  could not read the ApduType enum' -ForegroundColor Red; exit 1 }

# 2) services the stack dispatches on receive -> the surface a device must answer
$dispatch = Get-Content $dispatchFile -Raw
$surface = @{}
foreach ($m in [regex]::Matches($dispatch, 'case\s+([A-Z][A-Za-z_0-9]*)\s*:')) {
    $n = $m.Groups[1].Value
    if (-not $byName.ContainsKey($n)) { continue }
    if ($n -match 'Response$|Confirm$') { continue }   # a device sends those, it does not answer them
    $surface[$n] = $byName[$n]
}

# 3) services the suite sends
Import-Module (Join-Path $here 'lib/KnxTest.psm1') -Force
$apci = (Get-KnxConstants).Apci
$suiteFile = Join-Path $here 'Suites/D-Device.Tests.ps1'
$suite = Get-Content $suiteFile -Raw
$sentValues = New-Object System.Collections.Generic.HashSet[int]
foreach ($m in [regex]::Matches($suite, '\$K\.Apci\.([A-Z_0-9]+)')) {
    $n = $m.Groups[1].Value
    if ($apci.ContainsKey($n)) { [void]$sentValues.Add([int]$apci[$n]) }
}
# Services sent through a named TPDU builder instead of a raw APCI constant. Counting only
# $K.Apci.* under-reported the group services, which D-19 sends via New-TpduGroupValueRead - a
# coverage figure that is too LOW is as useless as one that is too high.
$builders = @{
    'New-TpduGroupValueRead'  = 'GROUP_VALUE_READ'
    'New-TpduGroupValueWrite' = 'GROUP_VALUE_WRITE'
}
foreach ($b in $builders.Keys) {
    if ($suite -match [regex]::Escape($b)) {
        $n = $builders[$b]
        if ($apci.ContainsKey($n)) { [void]$sentValues.Add([int]$apci[$n]) }
    }
}

$covered = @($surface.Keys | Where-Object { $sentValues.Contains([int]$surface[$_]) } | Sort-Object)
$missing = @($surface.Keys | Where-Object { -not $sentValues.Contains([int]$surface[$_]) } | Sort-Object)
$pct = if ($surface.Count -gt 0) { [Math]::Round(100.0 * $covered.Count / $surface.Count) } else { 0 }

Write-Host ("  Application services a device must answer : {0}" -f $surface.Count)
Write-Host ("  exercised by the device suite            : {0}  ({1} %)" -f $covered.Count, $pct) -ForegroundColor $(if ($pct -ge 90) { 'Green' } elseif ($pct -ge 50) { 'Yellow' } else { 'Red' })
Write-Host ''

if ($Detailed) {
    Write-Host '  covered:' -ForegroundColor Green
    foreach ($n in $covered) { Write-Host ("    + {0,-36} 0x{1:X3}" -f $n, $surface[$n]) }
    Write-Host ''
    Write-Host '  not covered:' -ForegroundColor Red
    foreach ($n in $missing) { Write-Host ("    - {0,-36} 0x{1:X3}" -f $n, $surface[$n]) }
    Write-Host ''
}

Write-Host '  NOT measured by this tool - counted and closed separately:' -ForegroundColor DarkGray
Write-Host '    transport layer behaviour (D-2), robustness (D-4), addressing (D-5)' -ForegroundColor DarkGray
Write-Host '    interface objects and their properties, the load state machine' -ForegroundColor DarkGray
Write-Host '    datapoint types and group objects, operator-guided ETS flows' -ForegroundColor DarkGray
Write-Host ''
