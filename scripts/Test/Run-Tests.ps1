#!/usr/bin/env pwsh
<#
Open ■
┬────┴  Run-Tests
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: scripts/Test/Run-Tests.ps1

.SYNOPSIS
    The single entry point. Asks what to test, asks for the rig, runs it, reports.

.DESCRIPTION
    Everything else under scripts/Test is called from here. Each question explains in one
    line what the value is for and why it matters, because the two mistakes that cost the
    most time were a traffic source on a foreign TP line and a missing point-to-point
    target - both silent, both only visible minutes later in a red report.

    Answers are remembered in .last-run.json next to this script and offered as defaults.

    Any parameter given on the command line is used as-is and not asked for, so the script
    stays usable unattended:
        ./Run-Tests.ps1 -What All -Ip 11.11.0.210 -BdutPa 5.0.10 -TrafficIp 11.11.0.126 -P2pTarget 5.0.3

.PARAMETER What
    Conformance, Features, All, Endurance, Reference. Asked for when omitted.
.PARAMETER Ip
    Device under test.
.PARAMETER BdutPa
    Individual address of the device under test.
.PARAMETER TrafficIp
    Second interface that puts telegrams on the bus. Must sit on the BDUT's TP line.
.PARAMETER P2pTarget
    A device on that line which answers point-to-point requests.
.PARAMETER DeviceTargets
    Individual addresses of the TP devices to judge, for -What Devices and for the device
    stage of -What All. Comma separated, e.g. 5.0.3,5.0.9.
.PARAMETER SerialPort
    Serial console of the device, for the hardening stage of -What All. The FTC client is
    driven over that console, so without it the stage cannot run. Empty = it is skipped.
.PARAMETER FtcTarget
    Individual address the FTC client works against during the hardening stage, e.g. 5.0.3.
.PARAMETER FtcPassword
    Password for the FTC target when it is built with OPENKNX_FTC_SECURITY. Without it the
    hardening cases that stage a file report SKIP with that reason.
.PARAMETER ReferenceIp
    Certified reference device, for -What Reference.
.PARAMETER Iterations
    Number of passes for -What Endurance.
.PARAMETER Yes
    Take the remembered defaults for everything and do not ask.
#>

[CmdletBinding()]
param(
    [ValidateSet('Conformance', 'Features', 'All', 'Endurance', 'Reference', 'Stress', 'Busmonitor', 'Devices', 'Hardening', 'Clean')]
    [string]$What = '',
    [string]$Ip = '',
    [string]$BdutPa = '',
    [string]$TrafficIp = '',
    [string]$P2pTarget = '',
    [string]$DeviceTargets = '',
    [string]$SerialPort = '',
    [string]$FtcTarget = '',
    [string]$FtcPassword = '',
    [string]$ReferenceIp = '',
    [int]$Iterations = 0,
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateFile = Join-Path $here '.last-run.json'

function Show-Logo {
    Write-Host ''
    Write-Host '  Open ■' -ForegroundColor Green
    Write-Host '  ┬────┴  OpenKNX test runner' -ForegroundColor Green
    Write-Host '  ■ KNX   2026 OpenKNX - Erkan Çolak' -ForegroundColor DarkGray
    Write-Host ''
}

function Get-LastRun {
    if (-not (Test-Path $stateFile)) { return @{} }
    try { return (Get-Content $stateFile -Raw | ConvertFrom-Json -AsHashtable) } catch { return @{} }
}

function Save-LastRun {
    param([hashtable]$Values)
    try { $Values | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8 } catch { }
}

function Read-Value {
    <#
    .SYNOPSIS
        Asks for one value, showing what it is for and the remembered default.
    #>
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Why,
        [string]$Default = '',
        [switch]$Optional
    )
    Write-Host ''
    Write-Host "  $Prompt" -ForegroundColor Cyan
    Write-Host "    $Why" -ForegroundColor DarkGray
    while ($true) {
        $shown = if ($Default) { " [$Default]" } else { '' }
        $raw = Read-Host "  >$shown"
        $answer = if ($null -eq $raw) { '' } else { $raw.Trim() }
        if (-not $answer) { $answer = $Default }
        if ($answer) { return $answer }
        if ($Optional) { return '' }
        Write-Host '    A value is needed here.' -ForegroundColor Yellow
    }
}

