#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Run-Tests
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Run-Tests.ps1

<#
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
        ./Run-Tests.ps1 -What All -Ip 11.11.0.210 -BdutPa 1.1.10 -TrafficIp 11.11.0.126 -P2pTarget 1.1.7

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
    stage of -What All. Comma separated, e.g. 1.1.7,1.1.9.
.PARAMETER WitnessIp
    Devices/All: an interface with a hardware busmonitor that watches the line. Remembered; "none"
    switches the remembered one off. It must be neither -Ip nor the device under test.
.PARAMETER IsolatedNetwork
    Conformance/All: the rig is a network without a productive installation (TSSH 1.2.1). The system broadcast
    suite and the cases that send on 224.0.23.12 run only with it.
.PARAMETER ReadableGa
    Conformance/All: a group address with a readable group object of the device under test.
.PARAMETER TestGa
    Devices: group address(es) that only the device under test acts on. Not remembered, because
    it belongs to one target and a remembered value would be reused silently for another.
.PARAMETER Case
    Conformance/Devices: run only the case ids matching these wildcards, e.g. 'K-2.4.*'. A case that
    does not match is not executed and does not appear in the report.
.PARAMETER SerialPort
    Serial console of the device, for the hardening stage of -What All. The FTC client is
    driven over that console, so without it the stage cannot run. Empty = it is skipped.
.PARAMETER FtcTarget
    Individual address the FTC client works against during the hardening stage, e.g. 1.1.7.
.PARAMETER FtcPassword
    Password for the FTC target when it is built with OPENKNX_FTC_SECURITY. Without it the
    hardening cases that stage a file report SKIP with that reason.
.PARAMETER ReferenceIp
    Certified reference device, for -What Reference.
.PARAMETER Iterations
    Number of passes for -What Endurance.
.PARAMETER PowerGuard
    on | off. Rig power guard: checks the bench power relays before every stage and before the
    restart / "did not come back" results of the device cases, and enforces -ProtectedTargets.
    Empty = profile field powerGuard, else off.
.PARAMETER PowerRelayWrite
    Relay switch GAs, comma separated, e.g. 0/3/100,0/3/110. A GroupValue_Write 1 switches a relay on.
.PARAMETER PowerRelayStatus
    Relay status GAs, same order as -PowerRelayWrite, e.g. 0/3/101,0/3/111.
.PARAMETER PowerRelayVia
    IP of the interface every guard telegram goes through. Must not hang on the relays itself.
.PARAMETER ProtectedTargets
    Individual addresses that power the rig, e.g. 1.1.3. With the guard on, no restart, master reset,
    address, memory or property write is sent to them.
.PARAMETER PowerRelayFeeds
    Device under test IPs whose TP the relays cut, comma separated, e.g. 11.11.0.126. The FIRST
    -PowerRelayWrite GA must cut the TP of every device listed; -PowerRelayVia must not be listed.
    The KNX-fault cases of the Device state stage run only for an -Ip in this list.
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
    [ValidateSet('', 'Interface', 'Router')]
    [string]$Role = '',
    [ValidateSet('', 'yes', 'no')]
    [string]$Busmon = '',
    [string]$WitnessIp = '',      # second interface, put into busmonitor mode to watch the bus
    [string]$TestGa = '',         # group address(es) only the device under test acts on (D-21.1)
    [switch]$IsolatedNetwork,     # the rig is its own network segment (TSSH 1.2.1)
    [string]$ReadableGa = '',     # group address with a readable group object of the device under test
    [switch]$Guided,              # allow cases that need a hand at the device or in ETS to ask
    [switch]$IncludeDestructive,  # allow cases that change device state (each one restores it)
    [string]$Case = '',           # wildcard filter on case ids, e.g. 'K-2.4.*'; empty runs the whole selection
    [string]$TestProfile = '',    # a named profile from scripts/Test/Profiles - the reproducible way to run
                                  # NOT -Profile: $Profile is an automatic variable in PowerShell, and -RunProfile
                                  # (Full/ReadOnly/Safe) already means something else in the runners
    [string]$Multicast = '',      # routing multicast group; 224.0.23.12 is production and drops the routing suite
    [switch]$ListProfiles,        # print the profiles and exit
    [string]$SerialPort = '',
    [string]$FtcTarget = '',
    [string]$FtcPassword = '',
    [string]$ReferenceIp = '',
    [string]$Stages = '',         # restrict a combined run to these stages; empty = every stage
    [string]$ReferenceIps = '',   # several certified interfaces for the reference stage
    [string]$SpeedTarget = '',    # TP device that receives the throughput transfer
    [int]$SpeedKb = 0,            # payload per transfer mode; 0 lets the profile decide
    [int]$Iterations = 0,
    [ValidateSet('', 'on', 'off')]
    [string]$PowerGuard = '',     # rig power guard; empty = profile, else off
    [string]$PowerRelayWrite = '',
    [string]$PowerRelayStatus = '',
    [string]$PowerRelayVia = '',
    [string]$ProtectedTargets = '',
    [string]$PowerRelayFeeds = '',
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateFile = Join-Path $here '.last-run.json'
$profileDir = Join-Path $here 'Profiles'

function Show-Logo {
    . (Join-Path $PSScriptRoot 'lib/KnxLogo.ps1')
    Write-KnxLogo -Title 'OpenKNX test runner'
}

function Get-LastRun {
    if (-not (Test-Path $stateFile)) { return @{} }
    # -AsHashtable arrived with PowerShell 6; under Windows PowerShell 5.1 the parameter does not
    # exist, the call throws, and the catch below silently returned an empty state - the runner
    # then forgot every previous answer on exactly the platform it has to run on. Convert by hand.
    try {
        $o = Get-Content $stateFile -Raw | ConvertFrom-Json
        $h = @{}
        foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }
        return $h
    }
    catch { return @{} }
}

function Save-LastRun {
    param([hashtable]$Values)
    try { $Values | ConvertTo-Json | Set-Content -Path $stateFile -Encoding UTF8 } catch { }
}

