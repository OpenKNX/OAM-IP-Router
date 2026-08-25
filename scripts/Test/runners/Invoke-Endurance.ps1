#!/usr/bin/env pwsh
<#
Open ■
┬────┴  Invoke-Endurance
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: scripts/Test/Invoke-Endurance.ps1

.SYNOPSIS
    Runs the full test stack N times and answers the only question repetition can answer:
    is anything INTERMITTENT, and does the device DEGRADE while being tested?

.DESCRIPTION
    A single green run proves that nothing was broken at that moment. It says nothing
    about a case that fails one time in twenty - and that is the class of defect that
    survives development and shows up in the field.

    So this script does three things a single run cannot:

      1. Per-case flakiness. Every case ID is tracked across all iterations and classified
         as STABLE PASS, STABLE FAIL or FLAKY. A flaky case is reported ABOVE the stable
         failures, because it is harder to find and usually more serious.

      2. Degradation. Failures and durations are compared between the first and the second
         half of the run. A device that gets slower or starts failing late is leaking
         something - a single run cannot see that by construction.

      3. An honest confidence statement instead of "everything is fine".

    HOW MANY ITERATIONS - and why it is never 100 %

    With N independent iterations and zero failures, the upper bound on an intermittent
    failure probability p at confidence C is:

        p <= 1 - (1 - C)^(1/N)        equivalently        N = ln(1 - C) / ln(1 - p)

    So N is derived from what you want to be able to RULE OUT, not guessed:

        95 % confident that a rate above 10 % would have shown   ->  N = 29
        95 % confident that a rate above  5 % would have shown   ->  N = 59
        95 % confident that a rate above  1 % would have shown   ->  N = 299
        99 % confident that a rate above  1 % would have shown   ->  N = 459

    There is no N that yields certainty. Pass -MaxFailureRate and -Confidence and the
    script computes N; pass -Iterations to set it directly.

    TWO LIMITS THIS SCRIPT STATES RATHER THAN HIDES

      * The iterations are NOT statistically independent. They run against the same device
        in the same order, so state accumulates. That is exactly what makes the degradation
        analysis work, and it is also why the confidence bound is optimistic. Treat it as
        an upper bound on what was observed, not a guarantee.
      * A bound on the failure rate under the conditions tested says nothing about
        conditions not tested. Bus load, temperature and network noise are not varied here.

.PARAMETER Iterations
    Number of iterations. Overrides the computed value.

.PARAMETER MaxFailureRate
    The intermittent failure rate to be able to rule out, as a fraction (0.10 = 10 %).
    Default 0.10.

.PARAMETER Confidence
    Confidence level for that statement (0.95 = 95 %). Default 0.95.

.PARAMETER Stage
    Which stages each iteration runs. Default Conformance and Features - they produce the
    per-case JSON that the flakiness analysis needs. Adding Legacy makes each iteration
    much longer without adding per-case data.

.PARAMETER StopOnFirstFailure
    Stop as soon as one iteration fails. Off by default: for flakiness the interesting
    part is how OFTEN it fails, which requires continuing.

.PARAMETER PauseSeconds
    Idle time between iterations. A short pause lets connection reapers run and makes the
    iterations a little more independent. Default 5.

.EXAMPLE
    ./Invoke-Endurance.ps1 -Ip 11.11.0.126 -TrafficIp 11.11.0.5 -Quick
.EXAMPLE
    ./Invoke-Endurance.ps1 -Ip 11.11.0.126 -TrafficIp 11.11.0.5 -MaxFailureRate 0.05
.EXAMPLE
    ./Invoke-Endurance.ps1 -Ip 11.11.0.126 -Iterations 100 -Quick
#>