function Read-Choice {
    <#
    .SYNOPSIS
        Shows the test stages grouped by what they judge, and reads the choice.
    .DESCRIPTION
        The list grew one entry at a time and ended up as nine equal-looking lines in which
        "Conformance" and "Devices" read as siblings although one judges the interface and
        the other judges what hangs off it. Grouping says which question each stage answers,
        so the choice can be made without knowing the suite.

        A Group on an entry starts a new heading; entries without one continue the previous
        group. Numbering runs across the whole list, so a group can be reordered without
        changing what [4] means to muscle memory - as long as the entries keep their order.
    #>
    param([Parameter(Mandatory)][array]$Options, [string]$Default = '')
    Write-Host ''
    Write-Host '  What do you want to test?' -ForegroundColor Cyan
    $group = ''
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $o = $Options[$i]
        if ($o.ContainsKey('Group') -and $o.Group -ne $group) {
            $group = $o.Group
            Write-Host ''
            Write-Host ("  $group") -ForegroundColor DarkCyan
        }
        $mark = if ($o.Key -ieq $Default) { '*' } else { ' ' }
        # {1,2} so [10] lines up under [9] instead of pushing every column one to the right.
        Write-Host ("   {0}[{1,2}] {2,-12} {3,-9} {4}" -f $mark, ($i + 1), $o.Key, $o.Time, $o.Why)
    }
    Write-Host ''
    while ($true) {
        $shown = if ($Default) { " [$Default]" } else { '' }
        $rawChoice = Read-Host "  >$shown"
        $a = if ($null -eq $rawChoice) { '' } else { $rawChoice.Trim() }
        if (-not $a -and $Default) { return $Default }
        if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $Options.Count) { return $Options[[int]$a - 1].Key }
        $match = $Options | Where-Object { $_.Key -ieq $a }
        if ($match) { return $match.Key }
        Write-Host '    Pick a number from the list.' -ForegroundColor Yellow
    }
}

Show-Logo
$last = Get-LastRun

# ─── What ───────────────────────────────────────────────────────────────────────

if (-not $What) {
    if ($Yes -and $last.ContainsKey('What')) { $What = $last.What }
    else {
        # The durations are the ones measured on this rig, not estimates: the old list
        # promised 30 s for a stage that takes 6 and 1 min for one that takes 2.5, and a
        # wrong duration is what makes someone start a run they then interrupt.
        $What = Read-Choice -Default $(if ($last.ContainsKey('What')) { $last.What } else { 'All' }) -Options @(
            @{ Group = 'Everything, one report';       Key = 'All';         Time = '~10 min'; Why = 'every stage below plus the legacy scripts' }

            @{ Group = 'The interface itself';         Key = 'Conformance'; Time = '~4 min';  Why = 'KNXnet/IP against the KNX test specification, sections 3 to 8' }
            @{                                         Key = 'Features';    Time = '~10 s';   Why = 'behaviour no specification prescribes - tunnel pool, busmonitor' }
            @{                                         Key = 'Busmonitor';  Time = '~2.5 min';Why = 'edge cases - does it hand over the bus UNCHANGED' }

            @{ Group = 'What hangs off it';            Key = 'Devices';     Time = '~30 s';   Why = 'the KNX devices on the line against Volume 3 - a NeoPixel, a Nuki' }
            @{                                         Key = 'Hardening';   Time = '~5 min';  Why = 'FTC file transfer and console, adversarially - over the device console' }

            @{ Group = 'Under pressure';               Key = 'Stress';      Time = '~8 min';  Why = 'load, leaks and misbehaving clients - what a protocol pass cannot show' }
            @{                                         Key = 'Endurance';   Time = 'long';    Why = 'N passes - tells STABLE from FLAKY, which one pass cannot' }

            @{ Group = 'Is it us, or is it the test?'; Key = 'Reference';   Time = '~10 min'; Why = 'the same cases against a certified device' }

            @{ Group = 'Housekeeping';                 Key = 'Clean';       Time = 'seconds';  Why = 'remove old reports - shows what will go and asks first' }
        )
    }
}

# ─── Rig ────────────────────────────────────────────────────────────────────────

function Default-For { param([string]$Key, [string]$Fallback = '') if ($last.ContainsKey($Key) -and $last[$Key]) { return $last[$Key] } return $Fallback }

