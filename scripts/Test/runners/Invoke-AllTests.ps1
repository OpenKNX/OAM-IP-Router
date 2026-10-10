#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Invoke-AllTests
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Invoke-AllTests.ps1

<#
.SYNOPSIS
    Runs every test stage in one go and produces ONE combined result.

.DESCRIPTION
    One entry point instead of five. The stages run in the order in which a failure is
    cheapest to understand:

      1. SelfTest     the libraries verify their own frames offline. No device needed.
                      If this is red, nothing after it means anything, and the run stops.
      2. Conformance  the TSSH suites (sections 3-8), 130 cases.
      3. Features     product behaviour no specification prescribes (L2).
      4. Hardening    the FTC / FTM / console adversarial suites, over a serial console.
      5. Legacy       the existing fuzz / tunnel / soak scripts (L3), bounded.

    Each stage writes its own report; this script collects them, merges the machine
    readable results, and prints a single summary with a single exit code.

    What it deliberately does NOT do: hide anything. A stage that could not run is
    reported as SKIPPED with the reason - never quietly omitted. A green summary here
    means "everything that was asked for ran and passed", not "nothing complained".

.PARAMETER Ip
    The device under test. Required unless -SelfTestOnly.

.PARAMETER TrafficIp
    Second KNXnet/IP interface on the same TP line. Without it every "from KNX" and
    bus-interrupt case reports SKIP.

.PARAMETER ReferenceIp
    Certified reference device for the cross-check (e.g. the Siemens interface).

.PARAMETER SerialPort
    Console port of the FTC client device. Without it the Hardening stage is skipped.

.PARAMETER FtcTarget
    Individual address of the FTC target device, e.g. 1.1.7. Never 1.1.3: it carries the relays that power the bench.

.PARAMETER Stage
    Which stages to run: SelfTest, Conformance, Features, Hardening, Legacy, All.
    Default: All.

.PARAMETER Quick
    Smoke run: skips the three timeout-measuring cases and shortens the legacy stage.
    The skipped cases are reported as SKIP with that reason - a quick run never looks
    like a full one.

.PARAMETER RunProfile
    Full | ReadOnly | Safe, passed through to the conformance stage. Default Safe.

.PARAMETER IncludeDestructive
    Allow the reconfiguring, exhausting and flooding cases in every stage.

.PARAMETER IsolatedLine
    Declares the 08_02_02 test set-up for D-30.2: only the single device target and the rig's own interfaces are
    on the line, none of them is a coupler or router, the target holds no addresses besides its own, and its
    neighbour address (device number + 1, or - 1 at 255) belongs to none of the interfaces or their tunnel
    pools. Without it D-30.2 ends as NOT-RUN.

.PARAMETER IncludeHardReset
    Allow H-7.5.9 Hard Reset. Forces factory configuration - see TSSH section 1.5.

.PARAMETER ExpectBusmonitor
    The device is built with OPENKNX_HW_BUSMON (feature stage).

.PARAMETER ExpectRouting
    The device is an IP-Router (feature stage).

.PARAMETER TunnelCount
    Configured number of tunnels (feature stage). Default 16.

.PARAMETER WitnessIp
    Device stage: an interface with a hardware busmonitor that watches the line independently.

.PARAMETER IsolatedNetwork
    Conformance stage: the rig is a network without a productive installation (TSSH 1.2.1).

.PARAMETER ReadableGa
    Conformance stage: a group address with a readable group object of the device under test.

.PARAMETER TestGa
    Device stage: group address(es) that only the device under test acts on (D-21.1).

.PARAMETER Guided
    Device stage: a person is present for the cases that need a hand at the device.

.PARAMETER Multicast
    Routing multicast group. Never the production group - the conformance runner refuses.

.PARAMETER PowerGuard
    on | off (default). On: Assert-KnxRigPower runs through -PowerRelayVia before every rig stage, and
    the device stage gets the relay setup and -ProtectedTargets. Off: no relay telegram, nothing protected.

.PARAMETER PowerRelayWrite
    Relay switch GAs, comma separated; paired by position with -PowerRelayStatus.

.PARAMETER PowerRelayStatus
    Relay status GAs, comma separated.

.PARAMETER PowerRelayVia
    Interface that carries every guard telegram.

.PARAMETER ProtectedTargets
    Individual addresses that power the rig; the device stage sends them no restart or write.

.PARAMETER PowerRelayFeeds
    Device under test IPs whose TP the relays cut, comma separated. The FIRST -PowerRelayWrite GA must cut the
    TP of every device listed; -PowerRelayVia must not be listed. The Device state stage runs its KNX-fault
    cases only for an -Ip in this list.

.PARAMETER ReportDir
    Where all reports land. Default: scripts/Test/Reports.

.PARAMETER SelfTestOnly
    Run stage 1 and stop. No device needed. Use this in a pre-commit check.

.EXAMPLE
    ./Invoke-AllTests.ps1 -SelfTestOnly
.EXAMPLE
    ./Invoke-AllTests.ps1 -Ip 11.11.0.126 -TrafficIp 11.11.0.5 -Quick
.EXAMPLE
    ./Invoke-AllTests.ps1 -Ip 11.11.0.126 -TrafficIp 11.11.0.5 -ReferenceIp 11.11.0.5 `
                          -SerialPort /dev/cu.usbmodem84101 -FtcTarget 1.1.7 `   # Windows: -SerialPort COM5
                          -ExpectBusmonitor -Multicast 224.0.23.13
.EXAMPLE
    ./Invoke-AllTests.ps1 -Ip 11.11.0.3 -RunProfile ReadOnly -Stage Conformance
#>

[CmdletBinding()]
param(
    [string]$Ip = '',
    [int]$Port = 3671,
    [string]$TrafficIp = '',
    [string]$ReferenceIp = '',
    [string]$ReferenceIps = '',   # reference stage: several certified interfaces, comma separated
    [string]$BdutPa = '',
    [string]$SerialPort = '',
    [string]$FtcTarget = '1.1.7',
    [string]$FtcPassword = '',
        [string[]]$Stage = @('All'),
    [switch]$Quick,
    [ValidateSet('Full', 'ReadOnly', 'Safe')]
    [string]$RunProfile = 'Safe',
    [switch]$IncludeDestructive,
    [switch]$IsolatedLine,
    [switch]$IncludeHardReset,
    [switch]$ExpectBusmonitor,
    [switch]$BusmonExclusive,
    [switch]$ExpectRouting,
    [switch]$Security,
    [int]$TunnelCount = 16,
    [string]$LoadSwitchVia = '',
    [string]$LoadSwitchGa = '',
    [string]$LoadSwitchPa = '',
    [string]$P2pTarget = '',
    [string[]]$DeviceTargets = @(),
    [string]$WitnessIp = '',      # device stage: second interface with a hardware busmonitor
    [string]$TestGa = '',         # device stage: group address(es) only the device under test acts on
    [switch]$IsolatedNetwork,     # conformance stage: the rig is its own network segment
    [string]$ReadableGa = '',     # conformance stage: group address with a readable group object
    [switch]$Guided,              # device stage: cases that need a hand at the device may ask
    [string]$Multicast = '224.0.23.12',
    [string]$ReportDir = '',
    # Ignored: the combined report goes into -ReportDir with the stage reports. Kept so an older caller
    # that still passes it does not fail on an unknown parameter.
    [string]$MainReportDir = '',
    [string]$RunId = '',
    [string]$SpeedTarget = '',    # speed stage: TP device that receives the throughput transfer
    [int]$SpeedKb = 50,           # speed stage: payload size per mode
    [int]$FidelitySeconds = 40,   # fidelity stage: how long both monitors watch the same line
    [string]$EtsPairs = '',       # readback stage: a recorded ETS download to replay
    [ValidateSet('on', 'off')]
    [string]$PowerGuard = 'off',  # rig power guard, see the help
    [string]$PowerRelayWrite = '',
    [string]$PowerRelayStatus = '',
    [string]$PowerRelayVia = '',
    [string]$ProtectedTargets = '',
    [string]$PowerRelayFeeds = '',
    [switch]$SelfTestOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)  # scripts/Test root
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$parentDir = Split-Path -Parent $repoRoot

# Setting UTF-8 output is harmless on every platform, so it needs no $IsWindows guard - and
# that guard was itself the portability bug: 5.1 does not define the variable, and under
# Set-StrictMode reading it throws before the first test ever runs.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
if (-not $ReportDir) { $ReportDir = Join-Path $here 'Reports' }
if (-not (Test-Path $ReportDir)) { [void](New-Item -ItemType Directory -Path $ReportDir -Force) }

$runStart = Get-Date
$stamp = $runStart.ToString('yyyyMMdd-HHmmss')

# ─── Presentation ───────────────────────────────────────────────────────────────


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

function Show-Logo {
    . (Join-Path $PSScriptRoot '../lib/KnxLogo.ps1')
    Write-KnxLogo -Title 'Full test run'
}

function Write-Stage {
    param([string]$Number, [string]$Text)
    Write-Host ''
    Write-Host ('  ' + ('═' * 72)) -ForegroundColor DarkCyan
    Write-Host "  STAGE $Number  $Text" -ForegroundColor Cyan
    Write-Host ('  ' + ('═' * 72)) -ForegroundColor DarkCyan
}

# ─── Stage bookkeeping ──────────────────────────────────────────────────────────

$stages = New-Object System.Collections.ArrayList

