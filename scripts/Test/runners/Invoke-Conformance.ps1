#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Invoke-Conformance
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Invoke-Conformance.ps1

<#
.SYNOPSIS
    Runs the KNXnet/IP conformance suites against an OpenKNX IP-Interface or IP-Router
    and writes a Markdown + JSON report with a per-clause result.

.DESCRIPTION
    Test cases are numbered after the KNX Association prufvorschrift
    "08_TSSH System Conformance Testing - KNXnet/IP v1.3", so every line of the report
    can be read next to the specification. IDs carry the clause verbatim, e.g. H-5.3.5.

    Results are PASS, FAIL, SKIP (with reason) and N-A (with reason). A case that does
    not apply to this product is reported with its reason rather than omitted - an
    auditor must see what was not run and why.

    The runner refuses to start when the rig is wrong instead of turning a broken setup
    into a wall of red. It also enforces two hard safety rules that no switch overrides:
      * Routing tests never run on the production multicast group.
      * A device declared as production only ever sees the read-only profile.

.PARAMETER Ip
    IP address of the device under test (BDUT). Mandatory unless -SelfTest is given.

.PARAMETER Suite
    Which suites to run: Core, DevMgmt, Tunnelling, Routing, RemoteDiag, IpMedium, All.
    Default: All.

.PARAMETER Product
    Interface | Router | Auto. Auto (default) derives it from the Supported Service
    Families DIB: a device advertising ROUTING is a router, otherwise an interface.

.PARAMETER TrafficIp
    A SECOND KNXnet/IP interface on the same TP line, used to generate bus traffic and
    to drive the load switch. Required for every "from KNX" and bus-interrupt test case.

.PARAMETER ReferenceIp
    Optional certified reference device (e.g. the Siemens interface). When given, each
    executed case is also run against it and the comparison is written to the report.
    A case failing on the reference points at our test expectation, not at the BDUT.

.PARAMETER WitnessIp
    An interface on the same TP line with a hardware busmonitor. The router's TP acknowledges (BUSY) are seen
    only there; the cases that judge them are NOT-RUN without it.

.PARAMETER ReadableGa
    A group address with a readable group object of the device under test (A_GroupValue_Read is answered).
    Without it the case that reads it is NOT-RUN.

.PARAMETER LoadSwitchVia
    Interface used to switch the load switch. Defaults to -TrafficIp.

.PARAMETER LoadSwitchGa
    Group address of the load switch. TSSH section 1.2.2 specifies 1/1/50, but there is no
    default here on purpose: most benches have no load switch, and a case that fails
    because a rig element is absent tells you nothing about the device. Without it the
    bus-interrupt cases report SKIP with that reason.

.PARAMETER LoadSwitchPa
    Individual address of the load switch, e.g. 1.1.50. Opt-in, same reasoning.

.PARAMETER P2pTarget
    A real TP device to address point-to-point (H-5.2.10), e.g. 1.1.7. TSSH uses the load
    switch for this; any answering device on the test line does the job. Without it the
    case reports SKIP.

.PARAMETER Multicast
    Routing multicast group for the Routing suite. MUST NOT be the production group
    when a production installation shares the network - the runner enforces this.

.PARAMETER RunProfile
    Full        every applicable case (default)
    ReadOnly    only cases that neither write nor reconfigure - for a production device
    Safe        everything except destructive and reset cases

.PARAMETER IncludeHardReset
    Run H-7.5.9 Hard Reset. TSSH section 1.5 requires this case to be executed
    separately: it forces factory configuration and needs an ETS download afterwards.

.PARAMETER IncludeDestructive
    Allow cases that flood, exhaust or reset the device.

.PARAMETER IsolatedNetwork
    Declares that the rig is on its own ethernet segment with no production installation
    (TSSH 1.2.1). Only then may cases send on the production / system setup group 224.0.23.12:
    the Routing suite runs on it, and the Sbc suite (system broadcast) runs at all. Off by default.

.PARAMETER SkipSlow
    Skip the three cases that measure a timeout and therefore take minutes (H-3.5.3 at
    ~120 s, H-4.2.11 at ~40 s, H-5.2.7 at ~8 s). They are reported as SKIP with that
    reason, never silently dropped - a smoke run must not look like a full one.

.PARAMETER ReportDir
    Output directory. Default: scripts/Test/Reports.

.PARAMETER SelfTest
    Verify the library's own frame vectors offline and exit. No device needed.

.PARAMETER SkipRigCheck
    Skip the pre-flight rig verification. For debugging the suites themselves.

.EXAMPLE
    ./Invoke-Conformance.ps1 -SelfTest
.EXAMPLE
    ./Invoke-Conformance.ps1 -Ip 11.11.0.126 -TrafficIp 11.11.0.5 -Suite Core,DevMgmt
.EXAMPLE
    ./Invoke-Conformance.ps1 -Ip 11.11.0.126 -TrafficIp 11.11.0.5 -ReferenceIp 11.11.0.5
.EXAMPLE
    ./Invoke-Conformance.ps1 -Ip 11.11.0.3 -RunProfile ReadOnly
#>