if (-not $Ip -and $What -ne 'Clean') {
    $d = Default-For 'Ip'
    $Ip = if ($Yes -and $d) { $d } else { Read-Value -Prompt 'Device under test - IP address' -Why 'the device being judged; every result in the report is about this one' -Default $d }
}
if (-not $BdutPa -and $What -notin @('Features','Stress','Busmonitor','Devices','Hardening','Clean')) {
    $d = Default-For 'BdutPa'
    # Ask the DEVICE what its address is instead of trusting what was typed last time. A
    # remembered address survives a reflash, a swapped board and a new project, and a stale
    # one is silently destructive here: it makes the suite address a different device on the
    # bus, and it neuters the check that a device must not hand out its OWN address as a
    # tunnel address - that check compares against this value. Measured cost: one
    # DESCRIPTION_REQUEST.
    $fromDevice = ''
    if ($Ip) {
        try {
            Import-Module (Join-Path $here 'lib/KnxTest.psm1') -Force -ErrorAction Stop
            $desc = Get-KnxDescription -Ip $Ip -TimeoutMs 2000
            if ($null -ne $desc -and $null -ne $desc.Device) { $fromDevice = $desc.Device.IndividualAddr }
        }
        catch { }
    }
    if ($fromDevice) {
        if ($d -and $d -ne $fromDevice) {
            Write-Host ''
            Write-Host "  Note: $Ip reports $fromDevice, the remembered value was $d - using what the device says." -ForegroundColor Yellow
        }
        $d = $fromDevice
    }
    $BdutPa = if ($Yes -and $d) { $d } else { Read-Value -Prompt 'Device under test - individual address' -Why "e.g. 5.0.10; used to address it on the bus and to check the traffic source shares its line$(if ($fromDevice) { " - the device reports $fromDevice" })" -Default $d }
}
if (-not $TrafficIp -and $What -notin @('Features','Stress','Devices','Hardening','Clean')) {
    $d = Default-For 'TrafficIp'
    $TrafficIp = if ($Yes -and $d) { $d } else { Read-Value -Optional -Prompt 'Traffic source - IP of a SECOND interface' -Why 'puts telegrams on the bus so the "from KNX" cases can run. It MUST sit on the same TP line as the device under test, otherwise nothing it sends can arrive. Empty = those cases are skipped' -Default $d }
}
if (-not $P2pTarget -and $What -notin @('Features','Stress','Busmonitor','Devices','Hardening','Clean')) {
    $d = Default-For 'P2pTarget'
    $P2pTarget = if ($Yes -and $d) { $d } else { Read-Value -Optional -Prompt 'Point-to-point target - individual address' -Why 'any device on that line which answers a connection-oriented read, e.g. 5.0.3. Without it H-5.2.10 is skipped and the run says nothing about point-to-point' -Default $d }
}
if (-not $DeviceTargets -and $What -in @('Devices', 'All')) {
    $d = Default-For 'DeviceTargets'
    $optional = ($What -eq 'All')
    if ($Yes) { $DeviceTargets = $d }
    elseif ($optional) {
        $DeviceTargets = Read-Value -Optional -Prompt 'KNX devices on the line - individual addresses' `
                                    -Why 'e.g. 5.0.3,5.0.9. These are judged as KNX DEVICES against Volume 3 - transport layer, properties, robustness. The interface is only the window. Empty = that stage is skipped' -Default $d
    }
    else {
        $DeviceTargets = Read-Value -Prompt 'KNX devices on the line - individual addresses' `
                                    -Why 'e.g. 5.0.3,5.0.9. Each is judged as a KNX DEVICE against Volume 3, seen through the interface above' -Default $d
    }
}
if (-not $SerialPort -and $What -in @('All', 'Hardening')) {
    # "All" that quietly leaves a stage out is the kind of half-truth this runner exists to
    # avoid: the report then says "all that ran passed" and nobody remembers what did not.
    # The hardening stage drives the FTC client over the device's serial console, so ask -
    # and offer what is actually plugged into this machine rather than make it up.
    $d = Default-For 'SerialPort'
    if ($Yes) { $SerialPort = $d }
    else {
        Write-Host ''
        Write-Host '  Device serial console - port' -ForegroundColor Cyan
        Write-Host '    the hardening stage drives the FTC client over the device console. Each port is' -ForegroundColor DarkGray
        Write-Host '    asked who it is, so you pick a device rather than guess a path. Choosing none' -ForegroundColor DarkGray
        Write-Host '    skips that stage, and the report says which stage is missing and why.' -ForegroundColor DarkGray
        try {
            Import-Module (Join-Path $here 'lib/KnxSerial.psm1') -Force -ErrorAction Stop
            # "none" is a sensible answer inside All - that stage is then reported missing.
            # Chosen on its own it would leave nothing to run, so it is not offered there.
            $SerialPort = Select-KnxSerialDevice -Probe -Optional:($What -eq 'All') -Default $d
        }
        catch {
            Write-Host "    (serial scan unavailable: $($_.Exception.Message))" -ForegroundColor Yellow
            $SerialPort = Read-Value -Optional -Prompt 'Port' -Why 'type it, e.g. /dev/cu.usbmodem84101 or COM5' -Default $d
        }
    }
}
if (-not $FtcTarget -and $What -in @('All', 'Hardening')) {
    $d = Default-For 'FtcTarget' '5.0.3'
    $FtcTarget = if ($Yes) { $d } else { Read-Value -Prompt 'FTC target - individual address' -Why 'the device the file-transfer client works against during hardening, e.g. 5.0.3. It has to be reachable on the bus' -Default $d }
}
if ($What -eq 'Reference' -and -not $ReferenceIp) {
    $d = Default-For 'ReferenceIp'
    $ReferenceIp = if ($Yes -and $d) { $d } else { Read-Value -Prompt 'Certified reference device - IP address' -Why 'the same cases run against it; a case both devices fail is a test defect, not ours' -Default $d }
}
if ($What -eq 'Endurance' -and $Iterations -le 0) {
    $d = Default-For 'Iterations' '29'
    $Iterations = [int](if ($Yes) { $d } else { Read-Value -Prompt 'Number of passes' -Why '29 gives 95% confidence that a fault occurring in 10% of runs shows up at least once' -Default $d })
}

