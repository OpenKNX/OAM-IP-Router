#!/usr/bin/env pwsh
<#
Open ■
┬────┴  Invoke-Conformance
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: scripts/Test/Invoke-Conformance.ps1

.SYNOPSIS
    Runs the KNXnet/IP conformance suites against an OpenKNX IP-Interface or IP-Router
    and writes a Markdown + JSON report with a per-clause verdict.

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
    A real TP device to address point-to-point (H-5.2.10), e.g. 5.0.3. TSSH uses the load
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
    [string]$ReferenceIp = '',
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
    Write-Host '  ┬────┴  KNXnet/IP conformance' -ForegroundColor Green
    Write-Host '  ■ KNX   2026 OpenKNX - Erkan Çolak' -ForegroundColor DarkGray
    Write-Host ''
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
        Write-Fatal "$($st.Failed) of $($st.Total) frame vectors are wrong - the suites would produce wrong verdicts."
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
        if (Test-KnxAlive -Ip $ReferenceIp -Port $Port -TimeoutMs 2000) {
            Write-Host "  Reference device $ReferenceIp answers" -ForegroundColor Green
        }
        else {
            Write-Host "  Reference device $ReferenceIp does NOT answer - cross-check disabled" -ForegroundColor Yellow
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
    if ($null -ne $desc.Extended) { $maskVersion = $desc.Extended.MaskVersion }
    foreach ($f in $families) { if ($f.Id -eq 0x05) { $isRouter = $true } }
}

if ($Product -eq 'Interface') { $isRouter = $false }
if ($Product -eq 'Router')    { $isRouter = $true }
$productName = 'IP-Interface'
if ($isRouter) { $productName = 'IP-Router' }

if (-not $BdutPa -and $devicePa -ne 'unknown') { $BdutPa = $devicePa }

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

$wantSuites = Expand-ListArgument -Value $Suite -Allowed @('Core','DevMgmt','Tunnelling','Routing','RemoteDiag','IpMedium','All') -Name 'Suite'
if ($wantSuites -contains 'All') { $wantSuites = @('Core', 'DevMgmt', 'Tunnelling', 'Routing', 'RemoteDiag', 'IpMedium') }

if ($RunProfile -eq 'ReadOnly') {
    Write-Section 'Safety'
    Write-Host '  Profile ReadOnly: no write, reconfigure, reset, exhaust or flood case will run.' -ForegroundColor Yellow
    if ($wantSuites -contains 'Routing') {
        Write-Host '  Routing suite dropped - it always writes to the bus.' -ForegroundColor Yellow
        $wantSuites = @($wantSuites | Where-Object { $_ -ne 'Routing' })
    }
}

# HARD gate: never emit on the production multicast group. No switch overrides it.
# The suite is DROPPED rather than the run aborted: the other five suites are unaffected
# by the multicast group, and aborting everything would punish the common case (running
# without -Multicast against an interface, where Routing is N-A anyway).
if ($wantSuites -contains 'Routing' -and $Multicast -eq $ProductionMulticast) {
    Write-Section 'Safety'
    Write-Host "  Routing suite DROPPED - it would emit on the production group $ProductionMulticast." -ForegroundColor Yellow
    Write-Host '  Every KNXnet/IP router on this LAN listens there, including one bridging a' -ForegroundColor Yellow
    Write-Host '  production TP line, which would carry the test traffic onto it.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  To run section 6, give the lab router its own group:  -Multicast 224.0.23.13' -ForegroundColor Cyan
    Write-Host '  TSSH section 1.2.1 also requires the rig on a separate ethernet segment.' -ForegroundColor DarkGray
    $wantSuites = @($wantSuites | Where-Object { $_ -ne 'Routing' })
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
    LoadSwitchVia      = $LoadSwitchVia
    LoadSwitchGa       = $LoadSwitchGa
    LoadSwitchPa       = $LoadSwitchPa
    P2pTarget          = $P2pTarget
    Multicast          = $Multicast
    RunProfile         = $RunProfile
    IncludeHardReset   = [bool]$IncludeHardReset
    IncludeDestructive = [bool]$IncludeDestructive
    SkipSlow           = [bool]$SkipSlow
    ReadOnly           = ($RunProfile -eq 'ReadOnly')
    AllowDestructive   = ([bool]$IncludeDestructive -and $RunProfile -eq 'Full')
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
    'Load switch'    = $(if ($LoadSwitchGa) { "$LoadSwitchPa on $LoadSwitchGa via $LoadSwitchVia" } else { '<not in this rig>' })
    'P2P target'     = $(if ($P2pTarget) { $P2pTarget } else { '<none>' })
    'Multicast'      = $Multicast
    'Profile'        = $RunProfile
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
    'RemoteDiag' = @{ File = '7-RemoteDiag.Tests.ps1';        Function = 'Invoke-KnxSuiteRemoteDiag'; Title = '7 Remote Diagnosis and Configuration' }
    'IpMedium'   = @{ File = '8-IpMedium.Tests.ps1';          Function = 'Invoke-KnxSuiteIpMedium';   Title = '8 IP as KNX Medium' }
}

$suiteDir = Join-Path $here 'Suites'
[void](Start-KnxTestRun -Product $productName -BdutIp $Ip -Environment $environment -RunProfile $RunProfile)

foreach ($key in $suiteMap.Keys) {
    if ($wantSuites -notcontains $key) { continue }
    $entry = $suiteMap[$key]
    $path = Join-Path $suiteDir $entry.File
    if (-not (Test-Path $path)) {
        Write-Host "  Suite file missing: $path" -ForegroundColor Red
        continue
    }
    Write-Section $entry.Title
    . $path
    & $entry.Function -Ctx $ctx -SuiteTitle $entry.Title

    # A device that has gone away turns every following case into a FAIL for the wrong
    # reason - dozens of red lines that all mean "the BDUT is not there any more". Say so
    # once, keep the results collected so far, and stop.
    if (-not $SkipRigCheck) {
        if (-not (Test-KnxAlive -Ip $Ip -Port $Port -TimeoutMs 3000)) {
            Write-Host ''
            Write-Host "  The BDUT stopped answering after suite '$($entry.Title)'." -ForegroundColor Red
            Write-Host '  Stopping here - every following case would fail for that reason, not its own.' -ForegroundColor Red
            Write-Host '  The results collected so far are still written to the report.' -ForegroundColor Yellow
            break
        }
    }
}

# ─── Report ─────────────────────────────────────────────────────────────────────

$out = Export-KnxTestReport -Directory $ReportDir
$sum = $out.Summary

Write-Section 'Summary'
Write-Host "  Total $($sum.Total)   " -NoNewline
Write-Host "PASS $($sum.Pass)  " -ForegroundColor Green -NoNewline
Write-Host "FAIL $($sum.Fail)  " -ForegroundColor $(if ($sum.Fail -gt 0) { 'Red' } else { 'DarkGray' }) -NoNewline
Write-Host "SKIP $($sum.Skip)  " -ForegroundColor Yellow -NoNewline
Write-Host "N-A $($sum.NA)" -ForegroundColor DarkGray
Write-Host ''
Write-Host "  Report: $($out.Markdown)" -ForegroundColor Cyan
Write-Host "  Data  : $($out.Json)" -ForegroundColor DarkGray
Write-Host ''

if ($sum.Fail -gt 0) { exit 1 }
exit 0