[CmdletBinding()]
param(
    [string]$Ip = '',
    [int]$Port = 3671,
        [string[]]$Suite = @('All'),
    [ValidateSet('Interface', 'Router', 'Auto')]
    [string]$Product = 'Auto',
    [string]$TrafficIp = '',
    [string]$Case = '',   # wildcard filter on case ids, e.g. 'K-2.4.*'; empty runs the whole selection
    [string]$ReferenceIp = '',
    [string]$WitnessIp = '',
    [string]$ReadableGa = '',
    # Move the device onto the run's multicast group for section 6 and put it back afterwards.
    # Without it a device on another group simply loses section 6 - see the routing pre-check.
    [switch]$PrepareRouting,
    [string]$LoadSwitchVia = '',
    [string]$LoadSwitchGa = '',
    [string]$LoadSwitchPa = '',
    [string]$P2pTarget = '',
    [string]$BdutPa = '',
    [string]$Multicast = '224.0.23.12',
    [ValidateSet('Full', 'ReadOnly', 'Safe')]
    [string]$RunProfile = 'Full',
    [switch]$IncludeHardReset,
    [switch]$IncludeDestructive,
    [switch]$SkipSlow,
    [switch]$IsolatedNetwork,
    [string]$ReportDir = '',
    [switch]$SelfTest,
    [switch]$SkipRigCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)  # scripts/Test root
Import-Module (Join-Path $here 'lib/KnxTest.psm1') -Force

# Setting UTF-8 output is harmless on every platform, so it needs no $IsWindows guard - and
# that guard was itself the portability bug: 5.1 does not define the variable, and under
# Set-StrictMode reading it throws before the first test ever runs.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# The production KNXnet/IP routing group. Flooding it reaches every router on the LAN,
# including one bridging a production TP line - which is why the Routing suite refuses it.
$ProductionMulticast = '224.0.23.12'

# Declared up front: the finally around the suites reads these, and under Set-StrictMode reading a
# variable that was never assigned is a terminating error - which is exactly the path taken whenever
# the device did NOT have to be moved.
$script:RoutingRestoreBytes = $null
$script:RoutingRestoreGroup = ''
$script:GroupRoutingLockReason = ''

function Set-KnxRoutingGroup {
    <#
    .SYNOPSIS
        Writes PID_ROUTING_MULTICAST_ADDRESS, restarts the device and proves it took the value.
    .DESCRIPTION
        The stack reads the group ONCE per device lifetime (03_08_03 2.5.17), so a write without a
        restart leaves the device sending on the new group while still listening on the old one.
        The read-back therefore happens AFTER the restart, never before it.
    #>
    param(
        [Parameter(Mandatory)][string]$Ip,
        [int]$Port = 3671,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [int]$WaitSec = 90
    )
    $KC = Get-KnxConstants
    $c = $null
    try {
        $c = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $KC.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        if (-not $c.Ok) { return [pscustomobject]@{ Ok = $false; Reason = "no device management connection ($($c.StatusName))" } }
        $w = New-CemiMPropWrite -ObjectType $KC.ObjType.KNXNETIP_PARAM -PropertyId $KC.Pid.ROUTING_MULTICAST_ADDRESS -Data $Bytes
        $wr = Send-KnxDeviceConfiguration -Connection $c -Cemi $w -TimeoutMs 4000
        if ($null -eq $wr.Parsed -or $wr.Parsed.IsError) { return [pscustomobject]@{ Ok = $false; Reason = 'the device refused the write' } }
        [void](Send-KnxDeviceConfiguration -Connection $c -Cemi (New-CemiMReset) -TimeoutMs 4000)
    }
    catch { return [pscustomobject]@{ Ok = $false; Reason = $_.Exception.Message } }
    finally { if ($null -ne $c -and $c.Ok) { [void](Close-KnxConnection -Connection $c) } }

    Start-Sleep -Seconds 3
    $deadline = (Get-Date).AddSeconds($WaitSec)
    $alive = $false
    while ((Get-Date) -lt $deadline) {
        try { if (Test-KnxAlive -Ip $Ip -Port $Port -TimeoutMs 2000) { $alive = $true; break } } catch { }
        Start-Sleep -Seconds 2
    }
    if (-not $alive) { return [pscustomobject]@{ Ok = $false; Reason = "the device did not answer again within $WaitSec s after the restart" } }

    $got = Get-KnxRoutingGroup -Ip $Ip -Port $Port
    if (-not $got.Ok) { return [pscustomobject]@{ Ok = $false; Reason = "could not read the group back: $($got.Reason)" } }
    $want = ($Bytes -join '.')
    if ($got.Group -ne $want) { return [pscustomobject]@{ Ok = $false; Reason = "the device reports $($got.Group) after the restart, not $want" } }
    return [pscustomobject]@{ Ok = $true; Reason = ''; Group = $got.Group }
}