function Add-StageResult {
    <#
    .SYNOPSIS
        Records one stage outcome. Status is PASS, FAIL, SKIPPED or ERROR.
    #>
    param(
        [string]$Name, [string]$Status, [string]$Reason = '',
        [int]$ExitCode = 0, $Counts = $null, [string]$Report = '', [double]$Seconds = 0,
        [switch]$ExpectsReport
    )
    # ExpectsReport marks a stage that writes a JSON report. Only for those does a missing Counts
    # mean the results were lost; a stage like Speed judges itself and never writes one.
    [void]$stages.Add([pscustomobject]@{
            Name          = $Name
            Status        = $Status
            Reason        = $Reason
            ExitCode      = $ExitCode
            Counts        = $Counts
            Report        = $Report
            Seconds       = [Math]::Round($Seconds, 1)
            ExpectsReport = [bool]$ExpectsReport
        })
    $col = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'SKIPPED' { 'Yellow' } default { 'Red' } }
    Write-Host ''
    Write-Host ("  -> {0}: {1}" -f $Name, $Status) -ForegroundColor $col -NoNewline
    if ($Reason) { Write-Host ("  ({0})" -f $Reason) -ForegroundColor $col } else { Write-Host '' }
}

function Get-NewestReport {
    <#
    .SYNOPSIS
        Finds the JSON report a stage just produced, by modification time.
    .DESCRIPTION
        Each sub-runner names its own file; rather than duplicating that naming here, the
        newest JSON written after the stage started is taken. Returns $null when the stage
        produced none - which is itself information, not something to paper over.
    #>
    param([string]$Directory, [datetime]$After, [string]$Pattern = '*.json')
    if (-not (Test-Path $Directory)) { return $null }
    $f = Get-ChildItem -Path $Directory -Filter $Pattern -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $After } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $f) { return $null }
    return $f.FullName
}

function Read-ReportCounts {
    <#
    .SYNOPSIS
        Reads the summary block out of a stage's JSON report.
    #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    try {
        $j = Get-Content -Path $Path -Raw | ConvertFrom-Json
        # NotRun is read defensively: an older or foreign report has no such field, and under
        # Set-StrictMode reading it would throw into the catch below and discard ALL counts.
        $nr = 0
        if ($null -ne $j.summary.PSObject.Properties['NotRun']) { $nr = [int]$j.summary.NotRun }
        # A suite a safety gate refused leaves NO cases behind, so it shows up in no count column. It is
        # recorded separately by Add-KnxRunDropped; without reading it here a run whose section 6 never
        # started still summed to "everything ran, and everything passed".
        $dr = 0
        if ($null -ne $j.PSObject.Properties['Dropped'] -and $null -ne $j.Dropped) { $dr = @($j.Dropped).Count }
        # Any further numeric field of the summary is a result class this runner does not know by
        # name - the test library adds one when a case ends without asserting anything. It is read
        # under whatever name the report carries: a class left out of the sum would show up as a
        # phantom gap on every run. Total, Judged and Dropped are not result classes.
        $notAClass = @('Total', 'Pass', 'Fail', 'Skip', 'NotRun', 'NA', 'Judged', 'Dropped')
        $other = [ordered]@{}
        foreach ($p in $j.summary.PSObject.Properties) {
            if ($notAClass -contains $p.Name) { continue }
            $v = 0
            if ([int]::TryParse("$($p.Value)", [ref]$v) -and $v -ne 0) { $other[$p.Name] = $v }
        }
        return [pscustomobject]@{
            Total  = [int]$j.summary.Total
            Pass   = [int]$j.summary.Pass
            Fail   = [int]$j.summary.Fail
            Skip   = [int]$j.summary.Skip
            NotRun = $nr
            NA     = [int]$j.summary.NA
            Dropped = $dr
            Other  = $other
        }
    }
    catch { return $null }
}

function Invoke-Stage {
    <#
    .SYNOPSIS
        Runs one sub-script, captures its exit code and its report.
    .DESCRIPTION
        The sub-script's own output is shown live - a full run is long, and a silent
        script that only prints at the end is impossible to supervise.
    #>
    param(
        [string]$Name, [string]$Script, [string[]]$Arguments,
        [string]$ReportDirectory, [string]$ReportPattern = '*.json',
        # Set for a stage whose script calls no Export-KnxTestReport: DPT, Host stack, Rename and ETS
        # readback judge themselves and leave no JSON behind. Without it the missing-report self-check
        # declares a healthy run invalid, because being started through this function is not evidence
        # that a report was ever meant to exist.
        [switch]$NoReport
    )
    $t0 = Get-Date
    if (-not (Test-Path $Script)) {
        Add-StageResult -Name $Name -Status 'SKIPPED' -Reason "script not found: $Script"
        return
    }
    & pwsh -NoProfile -File $Script @Arguments
    $code = $LASTEXITCODE
    $elapsed = ((Get-Date) - $t0).TotalSeconds

    $report = Get-NewestReport -Directory $ReportDirectory -After $t0 -Pattern $ReportPattern
    $counts = Read-ReportCounts -Path $report

    # Every runner in this suite uses the same exit codes, so they can be told apart here:
    #   0  everything passed
    #   1  tests failed - that is a statement about the DEVICE
    #   2  the library self-test failed - nothing that follows can be trusted
    #   3  the rig is not ready - a missing console, no free tunnel, a wrong address
    # Treating 3 as FAIL put a red line against the device because a cable was not plugged
    # in. A missing rig element is a SKIP with its reason, exactly as it is inside a suite.
    $status = 'PASS'
    $reason = ''
    if ($code -eq 3) {
        $status = 'SKIPPED'
        $reason = 'the stage did not judge - it reported exit 3 with its reason above (a missing rig element, or a check that needs a physical fault)'
    }
    elseif ($code -eq 2) {
        $status = 'FAIL'
        $reason = 'the library self-test failed - results would not be trustworthy'
    }
    elseif ($code -ne 0) {
        $status = 'FAIL'
        if ($null -ne $counts) { $reason = "$($counts.Fail) case(s) failed" } else { $reason = "exit code $code" }
    }
    Add-StageResult -Name $Name -Status $status -Reason $reason -ExitCode $code -Counts $counts -Report $report -Seconds $elapsed -ExpectsReport:(-not $NoReport)
}

$rigEvents = New-Object System.Collections.ArrayList

function Invoke-RigPowerGuard {
    <#
    .SYNOPSIS
        Runs Assert-KnxRigPower before a stage; a restore or an unconfirmed relay is recorded as a rig event.
    #>
    param([string]$Before)
    if ($PowerGuard -ne 'on') { return }
    Import-Module (Join-Path $here 'lib/KnxTest.psm1') -Force
    Import-Module (Join-Path $here 'lib/KnxDevice.psm1') -Force -DisableNameChecking
    $g = Assert-KnxRigPower -Via $PowerRelayVia -Port $Port -WriteGa $PowerRelayWrite -StatusGa $PowerRelayStatus -DutPa $BdutPa
    if (-not $g.Restored -and $g.Ok) { Write-Host "  Rig power  : $($g.Detail)" -ForegroundColor DarkGray; return }
    $kind = if ($g.Restored) { 'restored' } else { 'not confirmed' }
    [void]$rigEvents.Add([pscustomobject]@{
            Before  = $Before
            Time    = (Get-Date).ToString('HH:mm:ss')
            Event   = $kind
            Ok      = $g.Ok
            Seconds = $g.Seconds
            Detail  = $g.Detail
        })
    $col = if ($g.Restored -and $g.Ok) { 'Yellow' } else { 'Red' }
    Write-Host ''
    Write-Host "  RIG EVENT before ${Before}: rig power $kind - $($g.Detail)" -ForegroundColor $col
}

function Get-ResultLabel {
    <#
    .SYNOPSIS
        Turns a summary field name into the column label, e.g. NoProof -> NO-PROOF.
    #>
    param([string]$Name)
    return (($Name -creplace '([a-z0-9])([A-Z])', '$1-$2').ToUpper())
}

function Write-ResultBox {
    <#
    .SYNOPSIS
        Prints the headline box around one line of text.
    #>
    param([string]$Text, [string]$Color)
    $w = 50
    $t = $Text
    if ($t.Length -gt ($w - 2)) { $t = $t.Substring(0, $w - 2) }
    $pad = [int](($w - $t.Length) / 2)
    $line = ((' ' * $pad) + $t).PadRight($w)
    $bar = ([string][char]0x2500) * $w
    Write-Host ('  ' + [char]0x250C + $bar + [char]0x2510) -ForegroundColor $Color
    Write-Host ('  ' + [char]0x2502 + $line + [char]0x2502) -ForegroundColor $Color
    Write-Host ('  ' + [char]0x2514 + $bar + [char]0x2518) -ForegroundColor $Color
}

# ─── Start ──────────────────────────────────────────────────────────────────────

Show-Logo

$allStages = @('SelfTest', 'Dpt', 'HostStack', 'Conformance', 'Features', 'Rename', 'Busmonitor',
               'Fidelity', 'DeviceState', 'Devices', 'Hardening', 'Legacy', 'Reference', 'EtsReadback', 'Speed')
$want = Expand-ListArgument -Value $Stage -Allowed ($allStages + 'All') -Name 'Stage'
if ($want -contains 'All') { $want = $allStages }
if ($SelfTestOnly) { $want = @('SelfTest') }

Write-Host "  Stages     : $($want -join ', ')"
Write-Host "  BDUT       : $(if ($Ip) { $Ip } else { 'none' })"
Write-Host "  Traffic    : $(if ($TrafficIp) { $TrafficIp } else { 'none' })"
Write-Host "  Reference  : $(if ($ReferenceIp) { $ReferenceIp } else { 'none' })"
Write-Host "  Console    : $(if ($SerialPort) { $SerialPort } else { 'none' })"
Write-Host "  Profile    : $RunProfile$(if ($Quick) { '  (quick)' } else { '' })"
if ($IncludeDestructive) { Write-Host '  Destructive: ENABLED' -ForegroundColor Yellow }
if ($IncludeHardReset) { Write-Host '  Hard reset : ENABLED - forces factory configuration' -ForegroundColor Red }
$powerLine = 'off'
if ($PowerGuard -eq 'on') {
    $powerLine = "on - relays $PowerRelayWrite (status $PowerRelayStatus) via $PowerRelayVia"
    if ($ProtectedTargets) { $powerLine += ", protected $ProtectedTargets" }
    if ($PowerRelayFeeds) { $powerLine += ", feeds $PowerRelayFeeds" }
}
Write-Host "  Power guard: $powerLine"
Write-Host "  Reports    : $ReportDir"

