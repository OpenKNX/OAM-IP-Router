#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Test-Longrun
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Tools/Test-Longrun.ps1

<#
.SYNOPSIS
    Long-run evidence for the desync watchdog and the 0x03 reset fix.

.DESCRIPTION
    The two changes under test cannot be proven by a single pass: one asserts that something
    NEVER happens (the watchdog must not fire in normal operation), the other that a counter
    STAYS PUT (Resets must not grow). Both are statements about hours, not seconds.

    So this samples the device console at a fixed interval and records, per sample:
      - the BCU counters (Resets, Disconnects, CON rescues, Discarded)
      - any occurrence of the watchdog log line
      - liveness over IP, so a silent death is distinguishable from a quiet bus

    Everything is appended to the log as it happens, not buffered to the end - a run that is
    interrupted after four hours must still carry its evidence.

    A result is only printed at the end. Two ways to fail:
      Resets grew            -> the watchdog fires wrongly, 20 s is too tight
      watchdog line appeared -> same, with the direct proof in the log

.PARAMETER Port
    Console of the device under test.
.PARAMETER Ip
    Its IP address, for the liveness probe.
.PARAMETER Hours
    Upper bound on the duration. Default 4. Use a fraction for a smoke run, e.g. 0.1.
.PARAMETER StableSamples
    Stop early once this many consecutive samples are clean. Default 15. The claim under
    test is "nothing happens", and once enough consecutive quiet samples are in, more of
    them add confidence but no new information - so the run ends instead of burning hours
    and log lines. Pass -FullTerm to always run the whole duration.
.PARAMETER FullTerm
    Ignore StableSamples and run the full duration.
.PARAMETER IntervalSec
    Sampling interval. Default 120.
.PARAMETER LogFile
    Output. Default Reports/Longrun_<timestamp>.log

.EXAMPLE
    ./Test-Longrun.ps1 -Port /dev/cu.usbmodem3101 -Ip 11.11.0.126 -Hours 4
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Port,
    [int]$Baud = 115200,
    [Parameter(Mandatory)][string]$Ip,
    [double]$Hours = 4,
    [int]$IntervalSec = 120,
    [int]$StableSamples = 15,
    [switch]$FullTerm,
    [string]$LogFile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $here 'lib/KnxTest.psm1') -Force

