#!/usr/bin/env pwsh
<#
Open ■
┬────┴  Compare-Reference
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: scripts/Test/Compare-Reference.ps1

.SYNOPSIS
    Runs the conformance suite against OUR device and against a certified reference
    device, then classifies every case by how the two answered.

.DESCRIPTION
    This is the answer to "is this our bug or a wrong test expectation".

    A conformance suite is only as good as its expectations, and an expectation derived
    from a specification can still be wrong - the wrong clause, the wrong property, the
    wrong numeric value. A certified device settles it, because it has already passed the
    KNX Association's own run of these cases. So each case ID gets one of four verdicts:

      OUR DEFECT      failed on ours, passed on the reference
                      -> the strongest signal this tool produces. Fix the firmware.
      TEST SUSPECT    failed on BOTH
                      -> a certified device would not fail a correct expectation.
                         Check the test before touching the firmware.
      REFERENCE ONLY  passed on ours, failed on the reference
                      -> usually an older or differently configured reference, or a case
                         whose expectation is too lenient and ours passes by accident.
      AGREED          both passed, or both were skipped / not applicable

    THE RIG

    The reference cannot be its own traffic source, and a typical certified interface
    grants only ONE tunnel - so the second interface has to come from somewhere else:

        BDUT run:       -Ip <ours>          -TrafficIp <reference or third device>
        Reference run:  -Ip <reference>     -ReferenceTrafficIp <our second interface>

    With a Siemens interface as reference and two OpenKNX interfaces on the bench, that
    means: our RP board is the BDUT with the Siemens as traffic source, then the Siemens
    is the BDUT with our ESP board as traffic source.

    ONLY THE CONFORMANCE SUITE IS COMPARED. The feature suite asks "is this OUR product
    doing what we promised" - running it against a foreign device would produce failures
    that mean nothing.

    SAFETY: the reference is somebody's working interface. The run is forced to the Safe
    profile and destructive cases are refused, because a reference device that gets
    reconfigured stops being a reference.

.PARAMETER Ip
    Our device under test.

.PARAMETER ReferenceIp
    The certified reference device (e.g. a Siemens IP interface).

.PARAMETER TrafficIp
    Traffic source while OUR device is the BDUT. Defaults to the reference.

.PARAMETER ReferencePort
    UDP port of the reference. Defaults to -Port. Needed when the reference listens
    elsewhere, and when both "devices" are simulators on one host.

.PARAMETER Reference2Ip
    An optional SECOND certified reference. Two independent references change what a
    result means: a case failing on ours and passing on BOTH is proof, while references
    that disagree with each other say the expectation itself is contested. Without it the
    script behaves exactly as before.

.PARAMETER ReferenceTrafficIp
    Traffic source while the REFERENCE is the BDUT. Must not be the reference itself.
    Without it, the reference run has no traffic source and its "from KNX" cases skip.

.PARAMETER Quick
    Skip the timeout-measuring cases in both runs. Halves the wall clock.

.PARAMETER Suite
    Which suites to compare. Default All.

.EXAMPLE
    ./Compare-Reference.ps1 -Ip 11.11.0.126 -ReferenceIp 11.11.0.5 -ReferenceTrafficIp 11.11.0.144 -Quick
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Ip,
    [Parameter(Mandatory)][string]$ReferenceIp,
    [int]$Port = 3671,
    [int]$ReferencePort = 0,
    [string]$Reference2Ip = '',
    [int]$Reference2Port = 0,
    [string]$Reference2Pa = '',
    [string]$TrafficIp = '',
    [string]$ReferenceTrafficIp = '',
    [string]$BdutPa = '',
    [string]$ReferencePa = '',
    [string[]]$Suite = @('All'),
    [switch]$Quick,
    [string]$LoadSwitchGa = '',
    [string]$LoadSwitchPa = '',
    [string]$P2pTarget = '',
    [string]$Multicast = '224.0.23.12',
    [string]$ReportDir = ''
)

Set-StrictMode -Version Latest

function Get-KnxCaseResult {
    <#
    .SYNOPSIS
        Reads a case result from a report, whatever the field was called when it was written.
    .DESCRIPTION
        The field was renamed from Verdict to Result when the reports were reworded. Reports
        already on disk carry the old name, and a comparison that quietly ignored them would
        read as a clean run rather than a missing one. Both names are accepted here.
    #>
    param([Parameter(Mandatory)]$Case)
    if ($Case.PSObject.Properties['Result'])  { return "$($Case.Result)" }
    if ($Case.PSObject.Properties['Verdict']) { return "$($Case.Verdict)" }
    return ''
}
$ErrorActionPreference = 'Continue'