$ftmDir = Join-Path (Join-Path $parentDir 'OFM-FileTransferModule') 'scripts/Hardening'
# The hardening suite lives in OFM-FileTransferModule and writes into its own Reports folder when
# it is started there. Run as a stage of THIS suite it belongs with the run it is part of: one
# report directory per run, so the path printed when a run starts names the place all of them are.
$ftmReportDir = $ReportDir

# ─── Stage 1: self-tests ────────────────────────────────────────────────────────

if ($want -contains 'SelfTest') {
    Write-Stage '1' 'Self-test - the libraries verify their own frames offline'

    $t0 = Get-Date
    & pwsh -NoProfile -File (Join-Path $here 'runners/Invoke-Conformance.ps1') -SelfTest
    $knxCode = $LASTEXITCODE

    $ftmRunner = Join-Path $ftmDir 'Invoke-FtmHardening.ps1'
    $ftmCode = 0
    if (Test-Path $ftmRunner) {
        & pwsh -NoProfile -File $ftmRunner -SelfTest
        $ftmCode = $LASTEXITCODE
    }
    else {
        Write-Host "  FTC hardening library not found at $ftmRunner - its self-test is skipped." -ForegroundColor Yellow
    }

    # The result contract belongs in this stage, not beside it: Invoke-KnxSelfTest compares byte
    # vectors and raises no test case at all, so it cannot notice that Invoke-KnxTestCase has stopped
    # awarding the result a case earned. A case that silently turns PASS is the same class of damage
    # as a library that builds wrong frames, and it stops the run for the same reason.
    $contract = Join-Path $here 'Tools/Test-ResultContract.ps1'
    $contractCode = 0
    if (Test-Path $contract) {
        & pwsh -NoProfile -File $contract -Quiet
        $contractCode = $LASTEXITCODE
    }
    else {
        Write-Host "  Result contract check not found at $contract - skipped." -ForegroundColor Yellow
    }

    $elapsed = ((Get-Date) - $t0).TotalSeconds
    if ($knxCode -eq 0 -and $ftmCode -eq 0 -and $contractCode -eq 0) {
        Add-StageResult -Name 'Self-test' -Status 'PASS' -Seconds $elapsed
    }
    else {
        $why = if ($contractCode -ne 0 -and $knxCode -eq 0 -and $ftmCode -eq 0) { 'the harness no longer awards the result a case earned' } else { 'a test library builds wrong frames' }
        Add-StageResult -Name 'Self-test' -Status 'FAIL' -Reason $why -ExitCode 1 -Seconds $elapsed
        Write-Host ''
        Write-Host '  Stopping: every later stage would judge with a broken library.' -ForegroundColor Red
        Write-Host '  A wrong PASS is worse than no test at all.' -ForegroundColor Red
        Write-Host ''
        exit 2
    }
}

if ($SelfTestOnly) {
    Write-Host ''
    Write-Host '  Self-test only - done.' -ForegroundColor Green
    Write-Host ''
    exit 0
}

# ─── Stage 1b: host-only checks ─────────────────────────────────────────────────
# These need no device and no bus, and they run before the hardware stages on purpose: a broken
# datapoint converter or a stack that trips a sanitizer makes every device result below suspect.

if ($want -contains 'Dpt') {
    Write-Stage '1b' 'Datapoint types - the converter of lib/knx against a vector table'
    Invoke-Stage -Name 'DPT' -Script (Join-Path $here 'runners/Invoke-DptVectors.ps1') -Arguments @() -ReportDirectory $ReportDir -NoReport
}

if ($want -contains 'HostStack') {
    Write-Stage '1c' 'Host stack - knx + TPUart on this machine under a sanitizer'
    Invoke-Stage -Name 'Host stack' -Script (Join-Path $here 'runners/Invoke-HostStackTests.ps1') -Arguments @() -ReportDirectory $ReportDir -NoReport
}

# ─── Stage 2: conformance ───────────────────────────────────────────────────────

if ($want -contains 'Conformance') {
    Write-Stage '2' 'Conformance - KNXnet/IP (TSSH sections 3-8)'
    Invoke-RigPowerGuard -Before 'Conformance'
    if (-not $Ip) {
        Add-StageResult -Name 'Conformance' -Status 'SKIPPED' -Reason 'no -Ip given'
    }
    else {
        $a = @('-Ip', $Ip, '-Port', "$Port", '-Suite', 'All', '-RunProfile', $RunProfile, '-ReportDir', $ReportDir, '-Multicast', $Multicast)
        # The role, so the suite judges a router as a router. The rig values below were already
        # forwarded - adding them again made PowerShell refuse the call outright.
        if ($ExpectRouting) { $a += @('-Product', 'Router') }
        if ($TrafficIp) { $a += @('-TrafficIp', $TrafficIp) }
        # One address only: Invoke-Conformance parses this into an endpoint, and a comma-separated
        # list aborted the entire stage with "An invalid IP address was specified".
        # The @() must wrap the WHOLE pipeline. Where-Object hands back a bare string when one item
        # survives, and [0] on a string is its first CHARACTER: "11.11.0.2" arrived as "1", which
        # parses as 0.0.0.1, and the stage then died on "No route to host".
        if ($ReferenceIp) {
            $refOne = @($ReferenceIp -split '[,;\s]+' | Where-Object { $_ })
            if ($refOne.Count -gt 0) { $a += @('-ReferenceIp', $refOne[0]) }
        }
        if ($BdutPa) { $a += @('-BdutPa', $BdutPa) }
        if ($LoadSwitchVia) { $a += @('-LoadSwitchVia', $LoadSwitchVia) }
        if ($LoadSwitchGa) { $a += @('-LoadSwitchGa', $LoadSwitchGa) }
        if ($LoadSwitchPa) { $a += @('-LoadSwitchPa', $LoadSwitchPa) }
        if ($P2pTarget) { $a += @('-P2pTarget', $P2pTarget) }
        if ($WitnessIp) { $a += @('-WitnessIp', $WitnessIp) }
        if ($IsolatedNetwork) { $a += '-IsolatedNetwork' }
        if ($ReadableGa) { $a += @('-ReadableGa', $ReadableGa) }
        if ($IncludeDestructive) { $a += @('-IncludeDestructive', '-PrepareRouting') }
        if ($IncludeHardReset) { $a += '-IncludeHardReset' }
        if ($Quick) { $a += '-SkipSlow' }
        Invoke-Stage -Name 'Conformance' -Script (Join-Path $here 'runners/Invoke-Conformance.ps1') -Arguments $a -ReportDirectory $ReportDir
    }
}

# ─── Stage 3: features ──────────────────────────────────────────────────────────

if ($want -contains 'Features') {
    Write-Stage '3' 'Features - product behaviour no specification prescribes'
    Invoke-RigPowerGuard -Before 'Features'
    if (-not $Ip) {
        Add-StageResult -Name 'Features' -Status 'SKIPPED' -Reason 'no -Ip given'
    }
    else {
        $a = @('-Ip', $Ip, '-Port', "$Port", '-TunnelCount', "$TunnelCount", '-ReportDir', $ReportDir)
        if ($TrafficIp) { $a += @('-TrafficIp', $TrafficIp) }
        if ($ExpectBusmonitor) { $a += '-ExpectBusmonitor' }
    if ($BusmonExclusive) { $a += '-BusmonExclusive' }
        if ($ExpectRouting) { $a += '-ExpectRouting' }
        Invoke-Stage -Name 'Features' -Script (Join-Path $here 'Features/Test-Features.ps1') -Arguments $a -ReportDirectory $ReportDir
    }
}

# ─── Stage 4: FTC / FTM hardening ───────────────────────────────────────────────