if (-not $LogFile) {
    $LogFile = Join-Path $here ("Reports/Longrun_{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

. (Join-Path $PSScriptRoot '../lib/KnxLogo.ps1')
Write-KnxLogo -Title 'Long-run: desync watchdog + 0x03 reset fix'

function Append { param([string]$T) Add-Content -Path $LogFile -Value $T -Encoding UTF8; Write-Host $T }

$p = New-Object System.IO.Ports.SerialPort $Port, $Baud, None, 8, One
$p.DtrEnable = $true; $p.RtsEnable = $true; $p.ReadTimeout = 800
$p.Open(); Start-Sleep -Milliseconds 800; $p.DiscardInBuffer()

function Drain {
    $s = ''
    try { while ($true) { $s += $p.ReadExisting(); Start-Sleep -Milliseconds 200; if ($p.BytesToRead -eq 0) { break } } } catch { }
    return ($s -replace "\x1b\[[0-9;]*[A-Za-z]", '')
}

function Get-Counters {
    <#
    .SYNOPSIS
        One 'bcu stat' sample, reduced to the numbers the result rests on.
    #>
    # 'bcu' (not 'bcu stat') is the one that carries the health counters on every platform:
    # the boxed 'bcu stat' output is truncated on the RP2040 console and stops after Overflow,
    # so the very numbers this test rests on never appear there.
    $p.DiscardInBuffer()
    $p.WriteLine('bcu'); Start-Sleep -Seconds 3
    $raw = Drain
    $o = [ordered]@{ Resets = -1; Disconnects = -1; ConRescues = -1; Discarded = -1; RxFrames = -1; TxFrames = -1; State = '?' }
    foreach ($l in ($raw -split "`n")) {
        if ($l -match 'BCU<Status:\s*(\w+)>')      { $o.State       = $Matches[1] }
        if ($l -match 'Resets\s+(\d+)')           { $o.Resets      = [int]$Matches[1] }
        if ($l -match 'CON-rescues\s+(\d+)')      { $o.ConRescues  = [int]$Matches[1] }
        if ($l -match 'Disconnects\s+(\d+)')      { $o.Disconnects = [int]$Matches[1] }
        if ($l -match 'Discarded\s+(\d+)\s*B')    { $o.Discarded   = [int]$Matches[1] }
        if ($l -match 'RX\s+(\d+)\s*\(')          { $o.RxFrames    = [int]$Matches[1] }
        if ($l -match 'TX\s+(\d+)')             { $o.TxFrames    = [int]$Matches[1] }
    }
    return [pscustomobject]@{ Values = $o; Raw = $raw }
}

$startedAt = Get-Date
Append "# Long-run evidence: desync watchdog + 0x03 reset fix"
Append "# started  : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Append "# console  : $Port"
Append "# device   : $Ip"
Append "# duration : $Hours h, sample every $IntervalSec s"

$p.WriteLine('v'); Start-Sleep -Seconds 3
foreach ($l in ((Drain) -split "`n")) { if ($l -match 'Buildtime') { Append ("# build    : " + ($l -replace '.*Buildtime:\s*', '').Trim()) } }

$first = Get-Counters
if ($first.Values.State -ne 'Connected') {
    Append "# ABORT: device is in state '$($first.Values.State)', not Connected."
    Append "# The desync watchdog is CONNECTED-only by design, so a run in any other state"
    Append "# would report PASS without ever testing what it claims to test."
    Append "# Recover with 'restart' on the console, then start again."
    $p.Close(); exit 3
}
Append ("# baseline : Resets={0} Disconnects={1} ConRescues={2} Discarded={3} State={4}" -f `
        $first.Values.Resets, $first.Values.Disconnects, $first.Values.ConRescues, $first.Values.Discarded, $first.Values.State)
Append ''
Append 'time                 Resets Disc ConR  dConR/dTX Discarded RxFrames TxFrames State      alive  watchdog'
Append ('-' * 112)

$deadline = (Get-Date).AddHours($Hours)
$watchdogHits = @()
$resetLines = @()
$samples = 0
$stableRun = 0
$stoppedEarly = $false
$last = $first.Values

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds $IntervalSec
    $samples++
    $s = Get-Counters
    $v = $s.Values
    $alive = Test-KnxAlive -Ip $Ip -TimeoutMs 3000

    # The watchdog announces itself in the log; any occurrence is evidence and is kept verbatim.
    $hit = ''
    foreach ($l in ($s.Raw -split "`n")) {
        if ($l -match 'desync|Watchdog') {
            $hit = 'WD'; $watchdogHits += ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $l.Trim())
        }
        # A phantom reset announces itself with this exact line. Its absence over hours is
        # what shows the removed 0x03 branch is not firing through some other route - the
        # Resets counter alone would not distinguish a genuine chip reset from a phantom.
        if ($l -match 'Reset received') {
            $hit = if ($hit) { "$hit+RST" } else { 'RST' }
            $resetLines += ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $l.Trim())
        }
    }

    # A rescue count means nothing on its own - it only becomes readable against the number
    # of frames actually transmitted in the same window. One rescue per send is a problem,
    # one per hundred is noise, and the raw counter cannot tell them apart.
    $dTx = if ($last.TxFrames -ge 0) { $v.TxFrames - $last.TxFrames } else { 0 }
    $dCr = if ($last.ConRescues -ge 0) { $v.ConRescues - $last.ConRescues } else { 0 }
    $ratio = if ($dTx -gt 0) { "{0}/{1}" -f $dCr, $dTx } elseif ($dCr -gt 0) { "$dCr/0!" } else { '-' }
    Append ("{0}  {1,6} {2,4} {3,4} {4,10} {5,9} {6,8} {7,8} {8,-10} {9,-6} {10}" -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $v.Resets, $v.Disconnects, $v.ConRescues, `
            $ratio, $v.Discarded, $v.RxFrames, $v.TxFrames, $v.State, $alive, $hit)

    # A jump is worth recording the moment it happens, not only in the summary.
    if ($v.Resets -gt $last.Resets -and $last.Resets -ge 0) {
        Append ("  !! Resets {0} -> {1} at $(Get-Date -Format 'HH:mm:ss')" -f $last.Resets, $v.Resets)
        foreach ($l in ($s.Raw -split "`n")) { if ($l.Trim()) { Append ("     | " + $l.Trim()) } }
    }
    # A sample is clean when nothing that the fix is about has moved.
    if ($hit -eq '' -and $v.Resets -le $first.Values.Resets) { $stableRun++ } else { $stableRun = 0 }
    if (-not $FullTerm -and $stableRun -ge $StableSamples) {
        Append ("  -> $StableSamples consecutive clean samples; further sampling adds no new information")
        $stoppedEarly = $true
        $last = $v
        break
    }
    $last = $v
}