$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)  # scripts/Test root
# Setting UTF-8 output is harmless on every platform, so it needs no $IsWindows guard - and
# that guard was itself the portability bug: 5.1 does not define the variable, and under
# Set-StrictMode reading it throws before the first test ever runs.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
if (-not $ReportDir) { $ReportDir = Join-Path $here 'Reports' }
if (-not (Test-Path $ReportDir)) { [void](New-Item -ItemType Directory -Path $ReportDir -Force) }

$runStart = Get-Date
$stamp = $runStart.ToString('yyyyMMdd-HHmmss')
$cmpDir = Join-Path $ReportDir "Compare_$stamp"
$ourDir = Join-Path $cmpDir 'ours'
$refDir = Join-Path $cmpDir 'reference'
foreach ($d in @($cmpDir, $ourDir, $refDir)) { [void](New-Item -ItemType Directory -Path $d -Force) }

Write-Host ''
Write-Host '  Open ■' -ForegroundColor Green
Write-Host '  ┬────┴  Reference comparison' -ForegroundColor Green
Write-Host '  ■ KNX   2026 OpenKNX - Erkan Çolak' -ForegroundColor DarkGray
Write-Host ''

if (-not $TrafficIp) { $TrafficIp = $ReferenceIp }
if ($ReferenceTrafficIp -eq $ReferenceIp) {
    Write-Host '  ABORT: -ReferenceTrafficIp must not be the reference itself.' -ForegroundColor Red
    Write-Host '  A device cannot generate the bus traffic it is being tested against.' -ForegroundColor Red
    exit 2
}

Write-Host "  Our device      : $Ip   (traffic: $TrafficIp)"
Write-Host "  Reference       : $ReferenceIp$(if ($ReferencePort -gt 0 -and $ReferencePort -ne $Port) { ":$ReferencePort" } else { '' })   (traffic: $(if ($ReferenceTrafficIp) { $ReferenceTrafficIp } else { '<none - from-KNX cases will skip>' }))"
Write-Host "  Suites          : $($Suite -join ', ')$(if ($Quick) { '  (quick)' } else { '' })"
Write-Host '  Profile         : Safe (forced - the reference must come back unchanged)' -ForegroundColor DarkGray
Write-Host ''
if (-not $ReferenceTrafficIp) {
    Write-Host '  NOTE: without -ReferenceTrafficIp the reference run cannot exercise the' -ForegroundColor Yellow
    Write-Host '  "from KNX" cases. They will be SKIP on the reference and therefore land in' -ForegroundColor Yellow
    Write-Host '  AGREED rather than telling you anything. Give it a second interface.' -ForegroundColor Yellow
    Write-Host ''
}

# ─── Run both ───────────────────────────────────────────────────────────────────

function Invoke-Run {
    param([string]$Label, [string]$Bdut, [int]$BdutPort, [string]$Traffic, [string]$Pa, [string]$Dir)
    Write-Host ('  ' + ('═' * 72)) -ForegroundColor DarkCyan
    Write-Host "  $Label  ->  $Bdut" -ForegroundColor Cyan
    Write-Host ('  ' + ('═' * 72)) -ForegroundColor DarkCyan

    $a = @('-Ip', $Bdut, '-Port', "$BdutPort", '-RunProfile', 'Safe', '-ReportDir', $Dir,
        '-Multicast', $Multicast, '-Suite', ($Suite -join ','))
    if ($LoadSwitchGa) { $a += @('-LoadSwitchGa', $LoadSwitchGa) }
    if ($LoadSwitchPa) { $a += @('-LoadSwitchPa', $LoadSwitchPa) }
    if ($P2pTarget) { $a += @('-P2pTarget', $P2pTarget) }
    if ($Traffic) { $a += @('-TrafficIp', $Traffic) }
    if ($Pa) { $a += @('-BdutPa', $Pa) }
    if ($Quick) { $a += '-SkipSlow' }

    # Out-Host, not a bare call: the child's stdout would otherwise become part of THIS
    # function's return value, and the caller would receive an array of console lines with
    # the parsed report buried at the end.
    & pwsh -NoProfile -File (Join-Path $here 'runners/Invoke-Conformance.ps1') @a | Out-Host
    $json = Get-ChildItem -Path $Dir -Filter '*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $json) { return $null }
    try { return (Get-Content -Path $json.FullName -Raw | ConvertFrom-Json) } catch { return $null }
}

