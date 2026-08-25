#!/usr/bin/env pwsh
<#
Open ■
┬────┴  Invoke-AllTests
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: scripts/Test/Invoke-AllTests.ps1

.SYNOPSIS
    Runs every test stage in one go and produces ONE combined verdict.

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
    Individual address of the FTC target device, e.g. 5.0.3.

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

.PARAMETER IncludeHardReset
    Allow H-7.5.9 Hard Reset. Forces factory configuration - see TSSH section 1.5.

.PARAMETER ExpectBusmonitor
    The device is built with OPENKNX_HW_BUSMON (feature stage).

.PARAMETER ExpectRouting
    The device is an IP-Router (feature stage).

.PARAMETER TunnelCount
    Configured number of tunnels (feature stage). Default 16.

.PARAMETER Multicast
    Routing multicast group. Never the production group - the conformance runner refuses.

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
                          -SerialPort /dev/cu.usbmodem84101 -FtcTarget 5.0.3 `   # Windows: -SerialPort COM5
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
    [string]$BdutPa = '',
    [string]$SerialPort = '',
    [string]$FtcTarget = '5.0.3',
    [string]$FtcPassword = '',
        [string[]]$Stage = @('All'),
    [switch]$Quick,
    [ValidateSet('Full', 'ReadOnly', 'Safe')]
    [string]$RunProfile = 'Safe',
    [switch]$IncludeDestructive,
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
    [string]$Multicast = '224.0.23.12',
    [string]$ReportDir = '',
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
    Write-Host ''
    Write-Host '  Open ■' -ForegroundColor Green
    Write-Host '  ┬────┴  Full test run' -ForegroundColor Green
    Write-Host '  ■ KNX   2026 OpenKNX - Erkan Çolak' -ForegroundColor DarkGray
    Write-Host ''
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
        [int]$ExitCode = 0, $Counts = $null, [string]$Report = '', [double]$Seconds = 0
    )
    [void]$stages.Add([pscustomobject]@{
            Name     = $Name
            Status   = $Status
            Reason   = $Reason
            ExitCode = $ExitCode
            Counts   = $Counts
            Report   = $Report
            Seconds  = [Math]::Round($Seconds, 1)
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
        return [pscustomobject]@{
            Total = [int]$j.summary.Total
            Pass  = [int]$j.summary.Pass
            Fail  = [int]$j.summary.Fail
            Skip  = [int]$j.summary.Skip
            NA    = [int]$j.summary.NA
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
        [string]$ReportDirectory, [string]$ReportPattern = '*.json'
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
        $reason = 'the rig is not ready for this stage - see the abort message above'
    }
    elseif ($code -eq 2) {
        $status = 'FAIL'
        $reason = 'the library self-test failed - results would not be trustworthy'
    }
    elseif ($code -ne 0) {
        $status = 'FAIL'
        if ($null -ne $counts) { $reason = "$($counts.Fail) case(s) failed" } else { $reason = "exit code $code" }
    }
    Add-StageResult -Name $Name -Status $status -Reason $reason -ExitCode $code -Counts $counts -Report $report -Seconds $elapsed
}

# ─── Start ──────────────────────────────────────────────────────────────────────

Show-Logo

$want = Expand-ListArgument -Value $Stage -Allowed @('SelfTest','Conformance','Features','Busmonitor','Devices','Hardening','Legacy','All') -Name 'Stage'
if ($want -contains 'All') { $want = @('SelfTest', 'Conformance', 'Features', 'Busmonitor', 'Devices', 'Hardening', 'Legacy') }
if ($SelfTestOnly) { $want = @('SelfTest') }

Write-Host "  Stages     : $($want -join ', ')"
Write-Host "  BDUT       : $(if ($Ip) { $Ip } else { 'none' })"
Write-Host "  Traffic    : $(if ($TrafficIp) { $TrafficIp } else { 'none' })"
Write-Host "  Reference  : $(if ($ReferenceIp) { $ReferenceIp } else { 'none' })"
Write-Host "  Console    : $(if ($SerialPort) { $SerialPort } else { 'none' })"
Write-Host "  Profile    : $RunProfile$(if ($Quick) { '  (quick)' } else { '' })"
if ($IncludeDestructive) { Write-Host '  Destructive: ENABLED' -ForegroundColor Yellow }
if ($IncludeHardReset) { Write-Host '  Hard reset : ENABLED - forces factory configuration' -ForegroundColor Red }
Write-Host "  Reports    : $ReportDir"

$ftmDir = Join-Path (Join-Path $parentDir 'OFM-FileTransferModule') 'scripts/Hardening'
$ftmReportDir = Join-Path $ftmDir 'Reports'

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

    $elapsed = ((Get-Date) - $t0).TotalSeconds
    if ($knxCode -eq 0 -and $ftmCode -eq 0) {
        Add-StageResult -Name 'Self-test' -Status 'PASS' -Seconds $elapsed
    }
    else {
        Add-StageResult -Name 'Self-test' -Status 'FAIL' -Reason 'a test library builds wrong frames' -ExitCode 1 -Seconds $elapsed
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

# ─── Stage 2: conformance ───────────────────────────────────────────────────────

if ($want -contains 'Conformance') {
    Write-Stage '2' 'Conformance - KNXnet/IP (TSSH sections 3-8)'
    if (-not $Ip) {
        Add-StageResult -Name 'Conformance' -Status 'SKIPPED' -Reason 'no -Ip given'
    }
    else {
        $a = @('-Ip', $Ip, '-Port', "$Port", '-Suite', 'All', '-RunProfile', $RunProfile, '-ReportDir', $ReportDir, '-Multicast', $Multicast)
        if ($TrafficIp) { $a += @('-TrafficIp', $TrafficIp) }
        if ($ReferenceIp) { $a += @('-ReferenceIp', $ReferenceIp) }
        if ($BdutPa) { $a += @('-BdutPa', $BdutPa) }
        if ($LoadSwitchVia) { $a += @('-LoadSwitchVia', $LoadSwitchVia) }
        if ($LoadSwitchGa) { $a += @('-LoadSwitchGa', $LoadSwitchGa) }
        if ($LoadSwitchPa) { $a += @('-LoadSwitchPa', $LoadSwitchPa) }
        if ($P2pTarget) { $a += @('-P2pTarget', $P2pTarget) }
        if ($IncludeDestructive) { $a += '-IncludeDestructive' }
        if ($IncludeHardReset) { $a += '-IncludeHardReset' }
        if ($Quick) { $a += '-SkipSlow' }
        Invoke-Stage -Name 'Conformance' -Script (Join-Path $here 'runners/Invoke-Conformance.ps1') -Arguments $a -ReportDirectory $ReportDir
    }
}

# ─── Stage 3: features ──────────────────────────────────────────────────────────

if ($want -contains 'Features') {
    Write-Stage '3' 'Features - product behaviour no specification prescribes'
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

if ($want -contains 'Busmonitor') {
    Write-Stage '4' 'Busmonitor - does it deliver the bus unchanged'
    if (-not $Ip) { Add-StageResult -Name 'Busmonitor' -Status 'SKIPPED' -Reason 'no -Ip given' }
    elseif (-not $TrafficIp) { Add-StageResult -Name 'Busmonitor' -Status 'SKIPPED' -Reason 'no -TrafficIp given - the busmonitor cases need real bus traffic' }
    elseif (-not (Wait-KnxInterfaceFree -TargetIp $TrafficIp -Port $Port)) {
        Add-StageResult -Name 'Busmonitor' -Status 'SKIPPED' -Reason "$TrafficIp never released a tunnel channel - every case would fail on the traffic source, not on the device"
    }
    else {
        $a = @('-Ip', $Ip, '-TrafficIp', $TrafficIp)
        Invoke-Stage -Name 'Busmonitor' -Script (Join-Path $here 'Features/Test-Busmonitor.ps1') -Arguments $a -ReportDirectory $ReportDir
    }
}

if ($want -contains 'Devices') {
    Write-Stage '5' 'Devices - KNX devices on the TP line against Volume 3'
    $devList = @()
    foreach ($t in $DeviceTargets) {
        if ($null -eq $t) { continue }
        foreach ($part in ($t -split '[,;\s]+')) { if ($part.Trim()) { $devList += $part.Trim() } }
    }
    if (-not $Ip) { Add-StageResult -Name 'Devices' -Status 'SKIPPED' -Reason 'no -Ip given' }
    elseif ($devList.Count -eq 0) {
        # Not an error: most runs judge the interface, not what hangs off it. Say what is
        # missing so nobody reads an absent stage as a clean one.
        Add-StageResult -Name 'Devices' -Status 'SKIPPED' -Reason 'no -DeviceTargets given - pass the individual addresses to test, e.g. -DeviceTargets 5.0.3,5.0.9'
    }
    else {
        $a = @('-Ip', $Ip, '-Port', $Port, '-Targets', ($devList -join ','))
        if ($Quick) { $a += '-SkipSlow' }
        if ($RunProfile -eq 'ReadOnly') { $a += '-ReadOnly' }
        Invoke-Stage -Name 'Devices' -Script (Join-Path $here 'runners/Invoke-DeviceTests.ps1') -Arguments $a -ReportDirectory $ReportDir
    }
}

if ($want -contains 'Hardening') {
    Write-Stage '4' 'Hardening - FTC / FTM / console (adversarial)'
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
    if (-not $Ip) {
        Add-StageResult -Name 'Legacy' -Status 'SKIPPED' -Reason 'no -Ip given'
    }
    elseif ($RunProfile -eq 'ReadOnly') {
        Add-StageResult -Name 'Legacy' -Status 'SKIPPED' -Reason 'profile ReadOnly - these scripts write to the bus and stress the device'
    }
    else {
        # These scripts predate the verdict engine: they have no JSON report, so only
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

# ─── Combined verdict ───────────────────────────────────────────────────────────

$runEnd = Get-Date
$totalSeconds = [Math]::Round(($runEnd - $runStart).TotalSeconds, 0)

$sumTotal = 0; $sumPass = 0; $sumFail = 0; $sumSkip = 0; $sumNA = 0
foreach ($s in $stages) {
    if ($null -eq $s.Counts) { continue }
    $sumTotal += $s.Counts.Total; $sumPass += $s.Counts.Pass
    $sumFail += $s.Counts.Fail; $sumSkip += $s.Counts.Skip; $sumNA += $s.Counts.NA
}

$failedStages = @($stages | Where-Object { $_.Status -eq 'FAIL' -or $_.Status -eq 'ERROR' })
$skippedStages = @($stages | Where-Object { $_.Status -eq 'SKIPPED' })

Write-Host ''
Write-Host ('  ' + ('═' * 72)) -ForegroundColor DarkCyan
Write-Host '  RESULT' -ForegroundColor Cyan
Write-Host ('  ' + ('═' * 72)) -ForegroundColor DarkCyan
Write-Host ''
Write-Host '  Stage           Status    Cases (P/F/S/N-A)          Time'
Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkGray
foreach ($s in $stages) {
    $col = switch ($s.Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'SKIPPED' { 'Yellow' } default { 'Red' } }
    $cases = '-'
    if ($null -ne $s.Counts) { $cases = "{0}/{1}/{2}/{3}" -f $s.Counts.Pass, $s.Counts.Fail, $s.Counts.Skip, $s.Counts.NA }
    Write-Host ("  {0} {1} {2} {3}" -f $s.Name.PadRight(15), $s.Status.PadRight(9), $cases.PadRight(26), ("$($s.Seconds)s")) -ForegroundColor $col
    if ($s.Reason) { Write-Host ("                  {0}" -f $s.Reason) -ForegroundColor DarkGray }
}
Write-Host ''
if ($sumTotal -gt 0) {
    Write-Host "  Cases total $sumTotal   " -NoNewline
    Write-Host "PASS $sumPass  " -ForegroundColor Green -NoNewline
    Write-Host "FAIL $sumFail  " -ForegroundColor $(if ($sumFail) { 'Red' } else { 'DarkGray' }) -NoNewline
    Write-Host "SKIP $sumSkip  " -ForegroundColor Yellow -NoNewline
    Write-Host "N-A $sumNA" -ForegroundColor DarkGray
}
Write-Host "  Wall clock  ${totalSeconds}s"
Write-Host ''

# The headline. It has to be readable from across the room and it must not overclaim.
if ($failedStages.Count -eq 0 -and $skippedStages.Count -eq 0) {
    Write-Host '  ┌──────────────────────────────────────────────────┐' -ForegroundColor Green
    Write-Host '  │   Everything ran, and everything passed          │' -ForegroundColor Green
    Write-Host '  └──────────────────────────────────────────────────┘' -ForegroundColor Green
}
elseif ($failedStages.Count -eq 0) {
    Write-Host '  ┌──────────────────────────────────────────────────┐' -ForegroundColor Yellow
    Write-Host '  │   All that ran passed - but not everything ran   │' -ForegroundColor Yellow
    Write-Host '  └──────────────────────────────────────────────────┘' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Everything that ran passed. These stages did not run:' -ForegroundColor Yellow
    foreach ($s in $skippedStages) { Write-Host "    - $($s.Name): $($s.Reason)" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '  A certification run needs all of them.' -ForegroundColor Yellow
}
else {
    Write-Host '  ┌──────────────────────────────────────────────────┐' -ForegroundColor Red
    Write-Host '  │   Some tests failed                              │' -ForegroundColor Red
    Write-Host '  └──────────────────────────────────────────────────┘' -ForegroundColor Red
    Write-Host ''
    foreach ($s in $failedStages) { Write-Host "    - $($s.Name): $($s.Reason)" -ForegroundColor Red }
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
[void]$md.AppendLine('')
[void]$md.AppendLine('## Stages')
[void]$md.AppendLine('')
[void]$md.AppendLine('| Stage | Status | PASS | FAIL | SKIP | N-A | Seconds | Reason | Report |')
[void]$md.AppendLine('|---|---|---|---|---|---|---|---|---|')
foreach ($s in $stages) {
    $p = '-'; $f = '-'; $sk = '-'; $na = '-'
    if ($null -ne $s.Counts) { $p = $s.Counts.Pass; $f = $s.Counts.Fail; $sk = $s.Counts.Skip; $na = $s.Counts.NA }
    $rep = '-'
    if ($s.Report) { $rep = Split-Path -Leaf $s.Report }
    [void]$md.AppendLine("| $($s.Name) | **$($s.Status)** | $p | $f | $sk | $na | $($s.Seconds) | $($s.Reason) | $rep |")
}
[void]$md.AppendLine('')
[void]$md.AppendLine('## Result')
[void]$md.AppendLine('')
if ($failedStages.Count -eq 0 -and $skippedStages.Count -eq 0) {
    [void]$md.AppendLine('**Everything ran, and everything passed.**')
}
elseif ($failedStages.Count -eq 0) {
    [void]$md.AppendLine('**All that ran passed - but not everything ran.** The stages below were left out, each with its reason. A missing stage is not a green one.')
    [void]$md.AppendLine('')
    foreach ($s in $skippedStages) { [void]$md.AppendLine("* $($s.Name): $($s.Reason)") }
}
else {
    [void]$md.AppendLine('**Some tests failed.** Each stage below links to its own report, where every failed case carries the bytes that were sent and received.')
    [void]$md.AppendLine('')
    foreach ($s in $failedStages) { [void]$md.AppendLine("* $($s.Name): $($s.Reason)") }
}

$combinedMd = Join-Path $ReportDir "AllTests_$stamp.md"
$combinedJson = Join-Path $ReportDir "AllTests_$stamp.json"
[System.IO.File]::WriteAllText($combinedMd, $md.ToString())
([pscustomobject]@{
        started  = $runStart.ToString('o')
        finished = $runEnd.ToString('o')
        seconds  = $totalSeconds
        settings = @{
            bdut = $Ip; traffic = $TrafficIp; reference = $ReferenceIp; console = $SerialPort
            profile = $RunProfile; quick = [bool]$Quick; destructive = [bool]$IncludeDestructive
            hardReset = [bool]$IncludeHardReset; multicast = $Multicast
        }
        totals   = @{ total = $sumTotal; pass = $sumPass; fail = $sumFail; skip = $sumSkip; na = $sumNA }
        stages   = @($stages)
        verdict  = $(if ($failedStages.Count -gt 0) { 'FAIL' } elseif ($skippedStages.Count -gt 0) { 'INCOMPLETE' } else { 'PASS' })
    }) | ConvertTo-Json -Depth 6 | Set-Content -Path $combinedJson -Encoding UTF8

Write-Host ''
Write-Host "  Combined report: $combinedMd" -ForegroundColor Cyan
Write-Host "  Combined data  : $combinedJson" -ForegroundColor DarkGray
Write-Host ''

if ($failedStages.Count -gt 0) { exit 1 }
if ($skippedStages.Count -gt 0) { exit 3 }
exit 0