$p.Close()

Append ''
Append '=== RESULT ==='
$elapsed = [Math]::Round(((Get-Date) - $startedAt).TotalMinutes, 1)
Append ("samples          : $samples over $elapsed min" + $(if ($stoppedEarly) { " (stopped early: evidence sufficient)" } else { '' }))
Append ("Resets           : {0} -> {1}" -f $first.Values.Resets, $last.Resets)
Append ("Disconnects      : {0} -> {1}" -f $first.Values.Disconnects, $last.Disconnects)
$totTx = $last.TxFrames - $first.Values.TxFrames
$totCr = $last.ConRescues - $first.Values.ConRescues
Append ("TX frames        : {0} -> {1}  (+{2})" -f $first.Values.TxFrames, $last.TxFrames, $totTx)
Append ("CON rescues      : {0} -> {1}  (+{2})" -f $first.Values.ConRescues, $last.ConRescues, $totCr)
if ($totTx -gt 0) {
    Append ("rescue rate      : {0} of {1} transmissions = {2}%" -f $totCr, $totTx, [Math]::Round(100.0*$totCr/$totTx,1))
} elseif ($totCr -gt 0) {
    Append ("rescue rate      : $totCr rescues WITHOUT a single transmission - that needs explaining")
}
Append ("watchdog entries : {0}" -f $watchdogHits.Count)
foreach ($h in $watchdogHits) { Append ("  $h") }
Append ("'Reset received' : {0}" -f $resetLines.Count)
foreach ($h in $resetLines) { Append ("  $h") }

$fail = @()
if ($last.Resets -gt $first.Values.Resets)   { $fail += "Resets grew ($($first.Values.Resets) -> $($last.Resets)) - the watchdog fires wrongly, 20 s is too tight" }
if ($watchdogHits.Count -gt 0)               { $fail += "the desync watchdog logged $($watchdogHits.Count) time(s) in normal operation - the 20 s threshold is too tight" }
if ($resetLines.Count -gt 0)                 { $fail += "'Reset received' appeared $($resetLines.Count) time(s) without a deliberate reset - the 0x03 path may still be reachable" }

Append ''
if ($fail.Count -eq 0) {
    Append "PASS - no reset growth, no watchdog entry, no unexplained 'Reset received'"
    Append "       over $samples samples / $elapsed min."
    Append 'The two claims under test are negative ones (a counter stays put, a log line never'
    Append 'appears), so this is evidence of absence over the observed window, not a proof for'
    Append 'all time. Re-run longer if a regression is ever suspected.'
} else {
    Append 'FAIL'
    foreach ($f in $fail) { Append "  - $f" }
}
Append "# finished : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

Write-Host ''
Write-Host "  Log: $LogFile" -ForegroundColor Cyan
Write-Host ''
if ($fail.Count -gt 0) { exit 1 }
exit 0