# Housekeeping is not a test choice: remembering it would offer "Clean" as the default the
# next time, and the answer to "[Clean]:" pressed by reflex is a deleted report directory.
$rememberWhat = if ($What -eq 'Clean') { Default-For 'What' 'All' } else { $What }
Save-LastRun @{ What = $rememberWhat; Ip = $Ip; BdutPa = $BdutPa; TrafficIp = $TrafficIp; P2pTarget = $P2pTarget; DeviceTargets = $DeviceTargets; SerialPort = $SerialPort; FtcTarget = $FtcTarget; ReferenceIp = $ReferenceIp; Iterations = "$Iterations" }

# ─── Run ────────────────────────────────────────────────────────────────────────

$common = @()
if ($Ip)         { $common += @('-Ip', $Ip) }
if ($BdutPa)     { $common += @('-BdutPa', $BdutPa) }
if ($TrafficIp)  { $common += @('-TrafficIp', $TrafficIp) }
if ($P2pTarget)  { $common += @('-P2pTarget', $P2pTarget) }

$runners = Join-Path $here 'runners'
switch ($What) {
    'Conformance' { $script = Join-Path $runners 'Invoke-Conformance.ps1'; $argv = $common }
    'All'         { $script = Join-Path $runners 'Invoke-AllTests.ps1';    $argv = $common
                    if ($DeviceTargets) { $argv += @('-DeviceTargets', $DeviceTargets) }
                    if ($SerialPort)    { $argv += @('-SerialPort', $SerialPort) }
                    if ($FtcTarget)     { $argv += @('-FtcTarget', $FtcTarget) }
                    if ($FtcPassword)   { $argv += @('-FtcPassword', $FtcPassword) } }
    'Hardening'   { $script = Join-Path $runners 'Invoke-AllTests.ps1'
                    # Driven through the same runner as the combined run, restricted to one
                    # stage, so the stage behaves identically whether it runs alone or in All.
                    $argv = @('-Stage', 'Hardening', '-SerialPort', $SerialPort)
                    if ($Ip)        { $argv += @('-Ip', $Ip) }
                    if ($FtcTarget)   { $argv += @('-FtcTarget', $FtcTarget) }
                    if ($FtcPassword) { $argv += @('-FtcPassword', $FtcPassword) } }
    'Clean'       { $script = Join-Path $here 'Tools/Clear-Reports.ps1'
                    # No rig arguments: this one never talks to a device. It lists what it
                    # found and asks before removing anything.
                    $argv = @() }
    'Devices'     { $script = Join-Path $runners 'Invoke-DeviceTests.ps1'
                    $argv = @('-Ip', $Ip, '-Targets', $DeviceTargets) }
    'Endurance'   { $script = Join-Path $runners 'Invoke-Endurance.ps1';   $argv = $common + @('-Iterations', $Iterations) }
    'Reference'   { $script = Join-Path $runners 'Compare-Reference.ps1';  $argv = $common + @('-ReferenceIp', $ReferenceIp) }
    'Stress'      { $script = $null }
    'Busmonitor'  { $script = Join-Path $here 'Features/Test-Busmonitor.ps1'
                    $argv = @('-Ip', $Ip)
                    if ($TrafficIp) { $argv += @('-TrafficIp', $TrafficIp) } }
    'Features'    { $script = Join-Path $here 'Features/Test-Features.ps1'
                    $argv = @('-Ip', $Ip)
                    if ($TrafficIp) { $argv += @('-TrafficIp', $TrafficIp) } }
}