if ($ReferencePort -le 0) { $ReferencePort = $Port }
$ours = Invoke-Run -Label 'RUN 1 of 2  our device' -Bdut $Ip -BdutPort $Port -Traffic $TrafficIp -Pa $BdutPa -Dir $ourDir
if ($null -eq $ours) {
    Write-Host ''
    Write-Host '  ABORT: the run against our device produced no report.' -ForegroundColor Red
    exit 3
}

$totalRuns = 2
if ($Reference2Ip) { $totalRuns = 3 }
$ref = Invoke-Run -Label "RUN 2 of $totalRuns  reference A" -Bdut $ReferenceIp -BdutPort $ReferencePort -Traffic $ReferenceTrafficIp -Pa $ReferencePa -Dir $refDir
if ($null -eq $ref) {
    Write-Host ''
    Write-Host '  ABORT: the run against the reference produced no report.' -ForegroundColor Red
    exit 3
}

$ref2 = $null
if ($Reference2Ip) {
    if ($Reference2Port -le 0) { $Reference2Port = $Port }
    $ref2Dir = Join-Path $cmpDir 'reference2'
    [void](New-Item -ItemType Directory -Path $ref2Dir -Force)
    $ref2 = Invoke-Run -Label 'RUN 3 of 3  reference B' -Bdut $Reference2Ip -BdutPort $Reference2Port -Traffic $ReferenceTrafficIp -Pa $Reference2Pa -Dir $ref2Dir
    if ($null -eq $ref2) {
        Write-Host ''
        Write-Host '  WARNING: the second reference produced no report - continuing with one reference.' -ForegroundColor Yellow
    }
}

# ─── Join by case id ────────────────────────────────────────────────────────────

$byId = @{}
foreach ($r in $ours.results) {
    $byId["$($r.Id)"] = [pscustomobject]@{
        Id = "$($r.Id)"; Title = "$($r.Title)"; Clause = "$($r.Clause)"
        Ours = (Get-KnxCaseResult -Case $r); OursReason = "$($r.Reason)"
        Ref = '-'; RefReason = ''
        Ref2 = '-'; Ref2Reason = ''
    }
}
foreach ($r in $ref.results) {
    $id = "$($r.Id)"
    if ($byId.ContainsKey($id)) {
        $byId[$id].Ref = (Get-KnxCaseResult -Case $r)
        $byId[$id].RefReason = "$($r.Reason)"
    }
    else {
        $byId[$id] = [pscustomobject]@{
            Id = $id; Title = "$($r.Title)"; Clause = "$($r.Clause)"
            Ours = '-'; OursReason = ''
            Ref = (Get-KnxCaseResult -Case $r); RefReason = "$($r.Reason)"
            Ref2 = '-'; Ref2Reason = ''
        }
    }
}

if ($null -ne $ref2) {
    foreach ($r in $ref2.results) {
        $id = "$($r.Id)"
        if (-not $byId.ContainsKey($id)) { continue }
        $byId[$id].Ref2 = (Get-KnxCaseResult -Case $r)
        $byId[$id].Ref2Reason = "$($r.Reason)"
    }
}

# With two references the classes carry different weight, so they are kept apart rather
# than merged: "both references pass" is proof, "the references disagree" is not.
$ourDefect = @(); $ourDefectWeak = @(); $testSuspect = @(); $refDisagree = @(); $refOnly = @(); $agreed = @()
foreach ($id in ($byId.Keys | Sort-Object)) {
    $c = $byId[$id]
    $oFail = ($c.Ours -eq 'FAIL')
    $refPass = @(); $refFail = @()
    foreach ($v in @(@{n = 'A'; v = $c.Ref }, @{n = 'B'; v = $c.Ref2 })) {
        if ($v.v -eq 'PASS') { $refPass += $v.n }
        elseif ($v.v -eq 'FAIL') { $refFail += $v.n }
    }
    if ($oFail) {
        if ($refPass.Count -gt 0 -and $refFail.Count -eq 0) { $ourDefect += $c; continue }
        if ($refPass.Count -gt 0 -and $refFail.Count -gt 0) { $ourDefectWeak += $c; continue }
        if ($refFail.Count -gt 0) { $testSuspect += $c; continue }
        $agreed += $c; continue
    }
    if ($refPass.Count -gt 0 -and $refFail.Count -gt 0) { $refDisagree += $c; continue }
    if ($c.Ours -eq 'PASS' -and $refFail.Count -gt 0) { $refOnly += $c; continue }
    $agreed += $c
}