function Wait-KnxInterfaceFree {
    <#
    .SYNOPSIS
        Waits until an interface can serve a tunnel again, and reports what it found.
    .DESCRIPTION
        Each stage is a separate process, so the connection the previous stage held is only
        released by the interface's own reaper - and a small interface with a single tunnel
        channel then refuses the next stage for up to two minutes. That produced ten red
        busmonitor cases against a device that was working perfectly; the cause was the
        traffic source, not the device under test. Waiting costs seconds and removes a whole
        class of false failures.
    #>
    param([Parameter(Mandatory)][string]$TargetIp, [int]$Port = 3671, [int]$TimeoutSeconds = 150)
    Import-Module (Join-Path $here 'lib/KnxTest.psm1') -Force
    $K = Get-KnxConstants
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $announced = $false
    while ($true) {
        $c = $null
        try {
            $c = Open-KnxConnection -Ip $TargetIp -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION `
                                    -Layer $K.Layer.TUNNEL_LINKLAYER -TimeoutMs 2000
        }
        catch { }
        if ($null -ne $c -and $c.Ok) {
            [void](Close-KnxConnection -Connection $c)
            if ($announced) { Write-Host '  Traffic interface is free again.' -ForegroundColor DarkGray }
            return $true
        }
        if ([DateTime]::UtcNow -ge $deadline) { return $false }
        if (-not $announced) {
            Write-Host "  Waiting for $TargetIp to release a tunnel channel (up to $TimeoutSeconds s)..." -ForegroundColor Yellow
            $announced = $true
        }
        Start-Sleep -Seconds 5
    }
}

function Test-KnxBusmonitorOffered {
    <#
    .SYNOPSIS
        Asks the device whether it accepts a busmonitor tunnel. Returns the connect result.
    .DESCRIPTION
        Whether a hardware busmonitor exists is a property of the DEVICE, so it is probed - never
        derived from -ExpectBusmonitor. A missing switch is a missing argument, not evidence about
        the build; Test-Features.ps1 settled that for X-BM-1 after the switch failed a device whose
        busmonitor works. Deriving it here instead reported 14 failures on a router that refused the
        busmonitor layer, and a gate on the switch would have hidden a dead busmonitor.
    #>
    param([Parameter(Mandatory)][string]$TargetIp, [int]$Port = 3671)
    Import-Module (Join-Path $here 'lib/KnxTest.psm1') -Force
    $K = Get-KnxConstants
    $c = $null
    try {
        $c = Open-KnxConnection -Ip $TargetIp -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION `
                                -Layer $K.Layer.TUNNEL_BUSMONITOR -TimeoutMs 3000
    }
    catch { }
    if ($null -eq $c) { return [pscustomobject]@{ Ok = $false; Status = -1; StatusName = 'NO_ANSWER'; NoHardware = $false } }
    if ($c.Ok) { [void](Close-KnxConnection -Connection $c) }
    # Only a layer refusal (E_CONNECTION_OPTION or E_TUNNELLING_LAYER) says the build has no busmonitor; E_NO_MORE_CONNECTIONS
    # covers an occupied slot AND a chip that cannot enter monitor mode, and no answer says nothing about the build.
    $noHardware = ((-not $c.Ok) -and (@($K.Error.E_CONNECTION_OPTION, $K.Error.E_TUNNELING_LAYER) -contains $c.Status))
    return [pscustomobject]@{ Ok = $c.Ok; Status = $c.Status; StatusName = $c.StatusName; NoHardware = $noHardware }
}

if ($want -contains 'Busmonitor') {
    Write-Stage '4' 'Busmonitor - does it deliver the bus unchanged'
    Invoke-RigPowerGuard -Before 'Busmonitor'
    if (-not $Ip) { Add-StageResult -Name 'Busmonitor' -Status 'SKIPPED' -Reason 'no -Ip given' }
    elseif (-not $TrafficIp) { Add-StageResult -Name 'Busmonitor' -Status 'SKIPPED' -Reason 'no -TrafficIp given - the busmonitor cases need real bus traffic' }
    # A busmonitor is exclusive per subnetwork, so a channel the previous stage still holds would answer
    # the probe E_NO_MORE_CONNECTIONS and look like a broken chip. Wait for the device BEFORE asking it.
    elseif (-not (Wait-KnxInterfaceFree -TargetIp $Ip -Port $Port)) {
        Add-StageResult -Name 'Busmonitor' -Status 'SKIPPED' -Reason "$Ip never released a tunnel channel - every case would fail on that, not on the capture"
    }
    else {
        # The probe itself takes a busmonitor channel and, on success, evicts open data tunnels on the
        # device (closeTunnelsForBusmon) - harmless between stages, but it is not a passive question.
        $bmOffer = Test-KnxBusmonitorOffered -TargetIp $Ip -Port $Port
        if ($bmOffer.NoHardware) {
            Add-StageResult -Name 'Busmonitor' -Status 'SKIPPED' -Reason "the device refused the busmonitor layer ($($bmOffer.StatusName)) - it is built without a hardware busmonitor, so the capture cases have nothing to judge. A device that has one and refuses is judged by X-BM-1 in the feature stage"
        }
        elseif (-not (Wait-KnxInterfaceFree -TargetIp $TrafficIp -Port $Port)) {
            Add-StageResult -Name 'Busmonitor' -Status 'SKIPPED' -Reason "$TrafficIp never released a tunnel channel - every case would fail on the traffic source, not on the device"
        }
        else {
            # Every other outcome - accepted, slot occupied, chip refused, no answer - runs the suite and
            # is reported by it. Skipping those would turn a dead busmonitor into a silent pass.
            $a = @('-Ip', $Ip, '-Port', "$Port", '-TrafficIp', $TrafficIp, '-ReportDir', $ReportDir)
            if ($ExpectRouting) { $a += '-ExpectRouting' }
            Invoke-Stage -Name 'Busmonitor' -Script (Join-Path $here 'Features/Test-Busmonitor.ps1') -Arguments $a -ReportDirectory $ReportDir
        }
    }
}

if ($want -contains 'Devices') {
    Write-Stage '5' 'Devices - KNX devices on the TP line against Volume 3'
    Invoke-RigPowerGuard -Before 'Devices'
    $devList = @()
    foreach ($t in $DeviceTargets) {
        if ($null -eq $t) { continue }
        foreach ($part in ($t -split '[,;\s]+')) { if ($part.Trim()) { $devList += $part.Trim() } }
    }
    if (-not $Ip) { Add-StageResult -Name 'Devices' -Status 'SKIPPED' -Reason 'no -Ip given' }
    elseif ($devList.Count -eq 0) {
        # Not an error: most runs judge the interface, not what hangs off it. Say what is
        # missing so nobody reads an absent stage as a clean one.
        Add-StageResult -Name 'Devices' -Status 'SKIPPED' -Reason 'no -DeviceTargets given - pass the individual addresses to test, e.g. -DeviceTargets 1.1.7,1.1.9'
    }
    else {
        $a = @('-Ip', $Ip, '-Port', $Port, '-Targets', ($devList -join ','), '-ReportDir', $ReportDir)
        if ($Quick) { $a += '-SkipSlow' }
        if ($RunProfile -eq 'ReadOnly') { $a += '-ReadOnly' }
        if ($IncludeDestructive) { $a += '-IncludeDestructive' }
        if ($Guided) { $a += '-Guided' }
        if ($IsolatedLine) { $a += '-IsolatedLine' }
        if ($WitnessIp) { $a += @('-WitnessIp', $WitnessIp) }
        if ($TestGa) { $a += @('-TestGa', $TestGa) }
        if ($TrafficIp) { $a += @('-TrafficIp', $TrafficIp) }
        if ($PowerGuard -eq 'on') {
            $a += @('-PowerGuard', 'on', '-PowerRelayWrite', $PowerRelayWrite, '-PowerRelayStatus', $PowerRelayStatus, '-PowerRelayVia', $PowerRelayVia)
            if ($ProtectedTargets) { $a += @('-ProtectedTargets', $ProtectedTargets) }
        }
        Invoke-Stage -Name 'Devices' -Script (Join-Path $here 'runners/Invoke-DeviceTests.ps1') -Arguments $a -ReportDirectory $ReportDir
    }
}

if ($want -contains 'Hardening') {
    Write-Stage '4' 'Hardening - FTC / FTM / console (adversarial)'
    Invoke-RigPowerGuard -Before 'Hardening'
    $ftmRunner = Join-Path $ftmDir 'Invoke-FtmHardening.ps1'
    if (-not (Test-Path $ftmRunner)) {
        Add-StageResult -Name 'Hardening' -Status 'SKIPPED' -Reason "OFM-FileTransferModule not found next to this repo"
    }
    elseif (-not $SerialPort) {
        Add-StageResult -Name 'Hardening' -Status 'SKIPPED' -Reason 'no -SerialPort given (the FTC client is driven over its console)'
    }
    else {
        $a = @('-Port', $SerialPort, '-Target', $FtcTarget, '-Suite', 'All', '-ReportDir', $ftmReportDir)
        # A target built with OPENKNX_FTC_SECURITY refuses writes with 0xA0 until a session
        # is opened; without the password those cases report SKIP with that reason.
        if ($FtcPassword) { $a += @('-TargetPassword', $FtcPassword) }
        # The hardening runner opens the console with DTR OFF by default, because asserting
        # it resets a board behind a CH340 or CP210x bridge. On a board with NATIVE USB -
        # every RP2040, RP2350 and ESP32-S3 here - DTR is instead how the host announces that
        # a terminal is attached, and the firmware stays silent without it. The check then
        # reports "the console does not answer" about a console that answers perfectly to
        # pio device monitor, which asserts DTR like every other terminal.
        try {
            Import-Module (Join-Path $here 'lib/KnxSerial.psm1') -Force -ErrorAction Stop
            if (Test-KnxSerialNeedsDtr -Port $SerialPort) {
                $a += '-Dtr'
                Write-Host "  $SerialPort is a native-USB port - asserting DTR so the firmware talks." -ForegroundColor DarkGray
            }
            else {
                Write-Host "  $SerialPort is behind a USB-serial bridge - leaving DTR alone so the device is not reset." -ForegroundColor DarkGray
            }
        }
        catch { }
        if ($Security) { $a += '-Security' }
        if ($IncludeDestructive) { $a += '-IncludeDestructive' }
        Invoke-Stage -Name 'Hardening' -Script $ftmRunner -Arguments $a -ReportDirectory $ftmReportDir
    }
}

# ─── Stage 5: legacy hardening scripts ──────────────────────────────────────────

if ($want -contains 'Legacy') {
    Write-Stage '5' 'Legacy hardening - fuzz, tunnels, soak'
    Invoke-RigPowerGuard -Before 'Legacy'
    if (-not $Ip) {
        Add-StageResult -Name 'Legacy' -Status 'SKIPPED' -Reason 'no -Ip given'
    }
    elseif ($RunProfile -eq 'ReadOnly') {
        Add-StageResult -Name 'Legacy' -Status 'SKIPPED' -Reason 'profile ReadOnly - these scripts write to the bus and stress the device'
    }
    else {
        # These scripts predate the result engine: they have no JSON report, so only
        # their exit code and live output are available. That is stated rather than
        # dressed up as a case count.
        $t0 = Get-Date
        $legacyFails = @()

        foreach ($item in @(
                # WantsTraffic marks the scripts that actually declare -TrafficIp. Appending it
                # blindly aborted Test-Tunnels with "a parameter cannot be found" - a stage
                # failure that looked like a device problem and was a wiring mistake here.
                @{ Name = 'Test-Tunnels'; File = 'legacy/Test-Tunnels.ps1'; Args = @('-Ip', $Ip, '-Ramp'); WantsTraffic = $false },
                @{ Name = 'Test-Fuzz'; File = 'legacy/Test-Fuzz.ps1'; Args = @('-Ip', $Ip); WantsTraffic = $false }
            )) {
            $path = Join-Path $here $item.File
            if (-not (Test-Path $path)) {
                Write-Host "  $($item.Name): not present, skipped" -ForegroundColor Yellow
                continue
            }
            Write-Host ''
            Write-Host "  --- $($item.Name) ---" -ForegroundColor DarkCyan
            $args2 = @($item.Args)
            if ($TrafficIp -and $item.WantsTraffic) { $args2 += @('-TrafficIp', $TrafficIp) }
            & pwsh -NoProfile -File $path @args2
            if ($LASTEXITCODE -ne 0) { $legacyFails += "$($item.Name) (exit $LASTEXITCODE)" }
        }

        $soak = Join-Path $here 'legacy/Test-Soak.ps1'
        if ((Test-Path $soak) -and -not $Quick) {
            Write-Host ''
            Write-Host '  --- Test-Soak (bounded) ---' -ForegroundColor DarkCyan
            $sa = @('-Ip', $Ip, '-Cycles', '2')
            if ($TrafficIp) { $sa += @('-TrafficIp', $TrafficIp) }
            & pwsh -NoProfile -File $soak @sa
            if ($LASTEXITCODE -ne 0) { $legacyFails += "Test-Soak (exit $LASTEXITCODE)" }
        }
        elseif ($Quick) {
            Write-Host '  Test-Soak skipped in a quick run.' -ForegroundColor Yellow
        }

        $elapsed = ((Get-Date) - $t0).TotalSeconds
        if ($legacyFails.Count -eq 0) { Add-StageResult -Name 'Legacy' -Status 'PASS' -Seconds $elapsed }
        else { Add-StageResult -Name 'Legacy' -Status 'FAIL' -Reason ($legacyFails -join '; ') -ExitCode 1 -Seconds $elapsed }
    }
}

# ─── Stage 6: rename guards on real hardware ────────────────────────────────────

if ($want -contains 'Rename') {
    Write-Stage '6' 'Rename - frame, drive and length guards on the device'
    Invoke-RigPowerGuard -Before 'Rename'
    if (-not $Ip) { Add-StageResult -Name 'Rename' -Status 'SKIPPED' -Reason 'no -Ip given' }
    elseif (-not $FtcTarget) { Add-StageResult -Name 'Rename' -Status 'SKIPPED' -Reason 'no -FtcTarget given - the suite renames files on a TP device' }
    elseif ($RunProfile -eq 'ReadOnly') { Add-StageResult -Name 'Rename' -Status 'SKIPPED' -Reason 'profile ReadOnly - renaming writes to the device filesystem' }
    else {
        $a = @('-Ip', $Ip, '-Port', "$Port", '-Pa', $FtcTarget)
        if ($FtcPassword) { $a += @('-Password', $FtcPassword) }
        Invoke-Stage -Name 'Rename' -Script (Join-Path $here 'Features/Test-Rename.ps1') -Arguments $a -ReportDirectory $ReportDir -NoReport
    }
}

# ─── Stage 6b: monitor fidelity against certified interfaces ────────────────────
# What our device REPORTS about the bus, compared with what a certified interface reports about the
# same bus at the same time. A device can pass every protocol case and still hand the user a
# different picture of the line, which is the one thing a monitor exists to get right.

if ($want -contains 'Fidelity') {
    Write-Stage '6b' 'Monitor fidelity - group and bus monitor against certified interfaces'
    Invoke-RigPowerGuard -Before 'Fidelity'
    $refs = @()
    $refSrc = if ($ReferenceIps) { $ReferenceIps } else { $ReferenceIp }
    foreach ($r in ($refSrc -split '[,;\s]+')) { if ($r.Trim() -and $r.Trim() -ne $Ip) { $refs += $r.Trim() } }
    $oknxCmd = Get-Command oknx -ErrorAction SilentlyContinue
    if (-not $Ip) { Add-StageResult -Name 'Fidelity' -Status 'SKIPPED' -Reason 'no -Ip given' }
    elseif ($refs.Count -eq 0) { Add-StageResult -Name 'Fidelity' -Status 'SKIPPED' -Reason 'no reference interface given - pass -ReferenceIps 11.11.0.2,11.11.0.5' }
    elseif (-not $oknxCmd) { Add-StageResult -Name 'Fidelity' -Status 'SKIPPED' -Reason 'the oknx tool is not on PATH' }
    else {
        $t0 = Get-Date
        $fidFails = @()
        $fidNotes = @()
        # The group monitor works on every interface; the raw bus monitor only where the hardware
        # has one, and a device without it refuses the busmonitor layer.
        $modes = @('gm')
        if ($ExpectBusmonitor) { $modes += 'bm' }
        foreach ($ref in $refs) {
            foreach ($mode in $modes) {
                Write-Host ''
                Write-Host "  --- $mode : $Ip against $ref ---" -ForegroundColor DarkCyan
                $out = & $oknxCmd.Source '-i' $Ip $mode 'compare' $ref '--seconds' "$FidelitySeconds" 2>&1
                $code = $LASTEXITCODE
                $out | ForEach-Object { Write-Host "  $_" }
                # The client ends with one machine-readable line: a word, then the counters. Match its
                # SHAPE, not a list of words: the old list was IDENTICAL|DIFFER|DIFFERENT while the tool
                # emits IDENTICAL|DIVERGENT|MULTI, so the only word both sides knew was IDENTICAL and
                # every real difference was filed as "no result line" - a finding about the device
                # reported as a failure to read it. Keyed on "<WORD> ... seenA=" no word can be lost again.
                $line = ''
                # -cmatch, anchored on the tab the client writes ("%s\tseenA=..."): stderr is merged by 2>&1
                # and the loop keeps the LAST match, so a diagnostic such as "WARN  ... seenA=3" must not match.
                foreach ($l in $out) { if ("$l" -cmatch "^([A-Z][A-Z_]+)`tseenA=\d+") { $line = "$l".Trim() } }
                # The stage keeps no report of its own, so without this the counters that name the class
                # of a difference are printed once and gone - which is why an earlier divergence could
                # not be diagnosed afterwards at all.
                if ($ReportDir -and (Test-Path $ReportDir)) {
                    $fidLog = Join-Path $ReportDir ("fidelity-{0}-{1}.txt" -f $mode, ($ref -replace '[^0-9A-Za-z]', '_'))
                    try { ($out | ForEach-Object { "$_" }) -join [Environment]::NewLine | Set-Content -Path $fidLog -Encoding UTF8 } catch { }
                }
                if (-not $line) {
                    $fidFails += "$mode/$ref (the client printed no result line)"
                    $fidNotes += "$mode $ref : no result line from the client"
                    continue
                }
                $seenA = if ($line -match 'seenA=(\d+)') { [int]$Matches[1] } else { 0 }
                $seenB = if ($line -match 'seenB=(\d+)') { [int]$Matches[1] } else { 0 }
                $resultWord = ($line -split '\s+')[0]
                # Two monitors that both saw nothing agree about nothing - that is not fidelity.
                if ($seenA -eq 0 -and $seenB -eq 0) {
                    $fidNotes += "$mode $ref : no traffic on the line, nothing to compare"
                }
                elseif ($resultWord -eq 'IDENTICAL') {
                    $fidNotes += "$mode $ref : identical ($seenA telegrams)"
                }
                else {
                    # Name the class of the difference, not just the word: onlyA/onlyB says who dropped,
                    # notReported with statusA/statusB says one side's monitor cannot report a dimension
                    # at all - a capability gap, not a fidelity failure, and the two need telling apart.
                    $detail = @()
                    foreach ($k in 'onlyA', 'onlyB', 'countMismatch', 'integrityMismatch', 'ackMismatch', 'notReported', 'incompleteA', 'incompleteB') {
                        if ($line -match "$k=(\d+)" -and [int]$Matches[1] -gt 0) { $detail += "$k=$($Matches[1])" }
                    }
                    $what = if ($detail.Count -gt 0) { "$resultWord ($($detail -join ', '))" } else { $resultWord }
                    $fidFails += "$mode/$ref ($what)"
                    $fidNotes += "$mode $ref : $what, seen $seenA/$seenB"
                }
                if ($code -ne 0 -and $resultWord -ne 'IDENTICAL') { $fidFails += "$mode/$ref (exit $code)" }
            }
        }
        $elapsed = ((Get-Date) - $t0).TotalSeconds
        $note = ($fidNotes -join ' · ')
        if ($fidFails.Count -eq 0) { Add-StageResult -Name 'Fidelity' -Status 'PASS' -Reason $note -Seconds $elapsed }
        else { Add-StageResult -Name 'Fidelity' -Status 'FAIL' -Reason ("$note; abweichend: " + (($fidFails | Select-Object -Unique) -join ', ')) -ExitCode 1 -Seconds $elapsed }
    }
}

# ─── Stage 7: evented device state ──────────────────────────────────────────────

if ($want -contains 'DeviceState') {
    Write-Stage '7' 'Device state - the evented PID_KNXNETIP_DEVICE_STATE'
    Invoke-RigPowerGuard -Before 'Device state'
    if (-not $Ip) { Add-StageResult -Name 'Device state' -Status 'SKIPPED' -Reason 'no -Ip given' }
    else {
        # The tool exits 0 all passed, 1 a check failed, 2 rig fault (a relay not confirmed ON after the cut),
        # 3 the KNX-fault cases did not all run. 2 is not "library self-test failed" here, so Invoke-Stage is not used.
        $t0 = Get-Date
        $script = Join-Path $here 'Tools/Test-DeviceStateIndication.ps1'
        if (-not (Test-Path $script)) {
            Add-StageResult -Name 'Device state' -Status 'SKIPPED' -Reason "script not found: $script"
        }
        else {
            $a = @('-Ip', $Ip, '-Port', $Port, '-ReportDir', $ReportDir)
            if ($BdutPa) { $a += @('-BdutPa', $BdutPa) }
            if ($IncludeDestructive -and $RunProfile -ne 'ReadOnly') { $a += '-IncludeDestructive' }
            if ($PowerGuard -eq 'on') {
                $a += @('-PowerGuard', 'on')
                if ($PowerRelayWrite) { $a += @('-PowerRelayWrite', $PowerRelayWrite) }
                if ($PowerRelayStatus) { $a += @('-PowerRelayStatus', $PowerRelayStatus) }
                if ($PowerRelayVia) { $a += @('-PowerRelayVia', $PowerRelayVia) }
                if ($PowerRelayFeeds) { $a += @('-PowerRelayFeeds', $PowerRelayFeeds) }
            }
            & pwsh -NoProfile -File $script @a
            $code = $LASTEXITCODE
            $elapsed = ((Get-Date) - $t0).TotalSeconds
            $report = Get-NewestReport -Directory $ReportDir -After $t0 -Pattern 'device-state_*.json'
            $counts = Read-ReportCounts -Path $report
            # The KNX-fault cases DS-KF-1..3: timing notes for a pass, result and reason otherwise.
            $kfTiming = @(); $kfOpen = @(); $kf2 = ''
            if ($report) {
                try {
                    $open = [ordered]@{}
                    foreach ($c in @((Get-Content -Path $report -Raw | ConvertFrom-Json).results)) {
                        if ($c.Id -eq 'DS-KF-2') { $kf2 = "$($c.Result)" }
                        if ($c.Result -eq 'PASS') { $kfTiming += @($c.Notes | Where-Object { "$_" -like 'timing:*' } | ForEach-Object { "$_".Substring(8) }) }
                        else {
                            # Cases that ended for the same reason are named once.
                            $miss = if ($c.Missing) { ' (' + $c.Missing + ')' } else { '' }
                            $key = ('{0}{1}: {2}' -f $c.Result, $miss, $c.Reason)
                            if ($open.Contains($key)) { $open[$key] += ",$($c.Id)" } else { $open[$key] = "$($c.Id)" }
                        }
                    }
                    foreach ($k in $open.Keys) { $kfOpen += "$($open[$k]) $k" }
                }
                catch { $kfOpen += "report not readable: $report" }
            }
            # 3: the checks that could run passed, but not every KNX-fault case ran. Read as PASS it would claim
            # the evented M_PropInfo.ind was confirmed; read as FAIL it would report a defect that was not seen.
            $allPass = ($null -ne $counts -and $counts.Total -gt 0 -and $counts.Pass -eq $counts.Total)
            if ($code -eq 0 -and $allPass) {
                Add-StageResult -Name 'Device state' -Status 'PASS' -Seconds $elapsed -Counts $counts -Report $report `
                    -Reason ("the evented M_PropInfo.ind was judged by the KNX-fault cases: " + ($kfTiming -join '; '))
            }
            elseif ($code -eq 0) {
                Add-StageResult -Name 'Device state' -Status 'FAIL' -ExitCode $code -Seconds $elapsed -Counts $counts -Report $report `
                    -Reason 'no report: the tool exited 0, but no device-state report with every case PASS was found'
            }
            elseif ($code -eq 2) {
                $relay = @($PowerRelayWrite -split '[,;\s]+' | Where-Object { $_ })[0]
                $rig = "RIG FAULT: relay $relay is OFF, switch on via $PowerRelayVia"
                Write-Host ''
                Write-Host "  $rig" -ForegroundColor Red
                $why = $rig
                if ($kfOpen.Count -gt 0) { $why += '; KNX-fault cases: ' + ($kfOpen -join '; ') }
                Add-StageResult -Name 'Device state' -Status 'FAIL' -ExitCode $code -Seconds $elapsed -Counts $counts -Report $report -Reason $why
            }
            elseif ($code -eq 3) {
                $why = if ($kf2 -eq 'PASS') { 'the evented M_PropInfo.ind was judged by DS-KF-2, but not every KNX-fault case ran' }
                       else { 'the readable and write-refusal checks passed; the evented M_PropInfo.ind (03_08_03 2.5.20 p.14) was NOT judged - it needs a real KNX or IP fault and the property is read-only' }
                if ($kfOpen.Count -gt 0) { $why += '; KNX-fault cases: ' + ($kfOpen -join '; ') }
                Add-StageResult -Name 'Device state' -Status 'SKIPPED' -Seconds $elapsed -Counts $counts -Report $report -Reason $why
            }
            else {
                $why = "exit $code - a check failed, see the output above"
                if ($kfOpen.Count -gt 0) { $why += '; KNX-fault cases: ' + ($kfOpen -join '; ') }
                Add-StageResult -Name 'Device state' -Status 'FAIL' -Reason $why -ExitCode $code -Counts $counts -Report $report -Seconds $elapsed
            }
        }
    }
}

# ─── Stage 8: comparison against certified reference devices ────────────────────
# -ReferenceIp takes a list: every certified interface on the rig is a separate yardstick, and a
# result our device and a certified one both give is worth more than either on its own.

if ($want -contains 'Reference') {
    Write-Stage '8' 'Reference - the same suite against certified third-party interfaces'
    Invoke-RigPowerGuard -Before 'Reference'
    $refs = @()
    $refSource = if ($ReferenceIps) { $ReferenceIps } else { $ReferenceIp }
    foreach ($r in ($refSource -split '[,;\s]+')) { if ($r.Trim()) { $refs += $r.Trim() } }
    if (-not $Ip) { Add-StageResult -Name 'Reference' -Status 'SKIPPED' -Reason 'no -Ip given' }
    elseif ($refs.Count -eq 0) {
        Add-StageResult -Name 'Reference' -Status 'SKIPPED' -Reason 'no -ReferenceIp given - pass a certified interface to compare against, e.g. -ReferenceIp 11.11.0.2'
    }
    else {
        $t0 = Get-Date
        $refFails = @()
        $refUsed = @()
        $refUnusable = @()
        foreach ($ref in $refs) {
            if ($ref -eq $Ip) { Write-Host "  $ref is the device under test, not a reference - skipped" -ForegroundColor Yellow; continue }
            Write-Host ''
            Write-Host "  --- reference $ref ---" -ForegroundColor DarkCyan
            $a = @('-Ip', $Ip, '-Port', "$Port", '-ReferenceIp', $ref, '-ReportDir', $ReportDir, '-Multicast', $Multicast)
            if ($TrafficIp) { $a += @('-TrafficIp', $TrafficIp) }
            if ($BdutPa) { $a += @('-BdutPa', $BdutPa) }
            if ($Quick) { $a += '-Quick' }
            & pwsh -NoProfile -File (Join-Path $here 'runners/Compare-Reference.ps1') @a
            # 3 means the rig could not offer this reference; that is not a result about our device.
            if ($LASTEXITCODE -eq 3) { Write-Host "  reference $ref not usable right now" -ForegroundColor Yellow; $refUnusable += $ref; continue }
            $refUsed += $ref
            if ($LASTEXITCODE -ne 0) { $refFails += "$ref (exit $LASTEXITCODE)" }
        }
        $elapsed = ((Get-Date) - $t0).TotalSeconds
        # A reference whose comparison did not run is named in the result; with none run there is nothing to judge.
        $refNote = if ($refUnusable.Count -gt 0) { "not compared: $($refUnusable -join ', ')" } else { '' }
        if ($refUsed.Count -eq 0) { Add-StageResult -Name 'Reference' -Status 'SKIPPED' -Reason ('no comparison could be run' + $(if ($refNote) { " - $refNote" } else { '' })) -Seconds $elapsed }
        elseif ($refFails.Count -eq 0) { Add-StageResult -Name 'Reference' -Status 'PASS' -Reason $refNote -Seconds $elapsed }
        else { Add-StageResult -Name 'Reference' -Status 'FAIL' -Reason ((@($refFails) + @($refNote | Where-Object { $_ })) -join '; ') -ExitCode 1 -Seconds $elapsed }
    }
}

# ─── Stage 9: ETS readback ──────────────────────────────────────────────────────

if ($want -contains 'EtsReadback') {
    Write-Stage '9' 'ETS readback - replay a recorded download and compare the answers'
    Invoke-RigPowerGuard -Before 'ETS readback'
    if (-not $EtsPairs) {
        Add-StageResult -Name 'ETS readback' -Status 'SKIPPED' -Reason 'no -EtsPairs given - record a download with Tools/Watch-EtsSession.ps1 first, then pass the file'
    }
    elseif (-not (Test-Path $EtsPairs)) {
        Add-StageResult -Name 'ETS readback' -Status 'SKIPPED' -Reason "the recording $EtsPairs does not exist"
    }
    else {
        $a = @('-Ip', $Ip, '-Pairs', $EtsPairs)
        if ($BdutPa) { $a += @('-Pa', $BdutPa) }
        Invoke-Stage -Name 'ETS readback' -Script (Join-Path $here 'runners/Invoke-EtsReadback.ps1') -Arguments $a -ReportDirectory $ReportDir -NoReport
    }
}

# ─── Stage 10: file transfer throughput ─────────────────────────────────────────
# Last on purpose: it moves real payload over the bus for many minutes and would distort the
# timing of every stage that came after it.

if ($want -contains 'Speed') {
    Write-Stage '10' "Speed - $SpeedKb KB to a TP device in both transfer modes"
    Invoke-RigPowerGuard -Before 'Speed'
    $oknx = Get-Command oknx -ErrorAction SilentlyContinue
    if (-not $Ip) { Add-StageResult -Name 'Speed' -Status 'SKIPPED' -Reason 'no -Ip given' }
    elseif (-not $SpeedTarget) { Add-StageResult -Name 'Speed' -Status 'SKIPPED' -Reason 'no -SpeedTarget given - name the TP device that receives the transfer, e.g. -SpeedTarget 1.1.8' }
    elseif (-not $oknx) { Add-StageResult -Name 'Speed' -Status 'SKIPPED' -Reason 'the oknx tool is not on PATH' }
    elseif ($RunProfile -eq 'ReadOnly') { Add-StageResult -Name 'Speed' -Status 'SKIPPED' -Reason 'profile ReadOnly - the transfer writes a file on the target' }
    else {
        $t0 = Get-Date
        $speedFails = @()
        $rates = @()
        foreach ($mode in @('safe', 'fast')) {
            Write-Host ''
            Write-Host "  --- $SpeedKb KB to $SpeedTarget, mode $mode ---" -ForegroundColor DarkCyan
            $out = & $oknx.Source '-i' $Ip $SpeedTarget 'perf' "$SpeedKb" $mode 2>&1
            $code = $LASTEXITCODE
            $out | ForEach-Object { Write-Host "  $_" }
            # The client prints its own measurement; quoting it beats recomputing it from a wall clock
            # that also contains the connect and the cleanup.
            $avg = ''
            foreach ($line in $out) { if ("$line" -match 'avg\s+([0-9]+)\s*B/s') { $avg = $Matches[1] } }
            if ($avg) { $rates += "$mode $avg B/s" } else { $rates += "$mode (no rate reported)" }
            if ($code -ne 0) { $speedFails += "$mode (exit $code)" }
        }
        $elapsed = ((Get-Date) - $t0).TotalSeconds
        $note = ($rates -join ' · ')
        if ($speedFails.Count -eq 0) { Add-StageResult -Name 'Speed' -Status 'PASS' -Reason $note -Seconds $elapsed }
        else { Add-StageResult -Name 'Speed' -Status 'FAIL' -Reason ("$note; failed: " + ($speedFails -join '; ')) -ExitCode 1 -Seconds $elapsed }
    }
}

# ─── Combined result ───────────────────────────────────────────────────────────

$runEnd = Get-Date
$totalSeconds = [Math]::Round(($runEnd - $runStart).TotalSeconds, 0)

$sumTotal = 0; $sumPass = 0; $sumFail = 0; $sumSkip = 0; $sumNA = 0; $sumNotRun = 0; $sumDropped = 0
# Result classes the reports carry beyond the five columns above, summed under their own names.
$sumOther = 0
$otherClasses = [ordered]@{}
foreach ($s in $stages) {
    if ($null -eq $s.Counts) { continue }
    $sumTotal += $s.Counts.Total; $sumPass += $s.Counts.Pass
    $sumFail += $s.Counts.Fail; $sumSkip += $s.Counts.Skip; $sumNA += $s.Counts.NA
    $sumNotRun += $s.Counts.NotRun
    if ($null -ne $s.Counts.PSObject.Properties['Dropped']) { $sumDropped += [int]$s.Counts.Dropped }
    if ($null -ne $s.Counts.PSObject.Properties['Other'] -and $null -ne $s.Counts.Other) {
        foreach ($k in @($s.Counts.Other.Keys)) {
            $v = [int]$s.Counts.Other[$k]
            $sumOther += $v
            if ($otherClasses.Contains($k)) { $otherClasses[$k] = [int]$otherClasses[$k] + $v }
            else { $otherClasses[$k] = $v }
        }
    }
}

$failedStages = @($stages | Where-Object { $_.Status -eq 'FAIL' -or $_.Status -eq 'ERROR' })
$skippedStages = @($stages | Where-Object { $_.Status -eq 'SKIPPED' })
# A stage that ran but whose report could not be read contributes nothing to the sums above. With
# every report unreadable all sums stay 0, so a check on the sums alone never fires and the run
# printed "everything passed" without having read one result. The stages are named and fail the run.
$unreadStages = @($stages | Where-Object {
        $null -eq $_.Counts -and $_.Status -ne 'SKIPPED' -and
        $null -ne $_.PSObject.Properties['ExpectsReport'] -and $_.ExpectsReport
    })

Write-Host ''
Write-Host ('  ' + ('═' * 72)) -ForegroundColor DarkCyan
Write-Host '  RESULT' -ForegroundColor Cyan
Write-Host ('  ' + ('═' * 72)) -ForegroundColor DarkCyan
Write-Host ''
Write-Host '  Stage           Status    Cases (P/F/NR/S/N-A)       Time'
Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkGray
foreach ($s in $stages) {
    $col = switch ($s.Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'SKIPPED' { 'Yellow' } default { 'Red' } }
    $cases = '-'
    if ($null -ne $s.Counts) {
        $cases = "{0}/{1}/{2}/{3}/{4}" -f $s.Counts.Pass, $s.Counts.Fail, $s.Counts.NotRun, $s.Counts.Skip, $s.Counts.NA
        if ($null -ne $s.Counts.PSObject.Properties['Other'] -and $null -ne $s.Counts.Other) {
            foreach ($k in @($s.Counts.Other.Keys)) { $cases += " +$($s.Counts.Other[$k]) $(Get-ResultLabel $k)" }
        }
    }
    Write-Host ("  {0} {1} {2} {3}" -f $s.Name.PadRight(15), $s.Status.PadRight(9), $cases.PadRight(26), ("$($s.Seconds)s")) -ForegroundColor $col
    if ($s.Reason) { Write-Host ("                  {0}" -f $s.Reason) -ForegroundColor DarkGray }
}
Write-Host ''
# Cases that fall out of the projection are unreported work, not a cosmetic defect: whichever bucket
# they belonged to, nobody looked at them. A warning left the result and the exit code green, so a
# run that lost cases was signed off as passed - the gap therefore fails the run.
$bucketed = $sumPass + $sumFail + $sumNotRun + $sumSkip + $sumNA + $sumOther
$bucketGap = $sumTotal - $bucketed
if ($sumTotal -gt 0) {
    Write-Host "  Cases total $sumTotal   " -NoNewline
    Write-Host "PASS $sumPass  " -ForegroundColor Green -NoNewline
    Write-Host "FAIL $sumFail  " -ForegroundColor $(if ($sumFail) { 'Red' } else { 'DarkGray' }) -NoNewline
    Write-Host "NOT-RUN $sumNotRun  " -ForegroundColor $(if ($sumNotRun) { 'Yellow' } else { 'DarkGray' }) -NoNewline
    Write-Host "SKIP $sumSkip  " -ForegroundColor Yellow -NoNewline
    Write-Host "N-A $sumNA" -ForegroundColor DarkGray -NoNewline
    # A case that proved nothing belongs on the line a human reads first, not only in the files.
    foreach ($k in $otherClasses.Keys) { Write-Host ("  " + (Get-ResultLabel $k) + " " + $otherClasses[$k]) -ForegroundColor Yellow -NoNewline }
    Write-Host ''
}
if ($sumDropped -gt 0) { Write-Host "  DROPPED-SUITES $sumDropped" -ForegroundColor Yellow }
# The buckets must account for every case the stages reported, once each. Too few means a result
# class is missing here, too many means a case is counted twice - both make the totals wrong.
if ($bucketGap -gt 0) {
    Write-Host "  SELF-CHECK FAILED: $sumTotal case(s) reported but $bucketed accounted for - $bucketGap case(s) appear in no result class of this summary" -ForegroundColor Red
}
elseif ($bucketGap -lt 0) {
    Write-Host "  SELF-CHECK FAILED: $sumTotal case(s) reported but $bucketed accounted for - $(-$bucketGap) case(s) are counted in more than one result class" -ForegroundColor Red
}
foreach ($s in $unreadStages) {
    $rep = if ($s.Report) { Split-Path -Leaf $s.Report } else { 'no report file found' }
    Write-Host "  SELF-CHECK FAILED: the report of stage $($s.Name) could not be read ($rep) - none of its cases is in the counts above" -ForegroundColor Red
}
foreach ($e in $rigEvents) { Write-Host "  RIG EVENT before $($e.Before): rig power $($e.Event) - $($e.Detail)" -ForegroundColor $(if ($e.Ok) { 'Yellow' } else { 'Red' }) }
Write-Host "  Wall clock  ${totalSeconds}s"
Write-Host ''

# The headline. It has to be readable from across the room and it must not overclaim.
$resultInvalid = ($bucketGap -ne 0 -or $unreadStages.Count -gt 0)
# A suite a safety gate refused never ran, exactly as a skipped stage never ran. The JSON already
# called such a run INCOMPLETE while this headline said "everything ran, and everything passed".
$notAllRan = ($skippedStages.Count -gt 0 -or $sumDropped -gt 0)
if ($resultInvalid) { Write-ResultBox -Text 'The result is not valid' -Color Red }
elseif ($failedStages.Count -gt 0) { Write-ResultBox -Text 'Some tests failed' -Color Red }
elseif ($notAllRan -and $sumOther -gt 0) { Write-ResultBox -Text 'Not everything ran, and not all of it is proven' -Color Yellow }
elseif ($notAllRan) { Write-ResultBox -Text 'All that ran passed - but not everything ran' -Color Yellow }
elseif ($sumOther -gt 0) { Write-ResultBox -Text 'Everything ran - but not every case is proven' -Color Yellow }
else { Write-ResultBox -Text 'Everything ran, and everything passed' -Color Green }

# Each list stands on its own: a counting gap says nothing about which stages did not run, so it
# must not take their place. Earlier the gap branch was first in an elseif chain and hid them.
if ($bucketGap -gt 0) {
    Write-Host ''
    Write-Host "    - $bucketGap case(s) reported by the stages appear in no result class of this summary" -ForegroundColor Red
}
elseif ($bucketGap -lt 0) {
    Write-Host ''
    Write-Host "    - $(-$bucketGap) case(s) are counted in more than one result class, so the totals above overstate the run" -ForegroundColor Red
}
if ($unreadStages.Count -gt 0) {
    Write-Host ''
    Write-Host '  These stages ran but their report could not be read, so their cases are in no total:' -ForegroundColor Red
    foreach ($s in $unreadStages) { Write-Host "    - $($s.Name) (exit $($s.ExitCode))" -ForegroundColor Red }
}
if ($failedStages.Count -gt 0) {
    Write-Host ''
    foreach ($s in $failedStages) { Write-Host "    - $($s.Name): $($s.Reason)" -ForegroundColor Red }
}
if ($sumOther -gt 0) {
    Write-Host ''
    foreach ($k in $otherClasses.Keys) {
        Write-Host ("    - $($otherClasses[$k]) case(s) are " + (Get-ResultLabel $k) + ": they carry no pass or fail, so nothing about them is signed off.") -ForegroundColor Yellow
    }
}
if ($sumDropped -gt 0) {
    Write-Host ''
    Write-Host "    - $sumDropped whole suite(s) were refused by a safety gate and left no case behind." -ForegroundColor Yellow
}
if ($skippedStages.Count -gt 0) {
    Write-Host ''
    Write-Host '  These stages did not run:' -ForegroundColor Yellow
    foreach ($s in $skippedStages) { Write-Host "    - $($s.Name): $($s.Reason)" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '  A certification run needs all of them.' -ForegroundColor Yellow
}

if ($sumSkip -gt 0) {
    Write-Host ''
    Write-Host "  $sumSkip individual case(s) were skipped - each with its reason in the report." -ForegroundColor Yellow
}

# ─── Combined report ────────────────────────────────────────────────────────────

$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine('# Test run - all stages')
[void]$md.AppendLine('')
[void]$md.AppendLine("Started: $($runStart.ToString('yyyy-MM-dd HH:mm:ss'))  ")
[void]$md.AppendLine("Finished: $($runEnd.ToString('yyyy-MM-dd HH:mm:ss'))  ")
[void]$md.AppendLine("Duration: ${totalSeconds}s")
[void]$md.AppendLine('')
[void]$md.AppendLine('| Setting | Value |')
[void]$md.AppendLine('|---|---|')
[void]$md.AppendLine("| Device under test | $(if ($Ip) { $Ip } else { 'none' }) |")
[void]$md.AppendLine("| Traffic interface | $(if ($TrafficIp) { $TrafficIp } else { 'none' }) |")
[void]$md.AppendLine("| Reference device | $(if ($ReferenceIp) { $ReferenceIp } else { 'none' }) |")
[void]$md.AppendLine("| FTC console | $(if ($SerialPort) { $SerialPort } else { 'none' }) |")
[void]$md.AppendLine("| Profile | $RunProfile |")
[void]$md.AppendLine("| Quick | $($Quick.ToString()) |")
[void]$md.AppendLine("| Destructive | $($IncludeDestructive.ToString()) |")
[void]$md.AppendLine("| Hard reset | $($IncludeHardReset.ToString()) |")
[void]$md.AppendLine("| Multicast | $Multicast |")
[void]$md.AppendLine("| Rig power guard | $powerLine |")
[void]$md.AppendLine('')
if ($rigEvents.Count -gt 0) {
    [void]$md.AppendLine('## Rig events')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| Before stage | Time | Event | Seconds | Detail |')
    [void]$md.AppendLine('|---|---|---|---|---|')
    foreach ($e in $rigEvents) { [void]$md.AppendLine("| $($e.Before) | $($e.Time) | **$($e.Event)** | $($e.Seconds) | $($e.Detail) |") }
    [void]$md.AppendLine('')
}
[void]$md.AppendLine('## Stages')
[void]$md.AppendLine('')
[void]$md.AppendLine('| Stage | Status | PASS | FAIL | NOT-RUN | SKIP | N-A | Other classes | Seconds | Reason | Report |')
[void]$md.AppendLine('|---|---|---|---|---|---|---|---|---|---|---|')
foreach ($s in $stages) {
    $p = '-'; $f = '-'; $sk = '-'; $na = '-'; $nr = '-'; $oth = '-'
    if ($null -ne $s.Counts) {
        $p = $s.Counts.Pass; $f = $s.Counts.Fail; $sk = $s.Counts.Skip; $na = $s.Counts.NA; $nr = $s.Counts.NotRun
        if ($null -ne $s.Counts.PSObject.Properties['Other'] -and $null -ne $s.Counts.Other -and $s.Counts.Other.Count -gt 0) {
            $oth = ((@($s.Counts.Other.Keys) | ForEach-Object { "$(Get-ResultLabel $_) $($s.Counts.Other[$_])" }) -join ', ')
        }
    }
    $rep = '-'
    if ($s.Report) { $rep = Split-Path -Leaf $s.Report }
    [void]$md.AppendLine("| $($s.Name) | **$($s.Status)** | $p | $f | $nr | $sk | $na | $oth | $($s.Seconds) | $($s.Reason) | $rep |")
}
[void]$md.AppendLine('')
[void]$md.AppendLine('## Result')
[void]$md.AppendLine('')
if ($resultInvalid) {
    [void]$md.AppendLine('**The result is not valid.** The totals above do not describe the run. No part of this result is signed off until every case the stages reported is accounted for exactly once.')
    [void]$md.AppendLine('')
}
elseif ($failedStages.Count -gt 0) {
    [void]$md.AppendLine('**Some tests failed.** Each stage below links to its own report, where every failed case carries the bytes that were sent and received.')
    [void]$md.AppendLine('')
}
elseif ($notAllRan) {
    [void]$md.AppendLine('**All that ran passed - but not everything ran.** What was left out is listed below, each with its reason. A missing stage is not a green one.')
    [void]$md.AppendLine('')
}
elseif ($sumOther -gt 0) {
    [void]$md.AppendLine('**Everything ran - but not every case is proven.** The cases below carry a result that is neither pass nor fail, so they prove nothing about the device.')
    [void]$md.AppendLine('')
}
else {
    [void]$md.AppendLine('**Everything ran, and everything passed.**')
}
# The lists are independent of the headline: a counting gap must not replace the stages that did not run.
if ($bucketGap -gt 0) {
    [void]$md.AppendLine("* The stages reported $sumTotal case(s), $bucketed are accounted for - $bucketGap appear in no result class.")
}
elseif ($bucketGap -lt 0) {
    [void]$md.AppendLine("* The stages reported $sumTotal case(s), $bucketed are accounted for - $(-$bucketGap) are counted in more than one result class.")
}
foreach ($s in $unreadStages) {
    $rep = if ($s.Report) { Split-Path -Leaf $s.Report } else { 'no report file found' }
    [void]$md.AppendLine("* $($s.Name): the stage ran (exit $($s.ExitCode)) but its report could not be read ($rep) - none of its cases is in the totals.")
}
foreach ($s in $failedStages) { [void]$md.AppendLine("* $($s.Name): $($s.Reason)") }
foreach ($k in $otherClasses.Keys) {
    [void]$md.AppendLine("* $($otherClasses[$k]) case(s) are $(Get-ResultLabel $k): they carry no pass or fail, so nothing about them is signed off.")
}
if ($sumDropped -gt 0) { [void]$md.AppendLine("* $sumDropped whole suite(s) were refused by a safety gate and left no case behind.") }
foreach ($s in $skippedStages) { [void]$md.AppendLine("* $($s.Name) did not run: $($s.Reason)") }

# The combined report belongs INSIDE the run's folder, next to the per-stage ones, not beside it:
# one run, one directory. -MainReportDir is accepted and ignored.
$mainDir = $ReportDir
if (-not (Test-Path $mainDir)) { [void](New-Item -ItemType Directory -Force -Path $mainDir) }
$mainName = if ($RunId) { $RunId } else { "AllTests_$stamp" }
$combinedMd = Join-Path $mainDir "$mainName.md"
$combinedJson = Join-Path $mainDir "$mainName.json"
[System.IO.File]::WriteAllText($combinedMd, $md.ToString())
([pscustomobject]@{
        started  = $runStart.ToString('o')
        finished = $runEnd.ToString('o')
        seconds  = $totalSeconds
        settings = @{
            bdut = $Ip; traffic = $TrafficIp; reference = $ReferenceIp; console = $SerialPort
            profile = $RunProfile; quick = [bool]$Quick; destructive = [bool]$IncludeDestructive
            hardReset = [bool]$IncludeHardReset; multicast = $Multicast
            powerGuard = $PowerGuard; powerRelayWrite = $PowerRelayWrite; powerRelayStatus = $PowerRelayStatus
            powerRelayVia = $PowerRelayVia; protectedTargets = $ProtectedTargets; powerRelayFeeds = $PowerRelayFeeds
        }
        rigEvents = @($rigEvents)
        # notRun belongs here too: the console line counts it and checks the sum, the machine file did
        # not, so a reader of the JSON found total != pass+fail+skip+na and no way to explain it.
        totals   = @{ total = $sumTotal; pass = $sumPass; fail = $sumFail; notRun = $sumNotRun; skip = $sumSkip; na = $sumNA; droppedSuites = $sumDropped; unaccounted = $bucketGap; unreadReports = $unreadStages.Count; otherClasses = $otherClasses }
        stages   = @($stages)
        # A dropped suite makes the run incomplete just as a skipped stage does: part of what was asked
        # for never ran, and PASS would say otherwise. Cases in a class that is neither pass nor fail
        # are incomplete for the same reason. A bucket gap and an unread report are worse - the summary
        # itself is then wrong about what ran, so the run fails.
        result  = $(if ($failedStages.Count -gt 0 -or $resultInvalid) { 'FAIL' } elseif ($skippedStages.Count -gt 0 -or $sumDropped -gt 0 -or $sumOther -gt 0) { 'INCOMPLETE' } else { 'PASS' })
    }) | ConvertTo-Json -Depth 6 | Set-Content -Path $combinedJson -Encoding UTF8

Write-Host ''
Write-Host "  Combined report: $combinedMd" -ForegroundColor Cyan
Write-Host "  Combined data  : $combinedJson" -ForegroundColor DarkGray
Write-Host ''

if ($failedStages.Count -gt 0 -or $resultInvalid) { exit 1 }
# Exit 3 is "the run did not judge all of it" - a refused suite and a case that proved nothing
# belong there, not in exit 0. The JSON result already called both of them INCOMPLETE.
if ($notAllRan -or $sumOther -gt 0) { exit 3 }
exit 0