function Get-TestProfiles {
    <#
    .SYNOPSIS
        Every profile in scripts/Test/Profiles, newest schema first.
    .DESCRIPTION
        A profile is what makes a run reproducible: the remembered answers in .last-run.json describe
        whatever was typed last, by whoever sat here. A profile is a named, reviewable file that says
        which rig it belongs to and what it promises to cover, and it travels with the repository.
    #>
    if (-not (Test-Path $profileDir)) { return @() }
    $out = @()
    foreach ($f in (Get-ChildItem -Path $profileDir -Filter '*.json' | Sort-Object Name)) {
        try { $o = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { Write-Host ("  profile $($f.Name) is not readable JSON - ignored") -ForegroundColor Yellow; continue }
        if (-not $o.PSObject.Properties.Match('name').Count) { continue }
        Add-Member -InputObject $o -NotePropertyName 'file' -NotePropertyValue $f.FullName -Force
        $out += $o
    }
    # NOT "return , $out": that hands the whole list to the caller as a single object, and a
    # foreach over it then runs once with the array - the display printed all three names in one line.
    return $out
}

function Get-ProfileField {
    <#
    .SYNOPSIS
        One field out of a profile section, or '' when the profile does not carry it.
    #>
    param($TestProfile, [string]$Section, [string]$Field)
    if ($null -eq $TestProfile -or -not $TestProfile.PSObject.Properties.Match($Section).Count) { return '' }
    $sec = $TestProfile.$Section
    if ($null -eq $sec -or -not $sec.PSObject.Properties.Match($Field).Count) { return '' }
    $v = $sec.$Field
    if ($null -eq $v) { return '' }
    return $v
}

function Format-PowerGuard {
    <#
    .SYNOPSIS
        One line for the rig power guard: 'off', or 'on - relays ... (status ...) via ..., protected ..., feeds ...'.
    #>
    param([string]$Guard, [string]$Write, [string]$Status, [string]$Via, [string]$Protected, [string]$Feeds = '')
    if ($Guard -ne 'on') { return 'off' }
    $line = "on - relays $(if ($Write) { $Write } else { '<none>' }) (status $(if ($Status) { $Status } else { '<none>' })) via $(if ($Via) { $Via } else { '<none>' })"
    if ($Protected) { $line += ", protected $Protected" }
    if ($Feeds) { $line += ", feeds $Feeds" }
    return $line
}

function Show-TestProfile {
    <#
    .SYNOPSIS
        Prints what a profile would run, before it runs it.
    #>
    param($TestProfile)
    Write-Host ''
    Write-Host ("  $($TestProfile.name)") -ForegroundColor Cyan
    if ($TestProfile.PSObject.Properties.Match('description').Count) {
        Write-Host ("    $($TestProfile.description)") -ForegroundColor DarkGray
    }
    Write-Host ''
    $rows = [ordered]@{}
    if ($TestProfile.PSObject.Properties.Match('what').Count) { $rows['Stage'] = $TestProfile.what }
    if ($TestProfile.PSObject.Properties.Match('stages').Count) { $rows['Stages'] = $TestProfile.stages }
    foreach ($pair in @(
        @{ k = 'Device under test'; s = 'device'; f = 'ip' }
        @{ k = 'Individual address'; s = 'device'; f = 'pa' }
        @{ k = 'Role'; s = 'device'; f = 'role' }
        @{ k = 'Hardware busmonitor'; s = 'device'; f = 'hardwareBusmonitor' }
        @{ k = 'Traffic interface'; s = 'rig'; f = 'trafficIp' }
        @{ k = 'Bus witness'; s = 'rig'; f = 'witnessIp' }
        @{ k = 'Point-to-point target'; s = 'rig'; f = 'p2pTarget' }
        @{ k = 'TP devices'; s = 'rig'; f = 'deviceTargets' }
        @{ k = 'Test group address'; s = 'rig'; f = 'testGa' }
        @{ k = 'Serial console'; s = 'rig'; f = 'serialPort' }
        @{ k = 'FTC target'; s = 'rig'; f = 'ftcTarget' }
        @{ k = 'Reference device'; s = 'rig'; f = 'referenceIp' }
        @{ k = 'Speed target'; s = 'rig'; f = 'speedTarget' }
        @{ k = 'Speed payload KB'; s = 'rig'; f = 'speedKb' }
        @{ k = 'Multicast group'; s = 'rig'; f = 'multicast' }
    )) {
        $v = Get-ProfileField $TestProfile $pair.s $pair.f
        if ("$v") { $rows[$pair.k] = "$v" }
    }
    $rows['Rig power guard'] = Format-PowerGuard -Guard "$(Get-ProfileField $TestProfile 'rig' 'powerGuard')" `
        -Write "$(Get-ProfileField $TestProfile 'rig' 'powerRelayWrite')" -Status "$(Get-ProfileField $TestProfile 'rig' 'powerRelayStatus')" `
        -Via "$(Get-ProfileField $TestProfile 'rig' 'powerRelayVia')" -Protected "$(Get-ProfileField $TestProfile 'rig' 'protectedTargets')" `
        -Feeds "$(Get-ProfileField $TestProfile 'rig' 'powerRelayFeeds')"
    $flags = @()
    if ((Get-ProfileField $TestProfile 'flags' 'guided') -eq $true) { $flags += 'guided' }
    if ((Get-ProfileField $TestProfile 'flags' 'includeDestructive') -eq $true) { $flags += 'destructive' }
    if ($flags.Count -gt 0) { $rows['Flags'] = ($flags -join ', ') }
    foreach ($k in $rows.Keys) { Write-Host ("    {0,-22} {1}" -f $k, $rows[$k]) }
    if ($TestProfile.PSObject.Properties.Match('requires').Count -and @($TestProfile.requires).Count -gt 0) {
        Write-Host ''
        Write-Host ("    promises to cover: " + (@($TestProfile.requires) -join ' ')) -ForegroundColor DarkGray
    }
    Write-Host ''
}

function Select-TestProfile {
    <#
    .SYNOPSIS
        Offers the profiles that fit the chosen stage and returns the one picked, or $null.
    #>
    param([string]$Stage, [array]$Profiles)
    $fit = @($Profiles | Where-Object { -not $_.PSObject.Properties.Match('what').Count -or $_.what -eq $Stage })
    if ($fit.Count -eq 0) { return $null }
    Write-Host ''
    Write-Host "  Profiles for $Stage" -ForegroundColor Cyan
    Write-Host '    A profile is the reproducible way to run: named settings, in a file, reviewable.' -ForegroundColor DarkGray
    Write-Host ''
    for ($i = 0; $i -lt $fit.Count; $i++) {
        $d = if ($fit[$i].PSObject.Properties.Match('description').Count) { $fit[$i].description } else { '' }
        Write-Host ("   [{0,2}] {1,-18} {2}" -f ($i + 1), $fit[$i].name, $d)
    }
    Write-Host ("   [ 0] {0,-18} {1}" -f 'none', 'ask me for every value, as before')
    Write-Host ''
    while ($true) {
        $raw = Read-Host '  >  profile'
        $a = if ($null -eq $raw) { '' } else { $raw.Trim() }
        if (-not $a -or $a -eq '0') { return $null }
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $fit.Count) {
            $chosen = $fit[$n - 1]
            Show-TestProfile -TestProfile $chosen
            $ok = Read-Host '  >  [Enter] run it, [n] pick another'
            if ($null -eq $ok -or $ok.Trim().ToLower() -ne 'n') { return $chosen }
            continue
        }
        $byName = @($fit | Where-Object { $_.name -ieq $a })
        if ($byName.Count -eq 1) { Show-TestProfile -TestProfile $byName[0]; return $byName[0] }
        Write-Host '    Not one of these.' -ForegroundColor Yellow
    }
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

if ($ListProfiles) {
    $ps = @(Get-TestProfiles)
    if ($ps.Count -eq 0) { Write-Host "  no profiles in $profileDir" -ForegroundColor Yellow; exit 0 }
    foreach ($pr in $ps) { Show-TestProfile -TestProfile $pr }
    exit 0
}

# ─── Profile, part one: a named profile decides the stage ───────────────────────
# Precedence for every value is: command line > profile > remembered > question. For the STAGE that
# had to be settled before the menu, or the remembered stage wins and the profile silently runs
# something else - measured: 'router-all' (stage All) ran the Devices stage because the last run had
# been a Devices run, and it ran it destructively.

$allProfiles = @(Get-TestProfiles)
$activeProfile = $null

if ($TestProfile) {
    $hit = @($allProfiles | Where-Object { $_.name -ieq $TestProfile })
    if ($hit.Count -ne 1) {
        Write-Host "  no profile named '$TestProfile' in $profileDir" -ForegroundColor Red
        if ($allProfiles.Count -gt 0) { Write-Host ("  known: " + ((@($allProfiles | ForEach-Object { $_.name })) -join ', ')) -ForegroundColor DarkGray }
        exit 3
    }
    $activeProfile = $hit[0]
    if (-not $What -and $activeProfile.PSObject.Properties.Match('what').Count) { $What = $activeProfile.what }
}

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

# ─── Profile ────────────────────────────────────────────────────────────────────
# Applied BEFORE the questions below: a value the profile carries is simply already set, so the
# prompt for it does not happen. Precedence is command line > profile > remembered > question -
# an explicit -Ip must always beat whatever a profile says, or a one-off run cannot be made.

if ($null -eq $activeProfile -and -not $Yes -and $What -ne 'Clean' -and $allProfiles.Count -gt 0) {
    $activeProfile = Select-TestProfile -Stage $What -Profiles $allProfiles
}

if ($null -ne $activeProfile) {
    if (-not $Ip)            { $Ip            = "$(Get-ProfileField $activeProfile 'device' 'ip')" }
    if (-not $BdutPa)        { $BdutPa        = "$(Get-ProfileField $activeProfile 'device' 'pa')" }
    if (-not $Role)          { $Role          = "$(Get-ProfileField $activeProfile 'device' 'role')" }
    if (-not $Busmon)        { $Busmon        = "$(Get-ProfileField $activeProfile 'device' 'hardwareBusmonitor')" }
    if (-not $TrafficIp)     { $TrafficIp     = "$(Get-ProfileField $activeProfile 'rig' 'trafficIp')" }
    if (-not $WitnessIp)     { $WitnessIp     = "$(Get-ProfileField $activeProfile 'rig' 'witnessIp')" }
    if (-not $P2pTarget)     { $P2pTarget     = "$(Get-ProfileField $activeProfile 'rig' 'p2pTarget')" }
    if (-not $DeviceTargets) { $DeviceTargets = "$(Get-ProfileField $activeProfile 'rig' 'deviceTargets')" }
    if (-not $TestGa)        { $TestGa        = "$(Get-ProfileField $activeProfile 'rig' 'testGa')" }
    if (-not $SerialPort)    { $SerialPort    = "$(Get-ProfileField $activeProfile 'rig' 'serialPort')" }
    if (-not $FtcTarget)     { $FtcTarget     = "$(Get-ProfileField $activeProfile 'rig' 'ftcTarget')" }
    if (-not $ReferenceIp)   { $ReferenceIp   = "$(Get-ProfileField $activeProfile 'rig' 'referenceIp')" }
    if (-not $ReferenceIps)  { $ReferenceIps  = "$(Get-ProfileField $activeProfile 'rig' 'referenceIps')" }
    # A profile may name the stages it wants. Without this a run is all-or-one: a TP profile would
    # either drag the whole KNXnet/IP suite along or shrink to a single stage.
    if (-not $Stages -and $activeProfile.PSObject.Properties.Match('stages').Count) { $Stages = [string]$activeProfile.stages }
    if (-not $SpeedTarget)   { $SpeedTarget   = "$(Get-ProfileField $activeProfile 'rig' 'speedTarget')" }
    if (-not $SpeedKb) {
        $kb = "$(Get-ProfileField $activeProfile 'rig' 'speedKb')"
        if ($kb -match '^\d+$') { $SpeedKb = [int]$kb }
    }
    if (-not $Multicast)     { $Multicast     = "$(Get-ProfileField $activeProfile 'rig' 'multicast')" }
    if (-not $PowerGuard) {
        # Checked here: assigning a value outside the ValidateSet would throw a binding error instead.
        $pg = "$(Get-ProfileField $activeProfile 'rig' 'powerGuard')"
        if ($pg -notin @('', 'on', 'off')) { Write-Host "  ABORT: profile field rig.powerGuard is '$pg' - it takes on or off. Nothing was started." -ForegroundColor Red; exit 3 }
        $PowerGuard = $pg
    }
    if (-not $PowerRelayWrite)  { $PowerRelayWrite  = "$(Get-ProfileField $activeProfile 'rig' 'powerRelayWrite')" }
    if (-not $PowerRelayStatus) { $PowerRelayStatus = "$(Get-ProfileField $activeProfile 'rig' 'powerRelayStatus')" }
    if (-not $PowerRelayVia)    { $PowerRelayVia    = "$(Get-ProfileField $activeProfile 'rig' 'powerRelayVia')" }
    if (-not $ProtectedTargets) { $ProtectedTargets = "$(Get-ProfileField $activeProfile 'rig' 'protectedTargets')" }
    if (-not $PowerRelayFeeds)  { $PowerRelayFeeds  = "$(Get-ProfileField $activeProfile 'rig' 'powerRelayFeeds')" }
    if (-not $Guided -and (Get-ProfileField $activeProfile 'flags' 'guided') -eq $true) { $Guided = [switch]$true }
    if (-not $IncludeDestructive -and (Get-ProfileField $activeProfile 'flags' 'includeDestructive') -eq $true) { $IncludeDestructive = [switch]$true }
    if ($Iterations -le 0) {
        $it = Get-ProfileField $activeProfile 'flags' 'iterations'
        if ("$it" -and [int]"$it" -gt 0) { $Iterations = [int]"$it" }
    }
    Write-Host ("  Profile    : {0}" -f $activeProfile.name) -ForegroundColor Green
}

# --- Rig power guard ---------------------------------------------------------------
# Off unless the parameter or the profile says on. On without a complete relay setup refuses to start.
if (-not $PowerGuard) { $PowerGuard = 'off' }
$powerGuardLine = Format-PowerGuard -Guard $PowerGuard -Write $PowerRelayWrite -Status $PowerRelayStatus -Via $PowerRelayVia -Protected $ProtectedTargets -Feeds $PowerRelayFeeds
if ($PowerGuard -eq 'on' -and $What -ne 'Clean') {
    $pgWrite = @($PowerRelayWrite -split '[,;\s]+' | Where-Object { $_ })
    $pgStatus = @($PowerRelayStatus -split '[,;\s]+' | Where-Object { $_ })
    $pgProt = @($ProtectedTargets -split '[,;\s]+' | Where-Object { $_ })
    $pgErr = @()
    if ($pgWrite.Count -eq 0) { $pgErr += 'no relay write GA (-PowerRelayWrite / rig.powerRelayWrite)' }
    if ($pgStatus.Count -eq 0) { $pgErr += 'no relay status GA (-PowerRelayStatus / rig.powerRelayStatus)' }
    if ($pgWrite.Count -ne $pgStatus.Count) { $pgErr += "$($pgWrite.Count) write GA(s) but $($pgStatus.Count) status GA(s) - they are paired by position" }
    foreach ($g in ($pgWrite + $pgStatus)) {
        if ($g -notmatch '^(\d{1,2})/(\d)/(\d{1,3})$' -or [int]$Matches[1] -gt 31 -or [int]$Matches[2] -gt 7 -or [int]$Matches[3] -gt 255) { $pgErr += "'$g' is not a three-level group address (0-31/0-7/0-255)" }
    }
    if (-not $PowerRelayVia) { $pgErr += 'no control interface (-PowerRelayVia / rig.powerRelayVia) - the traffic interface is not taken, it may hang on the relays itself' }
    elseif ($PowerRelayVia -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { $pgErr += "'$PowerRelayVia' is not an IPv4 address" }
    foreach ($t in $pgProt) {
        if ($t -notmatch '^(\d{1,2})\.(\d{1,2})\.(\d{1,3})$' -or [int]$Matches[1] -gt 15 -or [int]$Matches[2] -gt 15 -or [int]$Matches[3] -gt 255) { $pgErr += "'$t' in -ProtectedTargets is not an individual address (0-15.0-15.0-255)" }
    }
    $pgFeeds = @($PowerRelayFeeds -split '[,;\s]+' | Where-Object { $_ })
    foreach ($f in $pgFeeds) {
        if ($f -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$' -or @($Matches[1..4] | Where-Object { [int]$_ -gt 255 }).Count -gt 0) { $pgErr += "'$f' in -PowerRelayFeeds is not an IPv4 address" }
    }
    if ($PowerRelayVia -and $pgFeeds -contains $PowerRelayVia) { $pgErr += "-PowerRelayVia $PowerRelayVia is listed in -PowerRelayFeeds - the relay telegrams would go through an interface whose TP the relays cut" }
    if ($pgErr.Count -gt 0) {
        Write-Host ''
        Write-Host '  ABORT: the rig power guard is on, but its setup is incomplete:' -ForegroundColor Red
        foreach ($e in $pgErr) { Write-Host "    $e" -ForegroundColor Yellow }
        Write-Host '  Nothing was started. Complete it, or pass -PowerGuard off.' -ForegroundColor DarkGray
        Write-Host ''
        exit 3
    }
}
# Only the combined runner and the device runner carry the guard; say so for any other stage.
if ($PowerGuard -eq 'on' -and $What -notin @('All', 'Devices', 'Hardening')) { $powerGuardLine += " - not used by -What $What" }
if ($What -ne 'Clean') { Write-Host ("  Power guard: {0}" -f $powerGuardLine) -ForegroundColor $(if ($PowerGuard -eq 'on') { 'Green' } else { 'DarkGray' }) }

# ─── Rig ────────────────────────────────────────────────────────────────────────

function Test-ProfilePromises {
    <#
    .SYNOPSIS
        Refuses to start when a profile promises coverage it has not been given the inputs for.
    .DESCRIPTION
        "All" has to mean all. Today a run without -TestGa, -WitnessIp or -IncludeDestructive still
        started, ran for twenty minutes and reported PASS over 34 cases it never executed - the gap was
        visible only to somebody who counted the NOT-RUN rows afterwards. A profile states what it
        covers; if an input for that is missing, this says so before the first telegram, names the
        argument, and stops, twenty minutes earlier.
    #>
    param($TestProfile, [hashtable]$Values)
    if ($null -eq $TestProfile -or -not $TestProfile.PSObject.Properties.Match('requires').Count) { return }
    $missing = @()
    foreach ($req in @($TestProfile.requires)) {
        switch ($req) {
            '-BdutPa'              { if (-not $Values.BdutPa)        { $missing += "$req (individual address of the device under test)" } }
            '-TrafficIp'           { if (-not $Values.TrafficIp)     { $missing += "$req (second interface on the same TP line)" } }
            '-P2pTarget'           { if (-not $Values.P2pTarget)     { $missing += "$req (a device that answers point-to-point)" } }
            '-DeviceTargets'       { if (-not $Values.DeviceTargets) { $missing += "$req (the TP devices to judge)" } }
            '-TestGa'              { if (-not $Values.TestGa)        { $missing += "$req (a group address only the target acts on)" } }
            '-WitnessIp'           { if (-not $Values.WitnessIp)     { $missing += "$req (an interface with a hardware busmonitor to watch the line)" } }
            '-SerialPort'          { if (-not $Values.SerialPort)    { $missing += "$req (the device console the FTC client is driven over)" } }
            '-IncludeDestructive'  { if (-not $Values.IncludeDestructive) { $missing += "$req (the profile covers cases that change device state)" } }
            '-Guided'              { if (-not $Values.Guided)        { $missing += "$req (the profile covers cases that need a hand at the device)" } }
            '-Multicast'           { if (-not $Values.Multicast -or $Values.Multicast -eq '224.0.23.12') {
                                        $missing += "$req (a LAB group - on 224.0.23.12 the routing suite is dropped and section 6 never runs)" } }
            default                { }
        }
    }
    if ($missing.Count -eq 0) { return }
    Write-Host ''
    Write-Host "  Profile '$($TestProfile.name)' promises coverage this run cannot deliver:" -ForegroundColor Red
    foreach ($m in $missing) { Write-Host "    missing $m" -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '  Nothing was started. Either pass the arguments, or run a profile that promises less.' -ForegroundColor DarkGray
    Write-Host ''
    exit 3
}

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
    $BdutPa = if ($Yes -and $d) { $d } else { Read-Value -Prompt 'Device under test - individual address' -Why "e.g. 1.1.10; used to address it on the bus and to check the traffic source shares its line$(if ($fromDevice) { " - the device reports $fromDevice" })" -Default $d }
}
if (-not $TrafficIp -and $What -notin @('Features','Stress','Devices','Hardening','Clean')) {
    $d = Default-For 'TrafficIp'
    $TrafficIp = if ($Yes -and $d) { $d } else { Read-Value -Optional -Prompt 'Traffic source - IP of a SECOND interface' -Why 'puts telegrams on the bus so the "from KNX" cases can run. It MUST sit on the same TP line as the device under test, otherwise nothing it sends can arrive. Empty = those cases are skipped' -Default $d }
}
if (-not $P2pTarget -and $What -notin @('Features','Stress','Busmonitor','Devices','Hardening','Clean')) {
    $d = Default-For 'P2pTarget'
    $P2pTarget = if ($Yes -and $d) { $d } else { Read-Value -Optional -Prompt 'Point-to-point target - individual address' -Why 'any device on that line which answers a connection-oriented read, e.g. 1.1.7. Without it H-5.2.10 is skipped and the run says nothing about point-to-point' -Default $d }
}
if (-not $Role -and $What -in @('Features', 'All')) {
    # An OPERATOR input, deliberately not read from the device: the feature suite exists to catch a
    # device whose role does not match what it is supposed to be, and a role taken from the same
    # device would make that check confirm its own premise. Without it every run judged the target
    # against the interface profile, so a router failed on mask, families and busmonitor code.
    # Remembered PER DEVICE: one remembered role was applied to the next device, so a router run with
    # -Yes silently reused "Interface" from the interface run and failed on mask, families and busmon.
    $d = Default-For "Role@$Ip"
    if ($Yes -and -not $d) {
        Write-Host "  no role remembered for $Ip - pass -Role Interface or -Role Router" -ForegroundColor Red
        exit 3
    }
    $Role = if ($Yes -and $d) { $d } else { Read-Value -Prompt 'Product role - Interface or Router' -Why 'what this device is SUPPOSED to be; the feature suite checks mask and service families against it' -Default $d }
    if (@('Interface', 'Router') -notcontains $Role) { $Role = 'Interface' }
}
if (-not $Busmon -and $What -in @('Features', 'All')) {
    # Deliberately NOT derived from the role: whether a hardware busmonitor exists is a BUILD property
    # (OPENKNX_HW_BUSMON), and an interface can be built without one. Deriving it would manufacture the
    # very evidence the feature suite says must not be assumed.
    # Per device as well, and 'no' when nothing is remembered: with 'yes' the suite DEMANDS a
    # busmonitor tunnel, which failed a router that is built without one.
    $d = Default-For "Busmon@$Ip" 'no'
    $Busmon = if ($Yes -and $d) { $d } else { Read-Value -Prompt 'Hardware busmonitor expected - yes or no' -Why 'yes only when the firmware is built with OPENKNX_HW_BUSMON; the suite then requires a busmonitor tunnel to be accepted' -Default $d }
    if (@('yes', 'no') -notcontains $Busmon) { $Busmon = 'no' }
}
# "none" switches a remembered witness off on purpose; an empty value would take the remembered one.
$forgetWitness = ($WitnessIp -eq 'none')
if ($forgetWitness) { $WitnessIp = '' }
if (-not $WitnessIp -and -not $forgetWitness -and $What -in @('Devices', 'All')) {
    # A SECOND interface, in busmonitor mode. Without it the interface that sends is also the only
    # witness to what it sent, and anything it drops or invents stays invisible. It needs a hardware
    # busmonitor - an IP router refuses the busmonitor layer and cannot serve as one.
    $d = Default-For 'WitnessIp'
    $WitnessIp = if ($Yes) { $d } else { Read-Value -Optional -Prompt 'Bus witness - IP of an interface with a hardware busmonitor' -Why 'watches the line independently of the interface that sends. "none" = no witness; empty = the remembered one' -Default $d }
    if ($WitnessIp -eq 'none') { $WitnessIp = ''; $forgetWitness = $true }
}
if (-not $DeviceTargets -and $What -in @('Devices', 'All')) {
    $d = Default-For 'DeviceTargets'
    $optional = ($What -eq 'All')
    if ($Yes) { $DeviceTargets = $d }
    elseif ($optional) {
        $DeviceTargets = Read-Value -Optional -Prompt 'KNX devices on the line - individual addresses' `
                                    -Why 'e.g. 1.1.7,1.1.9. These are judged as KNX DEVICES against Volume 3 - transport layer, properties, robustness. The interface is only the window. Empty = that stage is skipped' -Default $d
    }
    else {
        $DeviceTargets = Read-Value -Prompt 'KNX devices on the line - individual addresses' `
                                    -Why 'e.g. 1.1.7,1.1.9. Each is judged as a KNX DEVICE against Volume 3, seen through the interface above' -Default $d
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
    $d = Default-For 'FtcTarget' '1.1.7'
    $FtcTarget = if ($Yes) { $d } else { Read-Value -Prompt 'FTC target - individual address' -Why 'the device the file-transfer client works against during hardening, e.g. 1.1.7. It has to be reachable on the bus' -Default $d }
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
# Role and Busmon are only determined for Features/All. Writing them unconditionally erased the
# remembered answer on every other run, so the next -Yes silently judged a router as an interface.
$rememberRole = if ($Role) { $Role } else { Default-For "Role@$Ip" }
$rememberBusmon = if ($Busmon) { $Busmon } else { Default-For "Busmon@$Ip" }
# Only a run that asked for a witness may change the remembered one; a Features run must not wipe it.
$rememberWitness = if ($forgetWitness) { '' } elseif ($WitnessIp) { $WitnessIp } else { Default-For 'WitnessIp' }
# Keep every remembered key, including the per-device ones of the OTHER devices.
$state = @{}
foreach ($k in $last.Keys) { $state[$k] = $last[$k] }
# Only a value this run actually determined may overwrite a remembered one. Writing the whole set
# unconditionally stored an empty string for every key the chosen stage never asks about: a Features
# run erased the device targets, the serial port and the FTC target, and a Clean run erased the device
# IP, so the next run with -Yes started without them and silently skipped what needs them.
foreach ($kv in @{ What = $rememberWhat; Ip = $Ip; BdutPa = $BdutPa; TrafficIp = $TrafficIp; P2pTarget = $P2pTarget;
                   DeviceTargets = $DeviceTargets; SerialPort = $SerialPort;
                   FtcTarget = $FtcTarget; ReferenceIp = $ReferenceIp }.GetEnumerator()) {
    if ($kv.Value) { $state[$kv.Key] = $kv.Value }
}
# The witness is the exception: "none" is an answer and has to be able to clear the remembered one.
$state['WitnessIp'] = $rememberWitness
if ($Iterations -gt 0) { $state['Iterations'] = "$Iterations" }
if ($rememberRole) { $state["Role@$Ip"] = $rememberRole }
if ($rememberBusmon) { $state["Busmon@$Ip"] = $rememberBusmon }
Save-LastRun $state

# ─── Run ────────────────────────────────────────────────────────────────────────

# ─── One run, one bundle ────────────────────────────────────────────────────────
# Reports/<What>_<stamp>/ holds every artifact the stages write, plus <What>_<stamp>.settings.json (what the run was
# given, to repeat it), <What>_<stamp>.json/.md (combined report: All, Hardening) and <What>_<stamp>.html.
# ─── The address the run will use must be the device's own ──────────────────────
# A remembered or profile-supplied address is a guess about which device answers at this IP; a stale one can name a device of
# the live installation. The reported address replaces a remembered, profile or prompted one; an explicit -BdutPa that differs aborts.
if ($Ip -and $BdutPa -and $What -ne 'Clean') {
    $reported = ''
    try {
        Import-Module (Join-Path $here 'lib/KnxTest.psm1') -Force -ErrorAction Stop
        $vd = Get-KnxDescription -Ip $Ip -TimeoutMs 2000
        if ($null -ne $vd -and $null -ne $vd.Device) { $reported = [string]$vd.Device.IndividualAddr }
    }
    catch { }
    if ($reported -and $reported -ne $BdutPa) {
        if ($PSBoundParameters.ContainsKey('BdutPa')) {
            Write-Host ''
            Write-Host "  ABORT: $Ip reports individual address $reported, but -BdutPa says $BdutPa." -ForegroundColor Red
            Write-Host '  One of them is a different device. Nothing was started.' -ForegroundColor Yellow
            Write-Host ''
            exit 3
        }
        Write-Host "  Address    : $Ip reports $reported - using that instead of the remembered $BdutPa" -ForegroundColor Yellow
        $BdutPa = $reported
    }
}

# ─── Production lines are off limits ────────────────────────────────────────────
# A profile may name the lines its rig owns. Anything the run would address outside them is a device
# that does not belong to the test: here line 1.1 is the isolated rig, 1.0.x and 2.0.x are the live installation.
if ($null -ne $activeProfile -and $activeProfile.PSObject.Properties.Match('safety').Count -and
    $activeProfile.safety.PSObject.Properties.Match('allowedLines').Count) {
    $allowed = @($activeProfile.safety.allowedLines)
    $offside = @()
    $check = @()
    if ($BdutPa)    { $check += @{ what = '-BdutPa'; pa = $BdutPa } }
    if ($P2pTarget) { $check += @{ what = '-P2pTarget'; pa = $P2pTarget } }
    if ($FtcTarget) { $check += @{ what = '-FtcTarget'; pa = $FtcTarget } }
    foreach ($t in @($DeviceTargets -split '[,;\s]+' | Where-Object { $_ })) { $check += @{ what = '-DeviceTargets'; pa = $t } }
    foreach ($c in $check) {
        $line = ($c.pa -split '\.')[0, 1] -join '.'
        if ($allowed -notcontains $line) { $offside += ("{0} {1} (line {2})" -f $c.what, $c.pa, $line) }
    }
    if ($offside.Count -gt 0) {
        Write-Host ''
        Write-Host "  ABORT: profile '$($activeProfile.name)' allows lines $($allowed -join ', ') - these are outside:" -ForegroundColor Red
        foreach ($o in $offside) { Write-Host "    $o" -ForegroundColor Yellow }
        Write-Host '  A test must not address a device it does not own. Nothing was started.' -ForegroundColor DarkGray
        Write-Host ''
        exit 3
    }
}

Test-ProfilePromises -TestProfile $activeProfile -Values @{
    BdutPa = $BdutPa; TrafficIp = $TrafficIp; P2pTarget = $P2pTarget; DeviceTargets = $DeviceTargets
    TestGa = $TestGa; WitnessIp = $WitnessIp; SerialPort = $SerialPort; Multicast = $Multicast
    IncludeDestructive = [bool]$IncludeDestructive; Guided = [bool]$Guided
}

$reportsRoot = Join-Path $here 'Reports'
$runStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runId = "{0}_{1}" -f $What, $runStamp
$bundleDir = Join-Path $reportsRoot $runId
if ($What -ne 'Clean') {
    [void](New-Item -ItemType Directory -Force -Path $bundleDir)
    # The password is deliberately NOT in here, and neither is anything derived from it.
    $settings = [ordered]@{
        runId       = $runId
        what        = $What
        started     = (Get-Date).ToString('o')
        host        = @{ user = $env:USER; machine = [System.Net.Dns]::GetHostName(); powershell = $PSVersionTable.PSVersion.ToString() }
        device      = [ordered]@{ ip = $Ip; pa = $BdutPa; role = $Role; hardwareBusmonitor = $Busmon }
        rig         = [ordered]@{ trafficIp = $TrafficIp; witnessIp = $WitnessIp; p2pTarget = $P2pTarget
                                  deviceTargets = $DeviceTargets; testGa = $TestGa; serialPort = $SerialPort
                                  ftcTarget = $FtcTarget; referenceIp = $ReferenceIp
                                  speedTarget = $SpeedTarget; speedKb = "$SpeedKb"
                                  powerGuard = $PowerGuard; powerRelayWrite = $PowerRelayWrite
                                  powerRelayStatus = $PowerRelayStatus; powerRelayVia = $PowerRelayVia
                                  protectedTargets = $ProtectedTargets; powerRelayFeeds = $PowerRelayFeeds
                                  powerGuardSummary = $powerGuardLine
                                  # Which stages this run covered at all. Without it a profile that
                                  # deliberately runs a subset (tp-all) reads as an incomplete full run.
                                  stages = $(if ($Stages) { $Stages } else { 'alle' }) }
        flags       = [ordered]@{ guided = [bool]$Guided; includeDestructive = [bool]$IncludeDestructive
                                  case = $Case; iterations = $Iterations; ftcPasswordGiven = [bool]$FtcPassword
                                  multicast = $Multicast; isolatedNetwork = [bool]$IsolatedNetwork; readableGa = $ReadableGa }
        profile     = $(if ($null -ne $activeProfile) { $activeProfile.name } else { '' })
        repo        = [ordered]@{ commit = (& git -C $here rev-parse --short HEAD 2>$null); branch = (& git -C $here rev-parse --abbrev-ref HEAD 2>$null) }
    }
    # Everything a run produces lives in the run's own folder, companions included. New-TestReport
    # looks here first and beside the folder second, so bundles written before this still render.
    if (-not (Test-Path $bundleDir)) { [void](New-Item -ItemType Directory -Force -Path $bundleDir) }
    $settings | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $bundleDir "$runId.settings.json") -Encoding UTF8
    Write-Host ("  Run id     : {0}" -f $runId) -ForegroundColor DarkGray
}

$common = @()
if ($Ip)         { $common += @('-Ip', $Ip) }
if ($BdutPa)     { $common += @('-BdutPa', $BdutPa) }
if ($TrafficIp)  { $common += @('-TrafficIp', $TrafficIp) }
if ($P2pTarget)  { $common += @('-P2pTarget', $P2pTarget) }
# Every entry point below except Clean and Stress takes -ReportDir and writes into this run's bundle;
# the branches that build their own argument list add it themselves.
if ($What -notin @('Clean', 'Stress')) { $common += @('-ReportDir', $bundleDir) }
# Off forwards nothing: the runners then neither read nor write a relay and enforce no protected target.
$powerArgs = @()
if ($PowerGuard -eq 'on') {
    $powerArgs = @('-PowerGuard', 'on', '-PowerRelayWrite', $PowerRelayWrite, '-PowerRelayStatus', $PowerRelayStatus, '-PowerRelayVia', $PowerRelayVia)
    if ($ProtectedTargets) { $powerArgs += @('-ProtectedTargets', $ProtectedTargets) }
}

$runners = Join-Path $here 'runners'
# The case filter reaches the two runners that have it. Accepting it for a combined run and then
# running everything for ten minutes would be worse than saying so.
if ($Case -and $What -notin @('Conformance', 'Devices')) {
    Write-Host "  -Case works with -What Conformance and -What Devices, not with $What" -ForegroundColor Red
    exit 3
}
switch ($What) {
    'Conformance' { $script = Join-Path $runners 'Invoke-Conformance.ps1'; $argv = $common
                    if ($IncludeDestructive) { $argv += '-IncludeDestructive' }
                    if ($Multicast) { $argv += @('-Multicast', $Multicast) }
                    if ($Case) { $argv += @('-Case', $Case) }
                    if ($WitnessIp) { $argv += @('-WitnessIp', $WitnessIp) }
                    if ($IsolatedNetwork) { $argv += '-IsolatedNetwork' }
                    if ($ReadableGa) { $argv += @('-ReadableGa', $ReadableGa) } }
    'All'         { $script = Join-Path $runners 'Invoke-AllTests.ps1';    $argv = $common + @('-RunId', $runId)
                    # Invoke-AllTests defaults to profile Safe, and the conformance stage grants
                    # destructive cases only under Full - without this the flag was accepted here and
                    # every destructive conformance case was skipped anyway. Safe and Full differ in
                    # nothing else (Invoke-Conformance.ps1:401).
                    if ($IncludeDestructive) { $argv += @('-RunProfile', 'Full') }
                    if ($Multicast) { $argv += @('-Multicast', $Multicast) }
                    if ($Role -eq 'Router') { $argv += '-ExpectRouting' }
                    if ($Busmon -eq 'yes')  { $argv += '-ExpectBusmonitor' }
                    if ($DeviceTargets) { $argv += @('-DeviceTargets', $DeviceTargets) }
                    if ($WitnessIp)     { $argv += @('-WitnessIp', $WitnessIp) }
                    if ($TestGa)        { $argv += @('-TestGa', $TestGa) }
                    if ($IsolatedNetwork) { $argv += '-IsolatedNetwork' }
                    if ($ReadableGa)    { $argv += @('-ReadableGa', $ReadableGa) }
                    if ($Guided)        { $argv += '-Guided' }
                    if ($IncludeDestructive) { $argv += '-IncludeDestructive' }
                    if ($SerialPort)    { $argv += @('-SerialPort', $SerialPort) }
                    if ($FtcTarget)     { $argv += @('-FtcTarget', $FtcTarget) }
                    if ($FtcPassword)   { $argv += @('-FtcPassword', $FtcPassword) }
                    if ($ReferenceIp)   { $argv += @('-ReferenceIp', $ReferenceIp) }
                    if ($ReferenceIps)  { $argv += @('-ReferenceIps', $ReferenceIps) }
                    if ($Stages)        { $argv += @('-Stage', $Stages) }
                    if ($SpeedTarget)   { $argv += @('-SpeedTarget', $SpeedTarget) }
                    if ($SpeedKb -gt 0) { $argv += @('-SpeedKb', "$SpeedKb") }
                    $argv += $powerArgs
                    # Only the combined runner hosts the Device state stage that reads it.
                    if ($PowerGuard -eq 'on' -and $PowerRelayFeeds) { $argv += @('-PowerRelayFeeds', $PowerRelayFeeds) } }
    'Hardening'   { $script = Join-Path $runners 'Invoke-AllTests.ps1'
                    # Driven through the same runner as the combined run, restricted to one
                    # stage, so the stage behaves identically whether it runs alone or in All.
                    $argv = @('-Stage', 'Hardening', '-SerialPort', $SerialPort, '-ReportDir', $bundleDir, '-RunId', $runId)
                    if ($Ip)        { $argv += @('-Ip', $Ip) }
                    if ($FtcTarget)   { $argv += @('-FtcTarget', $FtcTarget) }
                    if ($FtcPassword) { $argv += @('-FtcPassword', $FtcPassword) }
                    $argv += $powerArgs }
    'Clean'       { $script = Join-Path $here 'Tools/Clear-Reports.ps1'
                    # No rig arguments: this one never talks to a device. It lists what it
                    # found and asks before removing anything.
                    $argv = @() }
    'Devices'     { $script = Join-Path $runners 'Invoke-DeviceTests.ps1'
                    $argv = @('-Ip', $Ip, '-Targets', $DeviceTargets, '-ReportDir', $bundleDir)
                    if ($WitnessIp) { $argv += @('-WitnessIp', $WitnessIp) }
                    if ($TestGa) { $argv += @('-TestGa', $TestGa) }
                    if ($Guided) { $argv += '-Guided' }
                    if ($IncludeDestructive) { $argv += '-IncludeDestructive' }
                    if ($Case) { $argv += @('-Case', $Case) }
                    if ($TrafficIp) { $argv += @('-TrafficIp', $TrafficIp) }
                    $argv += $powerArgs }
    'Endurance'   { $script = Join-Path $runners 'Invoke-Endurance.ps1';   $argv = $common + @('-Iterations', $Iterations) }
    'Reference'   { $script = Join-Path $runners 'Compare-Reference.ps1';  $argv = $common + @('-ReferenceIp', $ReferenceIp) }
    'Stress'      { $script = $null }
    'Busmonitor'  { $script = Join-Path $here 'Features/Test-Busmonitor.ps1'
                    $argv = @('-Ip', $Ip, '-ReportDir', $bundleDir)
                    if ($TrafficIp) { $argv += @('-TrafficIp', $TrafficIp) } }
    'Features'    { $script = Join-Path $here 'Features/Test-Features.ps1'
                    $argv = @('-Ip', $Ip, '-ReportDir', $bundleDir)
                    if ($TrafficIp) { $argv += @('-TrafficIp', $TrafficIp) }
                    if ($Role -eq 'Router') { $argv += '-ExpectRouting' }
                    if ($Busmon -eq 'yes')  { $argv += '-ExpectBusmonitor' } }
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

# The HTML report is not an extra step somebody has to remember - it is how a run ends.
if ($What -notin @('Clean', 'Stress')) {
    $builder = Join-Path $here 'Tools/New-TestReport.ps1'
    # Stage reports only: the settings and the combined summary of this run live in the bundle too, and
    # counting them made every bundle look like it held run data.
    $haveData = @(Get-ChildItem -Path $bundleDir -Filter '*.json' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "$runId.settings.json" -and $_.Name -ne "$runId.json" }).Count -gt 0
    if ((Test-Path $builder) -and $haveData) {
        try {
            & pwsh -NoProfile -File $builder -ReportDir $bundleDir | Out-Null
            $html = Join-Path $bundleDir ($runId + '.html')
            if (Test-Path $html) { Write-Host ("  Report     : {0}" -f $html) -ForegroundColor DarkGray }
            else { Write-Host '  (the HTML report was not written - the bundle holds no usable run data)' -ForegroundColor Yellow }
        }
        catch { Write-Host "  (the HTML report could not be built: $($_.Exception.Message))" -ForegroundColor Yellow }
    }
}

Write-Host ''
if ($What -eq 'Clean') {
    if ($code -ne 0) { Write-Host '  Some files could not be removed - see above.' -ForegroundColor Red }
}
elseif ($code -eq 0) { Write-Host '  RESULT: everything green.' -ForegroundColor Green }
# Exit 3 from Invoke-AllTests (All, Hardening) says "not all of it ran or was proven" - no case failed.
# Every other runner uses it to abort: the device does not answer, no tunnel, a run without a report.
elseif ($code -eq 3 -and $What -in @('All', 'Hardening')) { Write-Host '  RESULT: incomplete (exit 3) - no case failed, but not everything ran or was proven.' -ForegroundColor Yellow }
elseif ($code -eq 3) { Write-Host '  RESULT: aborted (exit 3) - a run ended without its report; the reason is printed above.' -ForegroundColor Yellow }
else { Write-Host "  RESULT: failures present (exit $code) - the report lists every case with its reason." -ForegroundColor Red }
if ($What -ne 'Clean') {
    Write-Host "  Run bundle : $bundleDir" -ForegroundColor DarkGray
    Write-Host "  Settings   : $(Join-Path $bundleDir ($runId + '.settings.json'))" -ForegroundColor DarkGray
}
Write-Host ''
exit $code