# ─── Result ─────────────────────────────────────────────────────────────────────

$runEnd = Get-Date
$minutes = [Math]::Round(($runEnd - $runStart).TotalMinutes, 1)

Write-Host ''
Write-Host ('  ' + ('═' * 72)) -ForegroundColor DarkCyan
Write-Host '  COMPARISON' -ForegroundColor Cyan
Write-Host ('  ' + ('═' * 72)) -ForegroundColor DarkCyan
Write-Host ''
Write-Host "  Our device  : $Ip  ($($ours.summary.Pass) pass / $($ours.summary.Fail) fail)"
Write-Host "  Reference A : $ReferenceIp  ($($ref.summary.Pass) pass / $($ref.summary.Fail) fail)"
if ($null -ne $ref2) { Write-Host "  Reference B : $Reference2Ip  ($($ref2.summary.Pass) pass / $($ref2.summary.Fail) fail)" }
Write-Host "  Wall clock : $minutes min"
Write-Host ''

if ($ourDefect.Count -gt 0) {
    Write-Host "  OUR DEFECT - failed on ours, PASSED on the certified reference ($($ourDefect.Count))" -ForegroundColor Red
    Write-Host ('  ' + ('-' * 68)) -ForegroundColor DarkGray
    foreach ($c in $ourDefect) {
        Write-Host ("  {0}  {1}" -f $c.Id.PadRight(11), $c.Title) -ForegroundColor Red
        Write-Host ("      $($c.Clause)") -ForegroundColor DarkGray
        Write-Host ("      ours: $($c.OursReason)") -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  These are the ones to fix. A certified device passes them.' -ForegroundColor Red
    Write-Host ''
}

if ($ourDefectWeak.Count -gt 0) {
    Write-Host "  OUR DEFECT (weak) - one reference passes, the other fails ($($ourDefectWeak.Count))" -ForegroundColor Yellow
    Write-Host ('  ' + ('-' * 68)) -ForegroundColor DarkGray
    foreach ($c in $ourDefectWeak) {
        Write-Host ("  {0}  {1}" -f $c.Id.PadRight(11), $c.Title) -ForegroundColor Yellow
        Write-Host ("      ours: $($c.OursReason)") -ForegroundColor DarkGray
        Write-Host ("      ref A: $($c.Ref)   ref B: $($c.Ref2)") -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  At least one certified device passes, so the expectation is achievable - but the' -ForegroundColor Yellow
    Write-Host '  references disagree, so check WHY the other one fails before treating it as proof.' -ForegroundColor Yellow
    Write-Host ''
}

if ($refDisagree.Count -gt 0) {
    Write-Host "  REFERENCES DISAGREE - ours passes, the two references differ ($($refDisagree.Count))" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 68)) -ForegroundColor DarkGray
    foreach ($c in $refDisagree) {
        Write-Host ("  {0}  {1}   (A: {2}, B: {3})" -f $c.Id.PadRight(11), $c.Title, $c.Ref, $c.Ref2) -ForegroundColor Cyan
    }
    Write-Host ''
}

if ($testSuspect.Count -gt 0) {
    Write-Host "  TEST SUSPECT - failed on ours AND on every reference ($($testSuspect.Count))" -ForegroundColor Yellow
    Write-Host ('  ' + ('-' * 68)) -ForegroundColor DarkGray
    foreach ($c in $testSuspect) {
        Write-Host ("  {0}  {1}" -f $c.Id.PadRight(11), $c.Title) -ForegroundColor Yellow
        Write-Host ("      ours     : $($c.OursReason)") -ForegroundColor DarkGray
        Write-Host ("      reference: $($c.RefReason)") -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  A certified device does not fail a correct expectation. Check the TEST first -' -ForegroundColor Yellow
    Write-Host '  wrong clause, wrong property, wrong numeric value - before touching firmware.' -ForegroundColor Yellow
    Write-Host '  (A rig limitation that hits both devices lands here too - read the reasons.)' -ForegroundColor DarkGray
    Write-Host ''
}

if ($refOnly.Count -gt 0) {
    Write-Host "  REFERENCE ONLY - passed on ours, failed on the reference ($($refOnly.Count))" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 68)) -ForegroundColor DarkGray
    foreach ($c in $refOnly) {
        Write-Host ("  {0}  {1}" -f $c.Id.PadRight(11), $c.Title) -ForegroundColor Cyan
        Write-Host ("      reference: $($c.RefReason)") -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '  Either the reference is older/configured differently, or the expectation is so' -ForegroundColor Cyan
    Write-Host '  lenient that ours passes by accident. Worth a look either way.' -ForegroundColor Cyan
    Write-Host ''
}