function Get-KnxGroupRoutingLock {
    <#
    .SYNOPSIS
        Reads whether the coupler is configured to route standard group telegrams at all.
    .DESCRIPTION
        03_05_01 4.5.6 p.93: PID_MAIN_LCGRPCONFIG (54) and PID_SUB_LCGRPCONFIG (55) on the Router
        object carry the handling of group addressed frames in bits 0-1 - 1 = UNLOCK (route all),
        2 = LOCK (route none), 3 = ROUT (the routing table decides). Measured on 11.11.0.126:
        54 = 0x0A -> LOCK, 55 = 0x0F -> ROUT, and exactly the locked direction is the one where
        every KNX-to-IP case failed. A device that is configured not to route is not a device that
        cannot route, so the suite must not report those as defects.
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671)
    $KC = Get-KnxConstants
    $c = $null
    $res = [ordered]@{ Ok = $false; Reason = ''; Main = $null; Sub = $null; MainLocked = $false; SubLocked = $false }
    try {
        $c = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $KC.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        if (-not $c.Ok) { $res.Reason = "no device management connection ($($c.StatusName))"; return [pscustomobject]$res }
        foreach ($pair in @(@(54, 'Main'), @(55, 'Sub'))) {
            $r = Read-KnxProperty -Connection $c -ObjectType 6 -PropertyId ([int]$pair[0])
            if ($null -eq $r.Parsed -or $r.Parsed.IsError -or $r.Parsed.Data.Length -lt 1) { continue }
            $v = [int]$r.Parsed.Data[0]
            $res[$pair[1]] = $v
            $res["$($pair[1])Locked"] = (($v -band 0x03) -eq 2)
        }
        $res.Ok = ($null -ne $res.Main -or $null -ne $res.Sub)
        if (-not $res.Ok) { $res.Reason = 'the router object does not answer PID 54/55' }
        return [pscustomobject]$res
    }
    catch { $res.Reason = $_.Exception.Message; return [pscustomobject]$res }
    finally { if ($null -ne $c -and $c.Ok) { [void](Close-KnxConnection -Connection $c) } }
}

function Get-KnxRoutingGroup {
    <#
    .SYNOPSIS
        Reads PID_ROUTING_MULTICAST_ADDRESS as dotted text.
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671)
    $KC = Get-KnxConstants
    $c = $null
    try {
        $c = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $KC.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        if (-not $c.Ok) { return [pscustomobject]@{ Ok = $false; Reason = "no device management connection ($($c.StatusName))" } }
        $r = Read-KnxProperty -Connection $c -ObjectType $KC.ObjType.KNXNETIP_PARAM -PropertyId $KC.Pid.ROUTING_MULTICAST_ADDRESS
        if ($null -eq $r.Parsed -or $r.Parsed.IsError -or $r.Parsed.Data.Length -lt 4) {
            return [pscustomobject]@{ Ok = $false; Reason = 'the property is not readable' }
        }
        return [pscustomobject]@{ Ok = $true; Reason = ''; Group = ($r.Parsed.Data[0..3] -join '.'); Bytes = [byte[]]$r.Parsed.Data[0..3] }
    }
    catch { return [pscustomobject]@{ Ok = $false; Reason = $_.Exception.Message } }
    finally { if ($null -ne $c -and $c.Ok) { [void](Close-KnxConnection -Connection $c) } }
}


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
    Write-KnxLogo -Title 'KNXnet/IP conformance'
}

function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * $Text.Length)) -ForegroundColor DarkGray
}

function Write-Fatal {
    param([string]$Text)
    Write-Host ''
    Write-Host "  ABORT: $Text" -ForegroundColor Red
    Write-Host ''
}

# ─── Self-test mode ─────────────────────────────────────────────────────────────

if ($SelfTest) {
    Show-Logo
    $st = Invoke-KnxSelfTest
    if (-not $st.Ok) {
        Write-Fatal "$($st.Failed) of $($st.Total) frame vectors are wrong - the suites would produce wrong results."
        exit 2
    }
    Write-Host '  Library verified. Device results produced with it can be trusted.' -ForegroundColor Green
    Write-Host ''
    exit 0
}