[CmdletBinding()]
param(
    [int]$Iterations = 0,
    [double]$MaxFailureRate = 0.10,
    [double]$Confidence = 0.95,

    [string]$Ip = '',
    [int]$Port = 3671,
    [string]$TrafficIp = '',
    [string]$ReferenceIp = '',
    [string]$BdutPa = '',
    [string]$SerialPort = '',
    [string]$FtcTarget = '5.0.3',
        [string[]]$Stage = @('Conformance', 'Features'),
    [switch]$Quick,
    [ValidateSet('Full', 'ReadOnly', 'Safe')]
    [string]$RunProfile = 'Safe',
    [switch]$IncludeDestructive,
    [switch]$ExpectBusmonitor,
    [switch]$BusmonExclusive,
    [switch]$ExpectRouting,
    [switch]$Security,
    [int]$TunnelCount = 16,
    [string]$LoadSwitchVia = '',
    [string]$LoadSwitchGa = '',
    [string]$LoadSwitchPa = '',
    [string]$P2pTarget = '',
    [string]$Multicast = '224.0.23.12',
    [string]$ReportDir = '',
    [switch]$StopOnFirstFailure,
    [int]$PauseSeconds = 5
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
$iterDir = Join-Path $ReportDir "Endurance_$stamp"
[void](New-Item -ItemType Directory -Path $iterDir -Force)


function Expand-ListArgument {
    <#
    .SYNOPSIS
        Normalises a multi-value argument and validates it against the allowed set.
    .DESCRIPTION
        "pwsh script.ps1 -X a,b" hands the script the single STRING "a,b", so a
        [ValidateSet] on a [string[]] parameter rejects it with a message that blames the
        user for correct-looking input. Splitting here accepts every spelling - "a,b",
        "a b", -X a -X b - and reports an unknown value by name instead.
    #>
    param([string[]]$Value, [string[]]$Allowed, [string]$Name)
    $out = @()
    foreach ($v in $Value) {
        if ($null -eq $v) { continue }
        foreach ($part in ($v -split '[,;\s]+')) {
            if (-not $part) { continue }
            $match = $Allowed | Where-Object { $_ -ieq $part }
            if (-not $match) {
                throw "-$Name : '$part' is not one of: $($Allowed -join ', ')"
            }
            if ($out -notcontains $match) { $out += $match }
        }
    }
    if ($out.Count -eq 0) { throw "-$Name : no value given" }
    return , $out
}

# ─── How many iterations ────────────────────────────────────────────────────────

function Get-RequiredIterations {
    <#
    .SYNOPSIS
        N such that observing zero failures bounds the failure rate at p with confidence C.
    .DESCRIPTION
        N = ln(1 - C) / ln(1 - p), rounded up. This is the standard zero-failure binomial
        bound; for C = 0.95 it is the familiar "rule of three" (N ~ 3/p).
    #>
    param([double]$MaxRate, [double]$Confidence)
    if ($MaxRate -le 0 -or $MaxRate -ge 1) { throw '-MaxFailureRate must be between 0 and 1 (exclusive)' }
    if ($Confidence -le 0 -or $Confidence -ge 1) { throw '-Confidence must be between 0 and 1 (exclusive)' }
    return [int][Math]::Ceiling([Math]::Log(1 - $Confidence) / [Math]::Log(1 - $MaxRate))
}

function Get-AchievedBound {
    <#
    .SYNOPSIS
        The failure rate that N zero-failure iterations actually rule out at confidence C.
    #>
    param([int]$N, [double]$Confidence)
    if ($N -le 0) { return 1.0 }
    return (1 - [Math]::Pow(1 - $Confidence, 1.0 / $N))
}

$stageList = Expand-ListArgument -Value $Stage -Allowed @('SelfTest','Conformance','Features','Hardening','Legacy','All') -Name 'Stage'
$computed = Get-RequiredIterations -MaxRate $MaxFailureRate -Confidence $Confidence
$n = $Iterations
if ($n -le 0) { $n = $computed }

Write-Host ''
Write-Host '  Open ■' -ForegroundColor Green
Write-Host '  ┬────┴  Endurance run' -ForegroundColor Green
Write-Host '  ■ KNX   2026 OpenKNX - Erkan Çolak' -ForegroundColor DarkGray
Write-Host ''
Write-Host "  Iterations     : $n$(if ($Iterations -gt 0) { '  (set explicitly)' } else { '  (computed)' })"
Write-Host ("  Statement      : {0:P0} confidence that an intermittent rate above {1:P0} would have shown" -f $Confidence, (Get-AchievedBound -N $n -Confidence $Confidence))
Write-Host "  Stages / iter  : $($stageList -join ', ')$(if ($Quick) { '  (quick)' } else { '' })"
Write-Host "  BDUT           : $(if ($Ip) { $Ip } else { '<none>' })"
Write-Host "  Pause          : ${PauseSeconds}s between iterations"
Write-Host "  Per-iteration  : $iterDir"
Write-Host ''
if ($Iterations -gt 0 -and $Iterations -lt $computed) {
    Write-Host "  NOTE: $computed iterations would be needed for the requested statement; $Iterations were asked for." -ForegroundColor Yellow
    Write-Host '  The report states what this run actually rules out, not what was intended.' -ForegroundColor Yellow
    Write-Host ''
}

# ─── Run the iterations ─────────────────────────────────────────────────────────

$allTests = Join-Path $here 'Invoke-AllTests.ps1'
if (-not (Test-Path $allTests)) {
    Write-Host "  ABORT: Invoke-AllTests.ps1 not found next to this script." -ForegroundColor Red
    exit 2
}

# caseId -> record of how it went in each iteration
$cases = @{}
# Named iterationLog, not iterations: PowerShell variable names are case-insensitive,
# so $iterations would be the [int]$Iterations parameter.
$iterationLog = New-Object System.Collections.ArrayList

for ($i = 1; $i -le $n; $i++) {
    $iterStart = Get-Date
    Write-Host ('  ' + ('─' * 72)) -ForegroundColor DarkCyan
    Write-Host ("  Iteration {0} / {1}   ({2})" -f $i, $n, $iterStart.ToString('HH:mm:ss')) -ForegroundColor Cyan
    Write-Host ('  ' + ('─' * 72)) -ForegroundColor DarkCyan

    $thisDir = Join-Path $iterDir ("iter-{0:D3}" -f $i)
    [void](New-Item -ItemType Directory -Path $thisDir -Force)

    $a = @('-Stage', ($stageList -join ',')) + @('-ReportDir', $thisDir, '-RunProfile', $RunProfile, '-Multicast', $Multicast, '-TunnelCount', "$TunnelCount")
    if ($Ip) { $a += @('-Ip', $Ip, '-Port', "$Port") }
    if ($TrafficIp) { $a += @('-TrafficIp', $TrafficIp) }
    if ($ReferenceIp) { $a += @('-ReferenceIp', $ReferenceIp) }
    if ($BdutPa) { $a += @('-BdutPa', $BdutPa) }
    if ($SerialPort) { $a += @('-SerialPort', $SerialPort, '-FtcTarget', $FtcTarget) }
    if ($LoadSwitchVia) { $a += @('-LoadSwitchVia', $LoadSwitchVia) }
    if ($LoadSwitchGa) { $a += @('-LoadSwitchGa', $LoadSwitchGa) }
    if ($LoadSwitchPa) { $a += @('-LoadSwitchPa', $LoadSwitchPa) }
    if ($P2pTarget) { $a += @('-P2pTarget', $P2pTarget) }
    if ($Quick) { $a += '-Quick' }
    if ($IncludeDestructive) { $a += '-IncludeDestructive' }
    if ($ExpectBusmonitor) { $a += '-ExpectBusmonitor' }
    if ($BusmonExclusive) { $a += '-BusmonExclusive' }
    if ($ExpectRouting) { $a += '-ExpectRouting' }
    if ($Security) { $a += '-Security' }

    & pwsh -NoProfile -File $allTests @a
    $code = $LASTEXITCODE
    $iterSeconds = ((Get-Date) - $iterStart).TotalSeconds

    # Collect every per-case JSON this iteration produced (conformance, features, ...).
    $iterPass = 0; $iterFail = 0; $iterSkip = 0; $iterNa = 0
    foreach ($f in (Get-ChildItem -Path $thisDir -Filter '*.json' -Recurse -ErrorAction SilentlyContinue)) {
        if ($f.Name -like 'AllTests_*') { continue }
        try { $j = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json } catch { continue }
        if ($null -eq $j.results) { continue }
        foreach ($r in $j.results) {
            $id = "$($r.Id)"
            if (-not $cases.ContainsKey($id)) {
                $cases[$id] = [pscustomobject]@{
                    Id = $id; Title = "$($r.Title)"; Suite = "$($r.Suite)"
                    Pass = 0; Fail = 0; Skip = 0; NA = 0
                    FailedIterations = (New-Object System.Collections.ArrayList)
                    Reasons = (New-Object System.Collections.ArrayList)
                }
            }
            $c = $cases[$id]
            switch (Get-KnxCaseResult -Case $r) {
                'PASS' { $c.Pass++; $iterPass++ }
                'FAIL' {
                    $c.Fail++; $iterFail++
                    [void]$c.FailedIterations.Add($i)
                    if ($c.Reasons -notcontains "$($r.Reason)") { [void]$c.Reasons.Add("$($r.Reason)") }
                }
                'SKIP' { $c.Skip++; $iterSkip++ }
                'N-A' { $c.NA++; $iterNa++ }
            }
        }
    }

    [void]$iterationLog.Add([pscustomobject]@{
            Index = $i; ExitCode = $code; Seconds = [Math]::Round($iterSeconds, 1)
            Pass = $iterPass; Fail = $iterFail; Skip = $iterSkip; NA = $iterNa
        })

    $col = if ($iterFail -eq 0 -and $code -le 3) { 'Green' } else { 'Red' }
    Write-Host ''
    Write-Host ("  Iteration {0}: {1} pass, {2} fail, {3} skip  ({4}s)" -f $i, $iterPass, $iterFail, $iterSkip, [Math]::Round($iterSeconds, 1)) -ForegroundColor $col
    Write-Host ''

    if ($StopOnFirstFailure -and $iterFail -gt 0) {
        Write-Host "  Stopping after iteration $i (-StopOnFirstFailure)." -ForegroundColor Yellow
        break
    }
    if ($i -lt $n -and $PauseSeconds -gt 0) { Start-Sleep -Seconds $PauseSeconds }
}

$done = $iterationLog.Count

# ─── Analysis ───────────────────────────────────────────────────────────────────

$stablePass = @(); $stableFail = @(); $flaky = @(); $neverRan = @()
foreach ($id in ($cases.Keys | Sort-Object)) {
    $c = $cases[$id]
    $ran = $c.Pass + $c.Fail
    if ($ran -eq 0) { $neverRan += $c; continue }
    if ($c.Fail -eq 0) { $stablePass += $c; continue }
    if ($c.Pass -eq 0) { $stableFail += $c; continue }
    $flaky += $c
}

# Degradation: compare the first half of the run against the second.
$half = [int][Math]::Floor($done / 2)
$firstFail = 0; $secondFail = 0; $firstSec = 0.0; $secondSec = 0.0
for ($k = 0; $k -lt $done; $k++) {
    $it = $iterationLog[$k]
    if ($k -lt $half) { $firstFail += $it.Fail; $firstSec += $it.Seconds }
    elseif ($done -gt 1) { $secondFail += $it.Fail; $secondSec += $it.Seconds }
}
$firstAvg = 0.0; $secondAvg = 0.0
if ($half -gt 0) { $firstAvg = $firstSec / $half }
if (($done - $half) -gt 0) { $secondAvg = $secondSec / ($done - $half) }

$totalFail = 0
foreach ($it in $iterationLog) { $totalFail += $it.Fail }
$cleanIterations = @($iterationLog | Where-Object { $_.Fail -eq 0 }).Count

# ─── Result ─────────────────────────────────────────────────────────────────────

$runEnd = Get-Date
$totalMinutes = [Math]::Round(($runEnd - $runStart).TotalMinutes, 1)

Write-Host ''
Write-Host ('  ' + ('═' * 72)) -ForegroundColor DarkCyan
Write-Host '  ENDURANCE RESULT' -ForegroundColor Cyan
Write-Host ('  ' + ('═' * 72)) -ForegroundColor DarkCyan
Write-Host ''
Write-Host "  Iterations completed : $done of $n"
Write-Host "  Clean iterations     : $cleanIterations"
Write-Host "  Total case failures  : $totalFail"
Write-Host "  Wall clock           : $totalMinutes min"
Write-Host ''
Write-Host "  Cases stable PASS    : $($stablePass.Count)" -ForegroundColor Green
Write-Host "  Cases FLAKY          : $($flaky.Count)" -ForegroundColor $(if ($flaky.Count) { 'Red' } else { 'DarkGray' })
Write-Host "  Cases stable FAIL    : $($stableFail.Count)" -ForegroundColor $(if ($stableFail.Count) { 'Red' } else { 'DarkGray' })
Write-Host ''

if ($flaky.Count -gt 0) {
    # Flaky first: a case that fails sometimes is harder to find than one that always does,
    # and it is the reason this run exists at all.
    Write-Host '  FLAKY CASES - these are the finding of this run' -ForegroundColor Red
    Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkGray
    foreach ($c in ($flaky | Sort-Object -Property @{Expression = { $_.Fail }; Descending = $true })) {
        $ran = $c.Pass + $c.Fail
        Write-Host ("  {0}  {1}/{2} failed   {3}" -f $c.Id.PadRight(12), $c.Fail, $ran, $c.Title) -ForegroundColor Red
        Write-Host ("      iterations: {0}" -f ($c.FailedIterations -join ', ')) -ForegroundColor DarkGray
        foreach ($r in $c.Reasons) { Write-Host "      reason: $r" -ForegroundColor DarkGray }
    }
    Write-Host ''
}

if ($stableFail.Count -gt 0) {
    Write-Host '  STABLE FAILURES - reproducible, therefore the easy ones' -ForegroundColor Yellow
    Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkGray
    foreach ($c in $stableFail) {
        Write-Host ("  {0}  {1}" -f $c.Id.PadRight(12), $c.Title) -ForegroundColor Yellow
        foreach ($r in $c.Reasons) { Write-Host "      reason: $r" -ForegroundColor DarkGray }
    }
    Write-Host ''
}

# Degradation
$degraded = $false
if ($done -ge 4) {
    Write-Host '  Degradation over the run' -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkGray
    Write-Host ("  Failures  first half {0}   second half {1}" -f $firstFail, $secondFail)
    Write-Host ("  Duration  first half {0:N1}s   second half {1:N1}s" -f $firstAvg, $secondAvg)
    if ($secondFail -gt $firstFail) {
        $degraded = $true
        Write-Host '  -> Failures INCREASE over the run. Something accumulates: a leaked handle,' -ForegroundColor Red
        Write-Host '     an unreleased connection, memory. A single run cannot see this.' -ForegroundColor Red
    }
    if ($firstAvg -gt 0 -and $secondAvg -gt ($firstAvg * 1.25)) {
        $degraded = $true
        Write-Host ("  -> Iterations get {0:P0} slower. The device is degrading under repetition." -f (($secondAvg / $firstAvg) - 1)) -ForegroundColor Red
    }
    if (-not $degraded) { Write-Host '  -> No trend: neither failures nor duration grow over the run.' -ForegroundColor Green }
    Write-Host ''
}

# The honest headline.
$bound = Get-AchievedBound -N $done -Confidence $Confidence
Write-Host ('  ' + ('═' * 72)) -ForegroundColor DarkCyan
if ($totalFail -eq 0 -and $flaky.Count -eq 0 -and $stableFail.Count -eq 0 -and -not $degraded) {
    Write-Host '  ┌────────────────────────────────────────────────────────────────┐' -ForegroundColor Green
    Write-Host '  │  NO FAILURE IN ANY ITERATION                                   │' -ForegroundColor Green
    Write-Host '  └────────────────────────────────────────────────────────────────┘' -ForegroundColor Green
    Write-Host ''
    Write-Host ("  What this establishes: with {0} clean iterations, an intermittent failure" -f $done)
    Write-Host ("  rate above {0:P1} would have shown up with {1:P0} probability." -f $bound, $Confidence)
    Write-Host ''
    Write-Host '  What it does NOT establish: that the device is correct. A rarer fault, or a' -ForegroundColor Yellow
    Write-Host '  fault under conditions this run did not vary (bus load, temperature, network' -ForegroundColor Yellow
    Write-Host '  noise), remains possible. The iterations also share one device and one order,' -ForegroundColor Yellow
    Write-Host '  so they are not fully independent and the bound is optimistic.' -ForegroundColor Yellow
}
else {
    Write-Host '  ┌────────────────────────────────────────────────────────────────┐' -ForegroundColor Red
    Write-Host '  │  NOT CLEAN                                                     │' -ForegroundColor Red
    Write-Host '  └────────────────────────────────────────────────────────────────┘' -ForegroundColor Red
    Write-Host ''
    if ($flaky.Count -gt 0) { Write-Host "  $($flaky.Count) case(s) failed intermittently - start there." -ForegroundColor Red }
    if ($stableFail.Count -gt 0) { Write-Host "  $($stableFail.Count) case(s) failed every time." -ForegroundColor Yellow }
    if ($degraded) { Write-Host '  The device degrades over repeated runs.' -ForegroundColor Red }
}
Write-Host ('  ' + ('═' * 72)) -ForegroundColor DarkCyan

# ─── Report ─────────────────────────────────────────────────────────────────────

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine('# Endurance run')
[void]$md.AppendLine('')
[void]$md.AppendLine("Started: $($runStart.ToString('yyyy-MM-dd HH:mm:ss'))  ")
[void]$md.AppendLine("Finished: $($runEnd.ToString('yyyy-MM-dd HH:mm:ss'))  ")
[void]$md.AppendLine("Duration: $totalMinutes min  |  iterations: $done of $n")
[void]$md.AppendLine('')
[void]$md.AppendLine('## What this run establishes')
[void]$md.AppendLine('')
if ($totalFail -eq 0) {
    [void]$md.AppendLine(("With **$done** clean iterations, an intermittent failure rate above **{0:P1}** would have been observed with **{1:P0}** probability." -f $bound, $Confidence))
}
else {
    [void]$md.AppendLine("**$totalFail** case failure(s) occurred across $done iterations, so no zero-failure bound applies.")
}
[void]$md.AppendLine('')
[void]$md.AppendLine('Limits, stated deliberately:')
[void]$md.AppendLine('')
[void]$md.AppendLine('* Repetition can never establish certainty; it bounds a rate.')
[void]$md.AppendLine('* The iterations run against the same device in the same order, so they are not')
[void]$md.AppendLine('  statistically independent - the bound is optimistic.')
[void]$md.AppendLine('* Conditions not varied here (bus load, temperature, network noise) are not covered.')
[void]$md.AppendLine('')
[void]$md.AppendLine('## Summary')
[void]$md.AppendLine('')
[void]$md.AppendLine('| Metric | Value |')
[void]$md.AppendLine('|---|---|')
[void]$md.AppendLine("| Iterations completed | $done of $n |")
[void]$md.AppendLine("| Clean iterations | $cleanIterations |")
[void]$md.AppendLine("| Total case failures | $totalFail |")
[void]$md.AppendLine("| Cases stable PASS | $($stablePass.Count) |")
[void]$md.AppendLine("| Cases FLAKY | $($flaky.Count) |")
[void]$md.AppendLine("| Cases stable FAIL | $($stableFail.Count) |")
[void]$md.AppendLine("| Degradation detected | $degraded |")
[void]$md.AppendLine('')

if ($flaky.Count -gt 0) {
    [void]$md.AppendLine('## Flaky cases')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('These failed in some iterations and passed in others. They are the finding of this run.')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| ID | Failed | Ran | Case | Failing iterations | Reasons |')
    [void]$md.AppendLine('|---|---|---|---|---|---|')
    foreach ($c in ($flaky | Sort-Object -Property @{Expression = { $_.Fail }; Descending = $true })) {
        $ran = $c.Pass + $c.Fail
        $reasons = (($c.Reasons | ForEach-Object { $_ -replace '\|', '\|' }) -join '; ')
        [void]$md.AppendLine("| ``$($c.Id)`` | $($c.Fail) | $ran | $($c.Title) | $($c.FailedIterations -join ', ') | $reasons |")
    }
    [void]$md.AppendLine('')
}

if ($stableFail.Count -gt 0) {
    [void]$md.AppendLine('## Stable failures')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| ID | Case | Reasons |')
    [void]$md.AppendLine('|---|---|---|')
    foreach ($c in $stableFail) {
        $reasons = (($c.Reasons | ForEach-Object { $_ -replace '\|', '\|' }) -join '; ')
        [void]$md.AppendLine("| ``$($c.Id)`` | $($c.Title) | $reasons |")
    }
    [void]$md.AppendLine('')
}

[void]$md.AppendLine('## Degradation')
[void]$md.AppendLine('')
[void]$md.AppendLine('| Half | Failures | Average duration |')
[void]$md.AppendLine('|---|---|---|')
[void]$md.AppendLine("| First | $firstFail | $([Math]::Round($firstAvg,1)) s |")
[void]$md.AppendLine("| Second | $secondFail | $([Math]::Round($secondAvg,1)) s |")
[void]$md.AppendLine('')
[void]$md.AppendLine('## Iterations')
[void]$md.AppendLine('')
[void]$md.AppendLine('| # | PASS | FAIL | SKIP | N-A | Seconds | Exit |')
[void]$md.AppendLine('|---|---|---|---|---|---|---|')
foreach ($it in $iterationLog) {
    [void]$md.AppendLine("| $($it.Index) | $($it.Pass) | $($it.Fail) | $($it.Skip) | $($it.NA) | $($it.Seconds) | $($it.ExitCode) |")
}

$mdPath = Join-Path $ReportDir "Endurance_$stamp.md"
$jsonPath = Join-Path $ReportDir "Endurance_$stamp.json"
[System.IO.File]::WriteAllText($mdPath, $md.ToString())
([pscustomobject]@{
        started = $runStart.ToString('o'); finished = $runEnd.ToString('o')
        iterationsRequested = $n; iterationsCompleted = $done
        confidence = $Confidence; ruledOutRate = $bound; requestedRate = $MaxFailureRate
        cleanIterations = $cleanIterations; totalFailures = $totalFail
        degradation = @{ detected = $degraded; firstHalfFailures = $firstFail; secondHalfFailures = $secondFail; firstHalfAvgSeconds = $firstAvg; secondHalfAvgSeconds = $secondAvg }
        stablePass = @($stablePass | ForEach-Object { $_.Id })
        stableFail = @($stableFail | ForEach-Object { [pscustomobject]@{ id = $_.Id; title = $_.Title; reasons = @($_.Reasons) } })
        flaky = @($flaky | ForEach-Object { [pscustomobject]@{ id = $_.Id; title = $_.Title; failed = $_.Fail; ran = ($_.Pass + $_.Fail); iterations = @($_.FailedIterations); reasons = @($_.Reasons) } })
        iterations = @($iterationLog)
    }) | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8

Write-Host ''
Write-Host "  Report: $mdPath" -ForegroundColor Cyan
Write-Host "  Data  : $jsonPath" -ForegroundColor DarkGray
Write-Host "  Per-iteration reports: $iterDir" -ForegroundColor DarkGray
Write-Host ''

if ($flaky.Count -gt 0) { exit 1 }
if ($stableFail.Count -gt 0) { exit 1 }
if ($degraded) { exit 1 }
exit 0