Write-Host ''
Write-Host '  ────────────────────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host "  Running: $What" -ForegroundColor Green
if ($script) { Write-Host "  $((Split-Path -Leaf $script)) $($argv -join ' ')" -ForegroundColor DarkGray }
Write-Host '  ────────────────────────────────────────────────────────────' -ForegroundColor DarkGray

if ($What -eq 'Stress') {
    # The stress tool is one script with several sub-tests, so it is driven here rather than
    # wrapped. Only the non-destructive ones run by default. 'route' and 'load' need a device
    # that routes, so they are offered only when ROUTING is advertised. 'wreck' is excluded on
    # purpose: it can starve the device into the watchdog, and OpenKNX auto-erase then WIPES
    # the KNX configuration - that is a deliberate decision, not an oversight.
    $stress = Join-Path $here 'stress/Invoke-Stress.ps1'
    # leak and soak run until stopped, so they are bounded here - otherwise the stage never
    # ends. The durations are long enough to expose a leak (a rising HEAP or a failing probe
    # shows within a minute) and short enough that the whole stage stays usable.
    $tests = @(
        @{ Name = 'health';   Why = 'is KNX-IP alive at all' }
        @{ Name = 'discover'; Why = 'DESCRIPTION round-trips, DIB parsing' }
        @{ Name = 'robust';   Why = 'malformed frames must be ignored, device stays up' }
        @{ Name = 'tunnel';   Why = 'exhaust tunnels, free them, reconnect - slot leaks' }
        @{ Name = 'leak';     Why = 'cEMI negative-path flood - watch HEAP free on the console'; Extra = @('-Seconds', '90') }
        @{ Name = 'soak';     Why = 'sustained load, KNX-IP must stay responsive';               Extra = @('-Seconds', '120') }
    )
    $routes = $false
    try {
        Import-Module (Join-Path $here 'lib/KnxTest.psm1') -Force
        $d = Get-KnxDescription -Ip $Ip
        $routes = @($d.Families | Where-Object { $_.Name -match 'ROUTING' }).Count -gt 0
    } catch { }
    if ($routes) {
        $tests += @{ Name = 'route'; Why = 'routing flood into the TP TX queue' }
        $tests += @{ Name = 'load';  Why = 'multicast back-pressure, ROUTING_BUSY / LOST' }
        Write-Host '  Device advertises ROUTING - the routing stress tests are included.' -ForegroundColor DarkGray
    }
    else {
        Write-Host '  Device does not advertise ROUTING - skipping route/load (they need a router).' -ForegroundColor DarkGray
    }
    Write-Host "  'wreck' is never run from here - it can trigger the watchdog and wipe the KNX configuration." -ForegroundColor DarkGray

    $code = 0
    $failed = @()
    foreach ($t in $tests) {
        Write-Host ''
        Write-Host "  --- $($t.Name): $($t.Why)" -ForegroundColor Cyan
        $extra = if ($t.ContainsKey('Extra')) { $t.Extra } else { @() }
        & pwsh -NoProfile -File $stress $Ip $t.Name @extra
        if ($LASTEXITCODE -ne 0) { $failed += "$($t.Name) (exit $LASTEXITCODE)"; $code = 1 }
    }
    Write-Host ''
    if ($failed.Count -gt 0) { Write-Host "  Stress failures: $($failed -join ', ')" -ForegroundColor Red }
    else { Write-Host "  All $($tests.Count) stress tests passed." -ForegroundColor Green }
}
else {
    & pwsh -NoProfile -File $script @argv
    $code = $LASTEXITCODE
}

Write-Host ''
if ($What -eq 'Clean') {
    if ($code -ne 0) { Write-Host '  Some files could not be removed - see above.' -ForegroundColor Red }
}
elseif ($code -eq 0) { Write-Host '  RESULT: everything green.' -ForegroundColor Green }
else { Write-Host "  RESULT: failures present (exit $code) - the report lists every case with its reason." -ForegroundColor Red }
if ($What -ne 'Clean') { Write-Host "  Reports: $(Join-Path $here 'Reports')" -ForegroundColor DarkGray }
Write-Host ''
exit $code
