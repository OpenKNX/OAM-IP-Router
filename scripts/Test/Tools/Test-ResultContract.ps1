#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Test-ResultContract
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Tools/Test-ResultContract.ps1

<#
.SYNOPSIS
    Checks that Invoke-KnxTestCase still awards the result each case shape has earned.

.DESCRIPTION
    Offline, no device, no network. Runs synthetic cases through the real library and compares the
    result and the assertion count against what the contract says they must be.

    It exists because nothing else guards this. Invoke-KnxSelfTest contains no Invoke-KnxTestCase
    call at all - it compares byte vectors - so its pass count says nothing about the result logic. A
    regression there is invisible: every case keeps reporting a result, just the wrong one.

    The case that matters most is NA-FROM-GATE. A gate that sets N-A and returns has also asserted
    nothing, so if the two conditions are ever confused, every case on a device WITHOUT the feature
    flips from "does not apply" to "proved nothing" - a statement about the run masquerading as a
    statement about the device.

.PARAMETER Quiet
    Leave out the per-check "ok" lines; the library still prints each synthetic case.

.EXAMPLE
    pwsh Tools/Test-ResultContract.ps1
    Runs every contract check and exits 1 when any of them is broken.

.NOTES
    PowerShell 5.1 compatible, UTF-8 with BOM (logo glyphs), no modules beyond the test library.
#>
[CmdletBinding()]
param([switch]$Quiet)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $here 'lib/KnxTest.psm1') -Force

. (Join-Path $PSScriptRoot '../lib/KnxLogo.ps1')
Write-KnxLogo -Title 'Result contract'

# Gates as the suites really write them: a scriptblock that ends the case from inside a helper.
$naGate     = { param([string]$What) Set-KnxTestNotApplicable "device does not have $What" }
$skipGate   = { param([string]$What) Set-KnxTestSkip "no input for $What" }
$notRunGate = { param([string]$What) Set-KnxTestNotRun -MissingInput '-TestGa' -Reason "needs a GA for $What" }
$helper     = { Assert-KnxTrue $true 'asserted inside a helper' }

# Id, expected result, expected assertion count, body.
$contract = @(
    @{ Id = 'PASS-ASSERTS';  Result = 'PASS';     Count = 1; Body = { Assert-KnxTrue $true 'holds' } }
    @{ Id = 'FAIL-ASSERTS';  Result = 'FAIL';     Count = 1; Body = { Assert-KnxTrue $false 'does not hold' } }
    @{ Id = 'NOPROOF-MUTE';  Result = 'NO-PROOF'; Count = 0; Body = { Add-KnxEvidence -Note 'says nothing' } }
    @{ Id = 'PASS-HELPER';   Result = 'PASS';     Count = 1; Body = { & $helper } }
    @{ Id = 'PASS-DEEP';     Result = 'PASS';     Count = 1; Body = { $outer = { & $helper }; & $outer } }
    # A failing assertion must be counted BEFORE it throws, or it looks like no assertion at all.
    @{ Id = 'FAIL-HELPER';   Result = 'FAIL';     Count = 1; Body = { $outer = { Assert-KnxTrue $false 'deep' }; & $outer } }
    @{ Id = 'NA-FROM-GATE';  Result = 'N-A';      Count = 0; Body = { & $naGate 'the feature' } }
    @{ Id = 'SKIP-FROM-GATE';Result = 'SKIP';     Count = 0; Body = { & $skipGate 'the feature' } }
    @{ Id = 'NOTRUN-GATE';   Result = 'NOT-RUN';  Count = 0; Body = { & $notRunGate 'the feature' } }
    @{ Id = 'NA-DEEP';       Result = 'N-A';      Count = 0; Body = { $outer = { & $naGate 'the nested feature' }; & $outer } }
    # An unhandled error is a failed case, never an unproven one.
    @{ Id = 'THROW-IS-FAIL'; Result = 'FAIL';     Count = 0; Body = { throw 'boom' } }
    @{ Id = 'COUNTS-THREE';  Result = 'PASS';     Count = 3; Body = { Assert-KnxTrue $true 'a'; Assert-KnxTrue $true 'b'; Assert-KnxTrue $true 'c' } }
)

$run = Start-KnxTestRun -Product 'result contract' -BdutIp '0.0.0.0'
foreach ($c in $contract) {
    Invoke-KnxTestCase -Suite 'Contract' -Id $c.Id -Title $c.Id -Clause 'harness contract' -Body $c.Body
}

$byId = @{}
foreach ($r in $run.Results) { $byId[[string]$r.Id] = $r }

$failed = 0
foreach ($c in $contract) {
    $r = $null
    if ($byId.ContainsKey($c.Id)) { $r = $byId[$c.Id] }
    if ($null -eq $r) {
        Write-Host ("  BROKEN  {0,-16} the case produced no result at all" -f $c.Id) -ForegroundColor Red
        $failed++
        continue
    }
    $gotResult = [string]$r.Result
    $gotCount = -1
    if ($null -ne $r.PSObject.Properties['Assertions']) { $gotCount = [int]$r.Assertions }
    $okResult = ($gotResult -eq $c.Result)
    $okCount = ($gotCount -eq $c.Count)
    if ($okResult -and $okCount) {
        if (-not $Quiet) { Write-Host ("  ok      {0,-16} {1,-9} {2} assertion(s)" -f $c.Id, $gotResult, $gotCount) -ForegroundColor DarkGray }
    }
    else {
        $why = @()
        if (-not $okResult) { $why += ("result {0}, expected {1}" -f $gotResult, $c.Result) }
        if (-not $okCount) { $why += ("counted {0} assertion(s), expected {1}" -f $gotCount, $c.Count) }
        Write-Host ("  BROKEN  {0,-16} {1}" -f $c.Id, ($why -join '; ')) -ForegroundColor Red
        $failed++
    }
}

Write-Host ''
if ($failed -gt 0) {
    Write-Host ("  {0} of {1} contract checks BROKEN - the harness no longer awards the result a case earned." -f $failed, $contract.Count) -ForegroundColor Red
    Write-Host ''
    exit 1
}
Write-Host ("  {0}/{0} contract checks hold." -f $contract.Count) -ForegroundColor Green
Write-Host ''
exit 0