Write-Host "  AGREED: $($agreed.Count) case(s) where both devices answered the same way." -ForegroundColor DarkGray
Write-Host ''
if ($ourDefect.Count -eq 0 -and $testSuspect.Count -eq 0) {
    Write-Host '  ┌────────────────────────────────────────────────────────────────┐' -ForegroundColor Green
    Write-Host '  │  OUR DEVICE MATCHES THE CERTIFIED REFERENCE                    │' -ForegroundColor Green
    Write-Host '  └────────────────────────────────────────────────────────────────┘' -ForegroundColor Green
}

# ─── Report ─────────────────────────────────────────────────────────────────────

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine('# Reference comparison')
[void]$md.AppendLine('')
[void]$md.AppendLine("Our device: ``$Ip``  |  reference: ``$ReferenceIp``  |  $minutes min  ")
[void]$md.AppendLine("Run: $($runStart.ToString('yyyy-MM-dd HH:mm:ss'))")
[void]$md.AppendLine('')
[void]$md.AppendLine('| Class | Count | Meaning |')
[void]$md.AppendLine('|---|---|---|')
[void]$md.AppendLine("| OUR DEFECT | $($ourDefect.Count) | failed on ours, passed on the certified reference |")
[void]$md.AppendLine("| TEST SUSPECT | $($testSuspect.Count) | failed on both - check the expectation first |")
[void]$md.AppendLine("| REFERENCE ONLY | $($refOnly.Count) | passed on ours, failed on the reference |")
[void]$md.AppendLine("| AGREED | $($agreed.Count) | both answered the same |")
[void]$md.AppendLine('')

foreach ($blk in @(
        @{ Name = 'OUR DEFECT'; Items = $ourDefect; Note = 'A certified device passes these. Fix the firmware.' },
        @{ Name = 'TEST SUSPECT'; Items = $testSuspect; Note = 'Failed on both. Verify the test expectation against the implementation before blaming the device.' },
        @{ Name = 'REFERENCE ONLY'; Items = $refOnly; Note = 'Passed on ours only.' })) {
    if ($blk.Items.Count -eq 0) { continue }
    [void]$md.AppendLine("## $($blk.Name)")
    [void]$md.AppendLine('')
    [void]$md.AppendLine($blk.Note)
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| ID | Case | Clause | Ours | Reference |')
    [void]$md.AppendLine('|---|---|---|---|---|')
    foreach ($c in $blk.Items) {
        $o = ($c.OursReason -replace '\|', '\|')
        $r = ($c.RefReason -replace '\|', '\|')
        [void]$md.AppendLine("| ``$($c.Id)`` | $($c.Title) | $($c.Clause) | **$($c.Ours)** $o | **$($c.Ref)** $r |")
    }
    [void]$md.AppendLine('')
}

$mdPath = Join-Path $ReportDir "Compare_$stamp.md"
$jsonPath = Join-Path $ReportDir "Compare_$stamp.json"
[System.IO.File]::WriteAllText($mdPath, $md.ToString())
([pscustomobject]@{
        started = $runStart.ToString('o'); finished = $runEnd.ToString('o')
        ours = $Ip; reference = $ReferenceIp
        reference2 = $Reference2Ip
        counts = @{ ourDefect = $ourDefect.Count; ourDefectWeak = $ourDefectWeak.Count; testSuspect = $testSuspect.Count; referencesDisagree = $refDisagree.Count; referenceOnly = $refOnly.Count; agreed = $agreed.Count }
        ourDefect = @($ourDefect); ourDefectWeak = @($ourDefectWeak); testSuspect = @($testSuspect); referencesDisagree = @($refDisagree); referenceOnly = @($refOnly)
    }) | ConvertTo-Json -Depth 6 | Set-Content -Path $jsonPath -Encoding UTF8

Write-Host "  Report: $mdPath" -ForegroundColor Cyan
Write-Host "  Data  : $jsonPath" -ForegroundColor DarkGray
Write-Host "  Both runs: $cmpDir" -ForegroundColor DarkGray
Write-Host ''

if ($ourDefect.Count -gt 0 -or $ourDefectWeak.Count -gt 0) { exit 1 }
exit 0