if (-not $Ip) {
    Show-Logo
    Write-Host '  -Ip is required (or use -SelfTest). See: Get-Help ./Invoke-Conformance.ps1 -Detailed' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

Show-Logo

# ─── Pre-flight: the library must be sound before it judges anything ────────────

Write-Section 'Pre-flight'
$st = Invoke-KnxSelfTest -Quiet
if (-not $st.Ok) {
    Write-Fatal "self-test failed ($($st.Failed)/$($st.Total) vectors) - refusing to judge a device with a broken library. Run -SelfTest for detail."
    exit 2
}
Write-Host "  Library self-test: $($st.Total)/$($st.Total) vectors OK" -ForegroundColor Green

# ─── Rig verification ───────────────────────────────────────────────────────────

if (-not $LoadSwitchVia) { $LoadSwitchVia = $TrafficIp }
if (-not $ReportDir) { $ReportDir = Join-Path $here 'Reports' }

$desc = $null
if (-not $SkipRigCheck) {
    if (-not (Test-KnxAlive -Ip $Ip -Port $Port -TimeoutMs 2000)) {
        Write-Fatal "BDUT $Ip does not answer a DESCRIPTION_REQUEST. Fix the rig - a dead device would make every case FAIL for the wrong reason."
        exit 3
    }
    Write-Host "  BDUT $Ip answers" -ForegroundColor Green

    $desc = Get-KnxDescription -Ip $Ip -Port $Port
    if ($null -eq $desc) {
        Write-Fatal "BDUT $Ip answered the liveness probe but no description could be decoded."
        exit 3
    }

    if ($TrafficIp) {
        if (Test-KnxAlive -Ip $TrafficIp -Port $Port -TimeoutMs 2000) {
            Write-Host "  Traffic interface $TrafficIp answers" -ForegroundColor Green

            # The traffic interface injects telegrams on ITS OWN TP line. If that is not the
            # BDUT's line, nothing it sends can ever reach the BDUT and every "from KNX" case
            # fails for a rig reason - six of them in one observed run, which cost 420 s and
            # looked like six device defects. Compare area/line and refuse rather than run.
            # This is checked by address, not by a hardcoded IP: an interface on a foreign
            # line is wrong here whatever its address, and a production coupler is exactly
            # the case that must never be used as a test traffic source.
            $tDesc = Get-KnxDescription -Ip $TrafficIp -Port $Port
            $tPa = if ($null -ne $tDesc -and $null -ne $tDesc.Device) { $tDesc.Device.IndividualAddr } else { $null }
            if (-not $tPa) {
                Write-Host "  Traffic interface $TrafficIp does not report an individual address - cannot verify it shares the BDUT line" -ForegroundColor Yellow
            }
            elseif ($BdutPa) {
                $tLine = ($tPa -split '\.')[0, 1] -join '.'
                $bLine = ($BdutPa -split '\.')[0, 1] -join '.'
                Write-Host "  Traffic interface PA $tPa (line $tLine), BDUT PA $BdutPa (line $bLine)"
                if ($tLine -ne $bLine) {
                    Write-Host ''
                    Write-Host "  ABORT: the traffic interface is on line $tLine, the BDUT on line $bLine." -ForegroundColor Red
                    Write-Host '  A telegram injected there can never reach the BDUT, so every "from KNX" case' -ForegroundColor Red
                    Write-Host '  would fail for a rig reason and look like a device defect.' -ForegroundColor Red
                    Write-Host "  Use an interface on line $bLine as -TrafficIp, or drop -TrafficIp to SKIP those cases." -ForegroundColor Yellow
                    Write-Host ''
                    exit 3
                }
            }
        }
        else {
            Write-Host "  Traffic interface $TrafficIp does NOT answer - 'from KNX' and bus-interrupt cases will SKIP" -ForegroundColor Yellow
            $TrafficIp = ''
            $LoadSwitchVia = ''
        }
    }
    else {
        Write-Host '  No -TrafficIp given - every "from KNX" and bus-interrupt case will SKIP' -ForegroundColor Yellow
    }

    if ($ReferenceIp) {
        # The reference is optional, so nothing about it may end the run. Test-KnxAlive does not just
        # return $false when the socket itself fails: with $ErrorActionPreference = 'Stop' a "No route
        # to host" from sendto is terminating, and it killed the whole conformance stage 0.9 s in,
        # costing 125 cases. Reaching the reference is a property of this host's routing, never a
        # result about the device under test.
        $refAlive = $false
        $refWhy = ''
        try { $refAlive = [bool](Test-KnxAlive -Ip $ReferenceIp -Port $Port -TimeoutMs 2000) }
        catch { $refAlive = $false; $refWhy = " ($($_.Exception.Message))" }
        if ($refAlive) {
            Write-Host "  Reference device $ReferenceIp answers" -ForegroundColor Green
        }
        else {
            Write-Host "  Reference device $ReferenceIp does NOT answer - cross-check disabled$refWhy" -ForegroundColor Yellow
            $ReferenceIp = ''
        }
    }
}

# ─── Product identification ─────────────────────────────────────────────────────

$isRouter = $false
$maskVersion = 'unknown'
$deviceName = 'unknown'
$devicePa = 'unknown'
$families = @()

if ($null -ne $desc) {
    $families = @($desc.Families)
    if ($null -ne $desc.Device) {
        $deviceName = $desc.Device.FriendlyName
        $devicePa = $desc.Device.IndividualAddr
    }
    foreach ($f in $families) { if ($f.Id -eq 0x05) { $isRouter = $true } }
}

# The mask comes from PID 83 over device management and does not depend on a DESCRIPTION_RESPONSE.
# Inside that guard, the one device this was written for - one that answers no description - kept
# printing 'unknown', which is the word the helper exists to replace.
$maskVersion = Get-KnxMaskVersionText -Ip $Ip -Port $Port

if ($Product -eq 'Interface') { $isRouter = $false }
if ($Product -eq 'Router')    { $isRouter = $true }
$productName = 'IP-Interface'
if ($isRouter) { $productName = 'IP-Router' }

if (-not $BdutPa -and $devicePa -ne 'unknown') { $BdutPa = $devicePa }
# One spelling for every comparison with addresses read from the device (e.g. the tunnel pool in H-5.3.4).
if ($BdutPa) {
    try { $BdutPa = ConvertFrom-KnxPa -Raw (ConvertTo-KnxPa -Address $BdutPa) }
    catch { throw "-BdutPa '$BdutPa' is not an individual address of the form area.line.device" }
}

Write-Section 'Device under test'
Write-Host "  Name          : $deviceName"
Write-Host "  Address       : $devicePa"
Write-Host "  Mask version  : $maskVersion"
Write-Host "  Role          : $productName" -ForegroundColor $(if ($isRouter) { 'Yellow' } else { 'Green' })
$famText = '(none decoded)'
if ($families.Count -gt 0) { $famText = (($families | ForEach-Object { "$($_.Name) v$($_.Version)" }) -join ', ') }
Write-Host "  Service famil.: $famText"

if ($Product -eq 'Auto' -and $null -eq $desc) {
    Write-Fatal 'cannot auto-detect the product without a description - pass -Product explicitly or fix the rig.'
    exit 3
}

# ─── Safety gates ───────────────────────────────────────────────────────────────

$wantSuites = Expand-ListArgument -Value $Suite -Allowed @('Core','DevMgmt','Tunnelling','Routing','Sbc','RemoteDiag','IpMedium','Tcp','Properties','V2','All') -Name 'Suite'
if ($wantSuites -contains 'All') { $wantSuites = @('Core', 'DevMgmt', 'Tunnelling', 'Routing', 'Sbc', 'RemoteDiag', 'IpMedium', 'Tcp', 'Properties', 'V2') }

if ($RunProfile -eq 'ReadOnly') {
    Write-Section 'Safety'
    Write-Host '  Profile ReadOnly: no write, reconfigure, reset, exhaust or flood case will run.' -ForegroundColor Yellow
    # Router only: on an interface section 6 is the negative test, H-6.NEG.1 reads and H-6.NEG.2 refuses ReadOnly itself.
    if ($wantSuites -contains 'Routing' -and $isRouter) {
        Write-Host '  Routing suite dropped - it always writes to the bus.' -ForegroundColor Yellow
        $wantSuites = @($wantSuites | Where-Object { $_ -ne 'Routing' })
    }
}

# Suites a gate refuses to start. They are handed to the run below so the report can name them;
# a dropped suite that only appears on the console is invisible in every artifact of the run.
$droppedSuites = @()

# On an interface section 6 is the negative test (H-6.NEG.1/2): the suite runs, the group machinery below is router only.
# A non-router reports 0.0.0.0 as its group, which must not be taken as a wrong group to rewrite.
if ($wantSuites -contains 'Routing' -and -not $isRouter) {
    Write-Section 'Routing'
    Write-Host "  Section 6 runs as the negative test - $Ip is judged as an interface, H-6.NEG.1/2 apply." -ForegroundColor DarkGray
}

# HARD gate: never emit on the production multicast group unless -IsolatedNetwork; the suite is DROPPED, the run goes on (no other suite reads -Multicast). An interface is not dropped here: H-6.NEG.2 refuses the production group itself.
# A routing run means something only on the group the device routes on; asked on another one every case fails for a rig reason. Read the group it uses and say so.
if ($wantSuites -contains 'Routing' -and $isRouter -and ($Multicast -ne $ProductionMulticast -or $IsolatedNetwork)) {
    $devGroup = ''
    $KC = Get-KnxConstants
    try {
        # $script:KnxConnType belongs to the MODULE, not to this script - reading it here left the
        # constant empty, the connect failed, and the silent catch below turned the whole guard into a
        # no-op. It ran the routing suite into eight failures that said nothing about the device.
        $mc = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $KC.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        if ($mc.Ok) {
            try {
                $rr = Read-KnxProperty -Connection $mc -ObjectType $KC.ObjType.KNXNETIP_PARAM `
                                       -PropertyId $KC.Pid.ROUTING_MULTICAST_ADDRESS
                if ($null -ne $rr.Parsed -and -not $rr.Parsed.IsError -and $rr.Parsed.Data.Length -ge 4) {
                    $devGroup = ($rr.Parsed.Data[0..3] -join '.')
                }
            }
            finally { [void](Close-KnxConnection -Connection $mc) }
        }
        else { Write-Host "  (could not read the device's routing group: $($mc.StatusName))" -ForegroundColor DarkGray }
    }
    catch {
        # Not swallowed: a guard that fails silently is worse than no guard, because the run then
        # looks as if the check had passed.
        Write-Host "  (the device's routing group could not be read: $($_.Exception.Message))" -ForegroundColor Yellow
    }
    $grpLock = Get-KnxGroupRoutingLock -Ip $Ip -Port $Port
    if ($grpLock.Ok -and ($grpLock.MainLocked -or $grpLock.SubLocked)) {
        $which = @()
        if ($grpLock.MainLocked) { $which += ('PID_MAIN_LCGRPCONFIG = 0x{0:X2}' -f [int]$grpLock.Main) }
        if ($grpLock.SubLocked)  { $which += ('PID_SUB_LCGRPCONFIG = 0x{0:X2}' -f [int]$grpLock.Sub) }
        Write-Section 'Coupler configuration'
        Write-Host "  The device is configured NOT to route standard group telegrams." -ForegroundColor Yellow
        Write-Host "  $($which -join ' , ') - bits 0-1 = 2 = GROUP_LOCK6FFF (03_05_01 4.5.6 p.93)." -ForegroundColor Yellow
        Write-Host '  The cases that need that direction will FAIL, and they should: as configured, the' -ForegroundColor Yellow
        Write-Host '  device does not fulfil the clause. The cause is recorded with each case so the' -ForegroundColor Yellow
        Write-Host '  report shows a configuration finding, not an unexplained defect.' -ForegroundColor Yellow
        $script:GroupRoutingLockReason = "the device is configured not to route standard group telegrams ($($which -join ', ') - GROUP_LOCK6FFF, 03_05_01 4.5.6 p.93); this is an ETS setting, not a device fault"
    }
    if ($devGroup -and $devGroup -ne $Multicast -and $PrepareRouting -and $IncludeDestructive) {
        Write-Section 'Routing preparation'
        Write-Host "  The device routes on $devGroup, this run uses $Multicast." -ForegroundColor Cyan
        Write-Host '  Moving it onto the run group for section 6 and back again afterwards.' -ForegroundColor Cyan
        $origBytes = ([System.Net.IPAddress]::Parse($devGroup)).GetAddressBytes()
        $newBytes = ([System.Net.IPAddress]::Parse($Multicast)).GetAddressBytes()
        $sw = Set-KnxRoutingGroup -Ip $Ip -Port $Port -Bytes $newBytes
        if ($sw.Ok) {
            Write-Host "  Device is on $Multicast and answering - section 6 will run." -ForegroundColor Green
            # A 15 s settle wait was tried here on the theory that the device has to re-announce its
            # multicast membership (this network has no IGMP querier). It changed nothing: H-6.1.1 was
            # PASS/FAIL/FAIL/PASS without it and FAIL/FAIL/PASS with it. Removed rather than kept as a
            # decoration - the intermittent failure is real and still unexplained.
            # Picked up by the finally block around the suites: whatever happens from here, the
            # device goes back to the group it was found on.
            $script:RoutingRestoreBytes = $origBytes
            $script:RoutingRestoreGroup = $devGroup
        }
        else {
            Write-Host "  Could not move the device: $($sw.Reason)" -ForegroundColor Red
            Write-Host '  Section 6 is dropped rather than run against a device that cannot hear it.' -ForegroundColor Yellow
            # It may have taken the write and failed the restart - put it back before giving up.
            [void](Set-KnxRoutingGroup -Ip $Ip -Port $Port -Bytes $origBytes)
            $wantSuites = @($wantSuites | Where-Object { $_ -ne 'Routing' })
            $droppedSuites += [pscustomobject]@{
                Suite  = '6 Routing'
                Reason = "the device could not be moved from $devGroup to $Multicast - $($sw.Reason)"
            }
        }
    }
    elseif ($devGroup -and $devGroup -ne $Multicast) {
        Write-Section 'Safety'
        Write-Host "  Routing suite DROPPED - the device routes on $devGroup, this run uses $Multicast." -ForegroundColor Yellow
        Write-Host '  Every case in section 6 would fail because nothing it sends reaches the device,' -ForegroundColor Yellow
        Write-Host '  and that would read as ten device defects.' -ForegroundColor Yellow
        Write-Host ''
        Write-Host "  Pass -PrepareRouting to move the device automatically and put it back," -ForegroundColor Cyan
        Write-Host "  or run with -Multicast $devGroup, or move the device to $Multicast yourself." -ForegroundColor Cyan
        Write-Host '  The move needs no ETS - PID 66 is writable over local device management:' -ForegroundColor DarkGray
        # A typo'd group would otherwise abort the run with a cast error while printing advice about it.
        $mcHex = ''
        $mcOct = @($Multicast -split '\.')
        if ($mcOct.Count -eq 4 -and -not (@($mcOct | Where-Object { $_ -notmatch '^\d{1,3}$' -or [int]$_ -gt 255 }).Count)) {
            $mcHex = (@($mcOct | ForEach-Object { '{0:X2}' -f [int]$_ }) -join '')
        }
        if ($mcHex) { Write-Host "    oknx -i $Ip prop write 11 1 66 1 $mcHex" -ForegroundColor DarkGray }
        Write-Host '  and the device must be RESTARTED afterwards: the stack reads the group once per' -ForegroundColor DarkGray
        Write-Host '  device lifetime (03_08_03 2.5.17), so without a reset it sends on the new group' -ForegroundColor DarkGray
        Write-Host '  and still listens on the old one.' -ForegroundColor DarkGray
        Write-Host '  (on the production group the suite is dropped for safety - see below).' -ForegroundColor DarkGray
        $wantSuites = @($wantSuites | Where-Object { $_ -ne 'Routing' })
        $droppedSuites += [pscustomobject]@{
            Suite  = '6 Routing'
            Reason = "the device routes on $devGroup while this run uses $Multicast - nothing the suite sends would reach it"
        }
    }
}

if ($IsolatedNetwork) {
    Write-Section 'Safety'
    Write-Host "  -IsolatedNetwork: cases may send on $ProductionMulticast (rig declared as its own segment)." -ForegroundColor Yellow
}

# The system broadcast cases send on the system setup group whatever the routing group is: opt-in only (router; N-A elsewhere).
if ($wantSuites -contains 'Sbc' -and $isRouter -and -not $IsolatedNetwork) {
    $wantSuites = @($wantSuites | Where-Object { $_ -ne 'Sbc' })
    $droppedSuites += [pscustomobject]@{
        Suite  = '6b System Broadcast'
        Reason = "sends on the system setup group $ProductionMulticast - pass -IsolatedNetwork once the rig is on its own segment"
    }
}

# Router only: on an interface H-6.NEG.2 refuses the production group itself, and H-6.NEG.1 sends nothing on a group.
if ($wantSuites -contains 'Routing' -and $isRouter -and $Multicast -eq $ProductionMulticast -and -not $IsolatedNetwork) {
    Write-Section 'Safety'
    Write-Host "  Routing suite DROPPED - it would emit on the production group $ProductionMulticast." -ForegroundColor Yellow
    Write-Host '  Every KNXnet/IP router on this LAN listens there, including one bridging a' -ForegroundColor Yellow
    Write-Host '  production TP line, which would carry the test traffic onto it.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  To run section 6, give the lab router its own group:  -Multicast 224.0.23.13' -ForegroundColor Cyan
    Write-Host '  or declare the rig isolated:                          -IsolatedNetwork' -ForegroundColor Cyan
    Write-Host '  TSSH section 1.2.1 also requires the rig on a separate ethernet segment.' -ForegroundColor DarkGray
    $wantSuites = @($wantSuites | Where-Object { $_ -ne 'Routing' })
    # Recorded, not only printed: a run whose section 6 never happened used to report
    # "conformance PASS" with nothing in the report saying the routing cases were missing.
    # The record is added once the run exists (below).
    $droppedSuites += [pscustomobject]@{
        Suite  = '6 Routing'
        Reason = "would emit on the production multicast group $ProductionMulticast - pass -Multicast 224.0.23.13 to give the lab its own group, or -IsolatedNetwork on an isolated rig"
    }
}

if ($IncludeHardReset) {
    Write-Section 'Safety'
    Write-Host '  H-7.5.9 Hard Reset is ENABLED.' -ForegroundColor Red
    Write-Host '  TSSH section 1.5: this forces factory configuration; the test client cannot' -ForegroundColor Yellow
    Write-Host '  restore the previous state. An ETS download is required afterwards.' -ForegroundColor Yellow
}

# ─── Build the run context ──────────────────────────────────────────────────────

$ctx = [pscustomobject]@{
    BdutIp             = $Ip
    Port               = $Port
    IsRouter           = $isRouter
    ProductName        = $productName
    BdutPa             = $BdutPa
    MaskVersion        = $maskVersion
    Families           = $families
    Description        = $desc
    TrafficIp          = $TrafficIp
    ReferenceIp        = $ReferenceIp
    WitnessIp          = $WitnessIp
    ReadableGa         = $ReadableGa
    LoadSwitchVia      = $LoadSwitchVia
    LoadSwitchGa       = $LoadSwitchGa
    LoadSwitchPa       = $LoadSwitchPa
    P2pTarget          = $P2pTarget
    Multicast          = $Multicast
    RunProfile         = $RunProfile
    IncludeHardReset   = [bool]$IncludeHardReset
    IncludeDestructive = [bool]$IncludeDestructive
    SkipSlow           = [bool]$SkipSlow
    IsolatedNetwork    = [bool]$IsolatedNetwork
    ReadOnly           = ($RunProfile -eq 'ReadOnly')
    AllowDestructive   = ([bool]$IncludeDestructive -and $RunProfile -eq 'Full')
    # Empty unless the coupler is configured to block group telegrams; section 6 uses it to say
    # "not executed, and here is why" instead of failing cases the configuration switches off.
    GroupRoutingLock   = $script:GroupRoutingLockReason
}

$environment = @{
    'BDUT IP'        = $Ip
    'BDUT PA'        = $BdutPa
    'Device name'    = $deviceName
    'Mask version'   = $maskVersion
    'Role'           = $productName
    'Service famil.' = $famText
    'Traffic IP'     = $(if ($TrafficIp) { $TrafficIp } else { '<none>' })
    'Reference IP'   = $(if ($ReferenceIp) { $ReferenceIp } else { '<none>' })
    'Witness IP'     = $(if ($WitnessIp) { $WitnessIp } else { '<none>' })
    'Readable GA'    = $(if ($ReadableGa) { $ReadableGa } else { '<none>' })
    'Load switch'    = $(if ($LoadSwitchGa) { "$LoadSwitchPa on $LoadSwitchGa via $LoadSwitchVia" } else { '<not in this rig>' })
    'P2P target'     = $(if ($P2pTarget) { $P2pTarget } else { '<none>' })
    'Multicast'      = $Multicast
    'Profile'        = $RunProfile
    'Isolated network' = $(if ($IsolatedNetwork) { 'yes - sending on the production / system setup group allowed' } else { 'no' })
    'Hard reset'     = $IncludeHardReset.ToString()
    'Destructive'    = $IncludeDestructive.ToString()
    'Skip slow'      = $SkipSlow.ToString()
    'Test client'    = "Invoke-Conformance.ps1 / KnxTest.psm1 ($($st.Total) vectors verified)"
    'Host'           = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
}

# ─── Load and run the suites ────────────────────────────────────────────────────

$suiteMap = [ordered]@{
    'Core'       = @{ File = '3-Core.Tests.ps1';              Function = 'Invoke-KnxSuiteCore';       Title = '3 Core' }
    'DevMgmt'    = @{ File = '4-DeviceManagement.Tests.ps1';  Function = 'Invoke-KnxSuiteDevMgmt';    Title = '4 Device Management' }
    'Tunnelling' = @{ File = '5-Tunnelling.Tests.ps1';        Function = 'Invoke-KnxSuiteTunnelling'; Title = '5 Tunnelling' }
    'Routing'    = @{ File = '6-Routing.Tests.ps1';           Function = 'Invoke-KnxSuiteRouting';    Title = '6 Routing' }
    'Sbc'        = @{ File = '6b-SystemBroadcast.Tests.ps1';  Function = 'Invoke-KnxSuiteSbc';        Title = '6b System Broadcast' }
    'RemoteDiag' = @{ File = '7-RemoteDiag.Tests.ps1';        Function = 'Invoke-KnxSuiteRemoteDiag'; Title = '7 Remote Diagnosis and Configuration' }
    'IpMedium'   = @{ File = '8-IpMedium.Tests.ps1';          Function = 'Invoke-KnxSuiteIpMedium';   Title = '8 IP as KNX Medium' }
    # Section 9 continues the report ordering only; the cases are 08_TSSK 2.5, not TSSH --
    # TSSH v1.3 contains no TCP case at all. See the suite header.
    'Tcp'        = @{ File = '9-Tcp.Tests.ps1';               Function = 'Invoke-KnxSuiteTcp';        Title = '9 TCP Transport' }
    # Section 10/11 are ours, not TSSH chapters: 10 walks the property tables a service test
    # never touches, 11 covers the Tunnelling v2 / Core v2 services. Both report N-A per case
    # on a device that does not carry the function, so they cost nothing on a v1 product.
    'Properties' = @{ File = '10-Properties.Tests.ps1';        Function = 'Invoke-KnxSuiteProperties'; Title = '10 Properties' }
    'V2'         = @{ File = '11-TunnellingV2.Tests.ps1';      Function = 'Invoke-KnxSuiteTunnellingV2'; Title = '11 Tunnelling v2' }
}

$suiteDir = Join-Path $here 'Suites'
if ($Case) {
    # free-form patterns, so no allowed-set validation: split on the usual separators only
    Set-KnxCaseFilter -Pattern @($Case -split '[,;\s]+' | Where-Object { $_ })
    Write-Host ("  Case filter: {0}" -f $Case) -ForegroundColor Cyan
}

[void](Start-KnxTestRun -Product $productName -BdutIp $Ip -Environment $environment -RunProfile $RunProfile)
foreach ($d in $droppedSuites) { Add-KnxRunDropped -Suite $d.Suite -Reason $d.Reason }

# Whatever happens in the suites - a failure, a break, a thrown case - the device goes back to the
# group it was found on. A rig left on the lab group would stop talking to its own installation.
$routingRestoreFailed = $false
try {
foreach ($key in $suiteMap.Keys) {
    if ($wantSuites -notcontains $key) { continue }
    $entry = $suiteMap[$key]
    $path = Join-Path $suiteDir $entry.File
    if (-not (Test-Path $path)) {
        # A red console line is not a result. Without the record below, a selected suite whose
        # file is absent leaves no cases, appears in no count column, and the run still reads
        # "everything ran, everything passed" - while a whole section never existed. The
        # routing drops a few lines down have always been recorded this way; this branch was
        # the one place that only printed. Found by review, the same week a registered but
        # not-yet-written suite was sitting in the map.
        Write-Host "  Suite file missing: $path" -ForegroundColor Red
        Add-KnxRunDropped -Suite $entry.Title -Reason "suite file not found: $($entry.File)"
        continue
    }
    Write-Section $entry.Title
    . $path
    & $entry.Function -Ctx $ctx -SuiteTitle $entry.Title

    # A device that has gone away turns every following case into a FAIL for the wrong
    # reason - dozens of red lines that all mean "the BDUT is not there any more". Say so
    # once, keep the results collected so far, and stop.
    # A probe that throws ("No route to host" is terminating under Stop) counts as no answer, so the report is still exported.
    if (-not $SkipRigCheck) {
        $alive = $false
        $aliveWhy = ''
        try { $alive = [bool](Test-KnxAlive -Ip $Ip -Port $Port -TimeoutMs 3000) }
        catch { $aliveWhy = " ($($_.Exception.Message))" }
        if (-not $alive) {
            Write-Host ''
            Write-Host "  The BDUT stopped answering after suite '$($entry.Title)'$aliveWhy." -ForegroundColor Red
            Write-Host '  Stopping here - every following case would fail for that reason, not its own.' -ForegroundColor Red
            Write-Host '  The results collected so far are still written to the report.' -ForegroundColor Yellow
            break
        }
    }
}
}
finally {
    if ($script:RoutingRestoreBytes) {
        Write-Section 'Routing restore'
        Write-Host "  Putting the device back on $($script:RoutingRestoreGroup) ..." -ForegroundColor Cyan
        $rs = Set-KnxRoutingGroup -Ip $Ip -Port $Port -Bytes $script:RoutingRestoreBytes
        if ($rs.Ok) {
            Write-Host "  Device is back on $($rs.Group), confirmed by reading it after the restart." -ForegroundColor Green
        }
        else {
            # Never a quiet note: the rig is now on a group its installation does not use.
            $routingRestoreFailed = $true
            Write-Host ''
            Write-Host "  RESTORE FAILED - the device is NOT back on $($script:RoutingRestoreGroup)." -ForegroundColor Red
            Write-Host "  Reason: $($rs.Reason)" -ForegroundColor Red
            Write-Host "  Put it back by hand:  oknx -i $Ip prop write 11 1 66 1 $(($script:RoutingRestoreBytes | ForEach-Object { '{0:X2}' -f $_ }) -join '')" -ForegroundColor Yellow
            Write-Host '  and restart the device afterwards - the group is read once per device lifetime.' -ForegroundColor Yellow
        }
        $script:RoutingRestoreBytes = $null
    }
}

# ─── Report ─────────────────────────────────────────────────────────────────────

$out = Export-KnxTestReport -Directory $ReportDir
$sum = $out.Summary

Write-Section 'Summary'
# One printer for every caller: four of them built this line by hand and each left out a different
# bucket, so the console could read green over a dropped suite the JSON already reported.
Write-KnxRunSummary
Write-Host ''
Write-Host "  Report: $($out.Markdown)" -ForegroundColor Cyan
Write-Host "  Data  : $($out.Json)" -ForegroundColor DarkGray
Write-Host ''

# A rig left on the wrong multicast group is a defect of this run even when every case passed;
# a green exit code would hide it until the next run wonders why nothing answers.
if ($routingRestoreFailed) {
    Write-Host '  The run ends non-zero because the routing group could not be restored.' -ForegroundColor Red
    exit 1
}
if ($sum.Fail -gt 0) { exit 1 }
exit 0
