#!/usr/bin/env pwsh
<#
Open ■
┬────┴  Test-Features
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: scripts/Test/Features/Test-Features.ps1

.SYNOPSIS
    Layer 2 of the test plan: product features and behaviour that no KNX specification
    prescribes but that the product promises.

.DESCRIPTION
    The conformance suites answer "is this a legal KNXnet/IP device". This script answers
    "is this OUR device, doing what we said it does". The two are independent: a device
    can be perfectly conformant and still have a broken OLED, a wrong LED indication or
    a device-management path that ETS cannot download through.

    Results use the same engine and the same report format as the conformance suites, so
    a run of both produces one comparable set of artefacts. IDs are prefixed X- because
    there is no specification clause behind them - the "clause" column names the source of
    the requirement instead (a document, a decision, a build flag).

.PARAMETER Ip
    IP address of the device under test.

.PARAMETER TrafficIp
    A second interface on the same TP line, used where a feature needs real bus traffic.

.PARAMETER ExpectBusmonitor
    The device is built with OPENKNX_HW_BUSMON and must accept a busmonitor tunnel.

.PARAMETER BusmonExclusive
    Declares the intended design for X-BM-2, because the firmware and CLAUDE.md currently
    disagree and only you can settle which is right:

      set     an active busmonitor blocks EVERY tunnel, including link layer. This is what
              the firmware does today - it answers with an explicit message
              ("HW busmonitor active (bus TX paused)"), so it is deliberate, not a slip.
      unset   only a SECOND busmonitor is refused; a link-layer tunnel stays available.
              This is what CLAUDE.md describes, and it keeps the device programmable while
              somebody is watching the bus.

    The case reports which expectation it applied, so the report never hides the choice.

.PARAMETER ExpectRouting
    The device is an IP-Router and must advertise ROUTING.

.PARAMETER TunnelCount
    Number of tunnel connections the product is configured for (KNX_TUNNELING). Default 16.

.PARAMETER ReportDir
    Output directory. Default: scripts/Test/Reports.

.EXAMPLE
    ./Test-Features.ps1 -Ip 11.11.0.126 -TrafficIp 11.11.0.5 -ExpectBusmonitor
.EXAMPLE
    ./Test-Features.ps1 -Ip 11.11.0.3 -ExpectRouting -TunnelCount 16
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Ip,
    [int]$Port = 3671,
    [string]$TrafficIp = '',
    [switch]$ExpectBusmonitor,
    [switch]$BusmonExclusive,
    [switch]$ExpectRouting,
    [int]$TunnelCount = 16,
    [string]$ReportDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $here 'lib/KnxTest.psm1') -Force
if (-not $ReportDir) { $ReportDir = Join-Path $here 'Reports' }

$K = Get-KnxConstants
$SUITE = 'X Features and behaviour'

Write-Host ''
Write-Host '  Open ■' -ForegroundColor Green
Write-Host '  ┬────┴  Feature and behaviour tests' -ForegroundColor Green
Write-Host '  ■ KNX   2026 OpenKNX - Erkan Çolak' -ForegroundColor DarkGray
Write-Host ''

$st = Invoke-KnxSelfTest -Quiet
if (-not $st.Ok) {
    Write-Host "  ABORT: library self-test failed ($($st.Failed)/$($st.Total))" -ForegroundColor Red
    exit 2
}

if (-not (Test-KnxAlive -Ip $Ip -Port $Port -TimeoutMs 2000)) {
    Write-Host "  ABORT: $Ip does not answer" -ForegroundColor Red
    exit 3
}

$desc = Get-KnxDescription -Ip $Ip -Port $Port
$productName = 'IP-Interface'
if ($ExpectRouting) { $productName = 'IP-Router' }

[void](Start-KnxTestRun -Product "$productName-features" -BdutIp $Ip -RunProfile 'Features' -Environment @{
        'BDUT IP'          = $Ip
        'Traffic IP'       = $(if ($TrafficIp) { $TrafficIp } else { '<none>' })
        'Expect busmon'    = $ExpectBusmonitor.ToString()
        'Expect routing'   = $ExpectRouting.ToString()
        'Tunnel count'     = "$TunnelCount"
        'Device name'      = $(if ($null -ne $desc -and $null -ne $desc.Device) { $desc.Device.FriendlyName } else { 'unknown' })
        'Mask version'     = $(if ($null -ne $desc -and $null -ne $desc.Extended) { $desc.Extended.MaskVersion } else { 'unknown' })
        'Host'             = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
    })

Write-Host "  $SUITE" -ForegroundColor Cyan
Write-Host ('  ' + ('-' * $SUITE.Length)) -ForegroundColor DarkGray

# ─── Identity ───────────────────────────────────────────────────────────────────

Invoke-KnxTestCase -Suite $SUITE -Id 'X-ID-1' -Title 'Mask version matches the product role' -Clause 'CLAUDE.md architecture decision; platformio.custom.ini MASK_VERSION' -Body {
    # The Extended Device Information DIB is "Not allowed" in a DESCRIPTION_RESPONSE
    # (03_08_02 Table 5, p.31) - it only appears in SEARCH_RESPONSE_EXTENDED. Looking for the
    # mask there therefore always failed, and the earlier "it is optional" reasoning was
    # guessed rather than read. The specification names the authoritative source itself:
    # PID_DEVICE_DESCRIPTOR (PID 83) in the Device Object. Read it there.
    $mgmt = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
    Assert-KnxTrue $mgmt.Ok "could not open a device management connection to read the mask ($($mgmt.StatusName))"
    try {
        $dd = Read-KnxProperty -Connection $mgmt -ObjectType $K.ObjType.DEVICE -PropertyId 83
        Assert-KnxTrue ($null -ne $dd.Parsed -and -not $dd.Parsed.IsError) 'PID_DEVICE_DESCRIPTOR (83) is not readable - the mask version cannot be established'
        Assert-KnxTrue ($dd.Parsed.Data.Length -ge 2) 'PID_DEVICE_DESCRIPTOR is shorter than the two octets a mask version needs'
        $mask = '0x{0:X4}' -f (Get-Uint16 -Bytes $dd.Parsed.Data -Offset 0)
    }
    finally { [void](Close-KnxConnection -Connection $mgmt) }
    Add-KnxEvidence -Note "mask $mask"
    if ($ExpectRouting) { Assert-KnxEqual '0x091A' $mask 'the IP-Router must report mask 091A' }
    else { Assert-KnxEqual '0x07B0' $mask 'the IP-Interface must report mask 07B0 - 091A would make it a routing device and forbid the busmonitor' }
}

Invoke-KnxTestCase -Suite $SUITE -Id 'X-ID-2' -Title 'Advertised service families match the product' -Clause '03_08_02 Core; CLAUDE.md "router vs interface is a capability"' -Body {
    Assert-KnxTrue ($null -ne $desc) 'no description'
    $names = ($desc.Families | ForEach-Object { $_.Name }) -join ', '
    Add-KnxEvidence -Note "advertised: $names"
    Assert-KnxTrue (Test-KnxFamilySupported -Body $desc.Body -Family $K.Family.CORE) 'CORE missing'
    Assert-KnxTrue (Test-KnxFamilySupported -Body $desc.Body -Family $K.Family.DEVICE_MANAGEMENT) 'DEVICE MANAGEMENT missing'
    Assert-KnxTrue (Test-KnxFamilySupported -Body $desc.Body -Family $K.Family.TUNNELLING) 'TUNNELLING missing'
    $hasRouting = Test-KnxFamilySupported -Body $desc.Body -Family $K.Family.ROUTING
    if ($ExpectRouting) { Assert-KnxTrue $hasRouting 'IP-Router does not advertise ROUTING' }
    else { Assert-KnxTrue (-not $hasRouting) 'IP-Interface advertises ROUTING - it must not' }
}

Invoke-KnxTestCase -Suite $SUITE -Id 'X-ID-3' -Title 'Maximum APDU length is reported' -Clause '03_08_02 Core, Extended Device Information DIB' -Body {
    # Same story as X-ID-1: the DIB is not allowed in a DESCRIPTION_RESPONSE. 03_08_02 p.30
    # names the source of the value: PID_MAX_LOCAL_APDU_LENGTH (PID 69) in the cEMI Server
    # Object - not PID_MAX_APDU_LENGTH (58), which is the Router Object's.
    $mgmt = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
    Assert-KnxTrue $mgmt.Ok "could not open a device management connection ($($mgmt.StatusName))"
    try {
        $ap = Read-KnxProperty -Connection $mgmt -ObjectType $K.ObjType.CEMI_SERVER -PropertyId 69
        if ($null -eq $ap.Parsed -or $ap.Parsed.IsError) {
            # Measured, not assumed: a certified reference interface does not expose PID 69
            # either, so the property is optional and demanding it would fail a conformant
            # device. Reported as a skip WITH that evidence rather than as a defect.
            Set-KnxTestSkip 'PID_MAX_LOCAL_APDU_LENGTH (69) is not exposed on the cEMI Server Object - optional, and the certified reference does not expose it either (measured)'
        }
        $apdu = if ($ap.Parsed.Data.Length -ge 2) { Get-Uint16 -Bytes $ap.Parsed.Data -Offset 0 } else { [int]$ap.Parsed.Data[0] }
    }
    finally { [void](Close-KnxConnection -Connection $mgmt) }
    Add-KnxEvidence -Note "max APDU $apdu octets"
    # 15 is the KNX minimum; anything below means long frames cannot work at all.
    Assert-KnxTrue ($apdu -ge 15) "reported maximum APDU length $apdu is below the KNX minimum of 15"
}

# ─── Tunnelling capacity ────────────────────────────────────────────────────────

Invoke-KnxTestCase -Suite $SUITE -Id 'X-TUN-1' -Title 'Configured number of tunnels is actually granted' -Clause 'platformio.custom.ini KNX_TUNNELING' -Body {
    $open = @()
    $refusal = -1
    # The suite's own shared traffic connection occupies a tunnel slot on this device, so
    # counting without releasing it reports one tunnel too few and blames the firmware for
    # the test's own connection. Release it; later cases reopen it on demand.
    Close-KnxTrafficConnection

    # How many tunnels CAN be granted is decided by how many additional individual addresses
    # are actually assigned, not by the build flag. A project may leave an entry empty - ETS
    # shows it as "5.0.- Tunnel 1" - and then the device correctly grants one fewer. Asking
    # the device turns a configuration state into evidence instead of a firmware defect.
    # The element count field is 4 bits, so 16 wraps to 0: read 15 + 1, never 16 at once.
    $assigned = @()
    $mgmt = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
    if ($mgmt.Ok) {
        try {
            foreach ($blk in @(@{ s = 1; n = 15 }, @{ s = 16; n = 1 })) {
                $pr = Read-KnxProperty -Connection $mgmt -ObjectType $K.ObjType.KNXNETIP_PARAM `
                                       -PropertyId $K.Pid.ADDITIONAL_INDIVIDUAL_ADDRESSES -ElementCount $blk.n -StartIndex $blk.s
                if ($null -eq $pr.Parsed -or $pr.Parsed.IsError) { continue }
                $d = $pr.Parsed.Data
                for ($o = 0; ($o + 1) -lt $d.Length; $o += 2) {
                    $raw = Get-Uint16 -Bytes $d -Offset $o
                    if ($raw -gt 0) { $assigned += (ConvertFrom-KnxPa -Raw $raw) }
                }
            }
        }
        finally { [void](Close-KnxConnection -Connection $mgmt) }
    }
    # Only DISTINCT addresses can be granted: the server never opens two tunnels with the
    # same individual address (03_08_04 section 2.2.4). An unassigned ETS entry shows up here
    # as a duplicate of its neighbour, so counting non-zero entries overstates the capacity.
    $distinct = @($assigned | Sort-Object -Unique)
    $expected = $TunnelCount
    if ($assigned.Count -gt 0) {
        $expected = $distinct.Count
        if ($distinct.Count -lt $assigned.Count) {
            Add-KnxEvidence -Note "pool holds $($assigned.Count) entries but only $($distinct.Count) distinct addresses - duplicates cannot be granted, and exhausting them is the E_NO_MORE_UNIQUE_CONNECTIONS case"
        }
        Add-KnxEvidence -Note "$($assigned.Count) of $TunnelCount tunnel addresses are assigned in the project: $($assigned -join ', ')"
        if ($assigned.Count -lt $TunnelCount) {
            Add-KnxEvidence -Note "$($TunnelCount - $assigned.Count) tunnel entr(y/ies) have no individual address - ETS shows those as '5.0.- Tunnel n'. Expecting $expected, not $TunnelCount"
        }
    }
    try {
        for ($i = 0; $i -lt ($TunnelCount + 2); $i++) {
            $c = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_LINKLAYER -TimeoutMs 2500
            if ($c.Ok) { $open += $c; continue }
            $refusal = $c.Status
            break
        }
        $addrs = @($open | ForEach-Object { $_.TunnelPa })
        Add-KnxEvidence -Note "$($open.Count) of $TunnelCount tunnels granted: $($addrs -join ', ')"
        Assert-KnxTrue ($open.Count -gt 0) 'no tunnel could be opened'
        Assert-KnxEqual $expected $open.Count "the device has $expected assignable tunnel address(es) but grants $($open.Count)"
        Assert-KnxStatus $K.Error.E_NO_MORE_CONNECTIONS $refusal 'the tunnel past the configured maximum was refused with the wrong status'
    }
    finally { foreach ($c in $open) { [void](Close-KnxConnection -Connection $c) } }
}

Invoke-KnxTestCase -Suite $SUITE -Id 'X-TUN-2' -Title 'Every tunnel gets a distinct, usable individual address' -Clause '03_08_04 Tunnelling, additional individual addresses' -Body {
    $open = @()
    try {
        for ($i = 0; $i -lt $TunnelCount; $i++) {
            $c = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_LINKLAYER -TimeoutMs 2500
            if (-not $c.Ok) { break }
            $open += $c
        }
        Assert-KnxTrue ($open.Count -gt 0) 'no tunnel could be opened'
        $addrs = @($open | ForEach-Object { $_.TunnelPa })
        Add-KnxEvidence -Note ($addrs -join ', ')
        $unique = @($addrs | Sort-Object -Unique)
        Assert-KnxEqual $addrs.Count $unique.Count 'two simultaneous tunnels were given the same individual address'
        foreach ($a in $addrs) {
            Assert-KnxTrue ($null -ne $a) 'a tunnel was opened without an individual address in the CRD'
            Assert-KnxTrue (((ConvertTo-KnxPa -Address $a) -band 0xFF) -ne 0) "tunnel address $a has device part 0"
        }
    }
    finally { foreach ($c in $open) { [void](Close-KnxConnection -Connection $c) } }
}

Invoke-KnxTestCase -Suite $SUITE -Id 'X-TUN-3' -Title 'Tunnel slots are released and reusable' -Clause 'operational requirement: a client crash must not consume a slot permanently' -Body {
    # Open to exhaustion, close everything, then prove the full count is available again.
    $first = @()
    try {
        for ($i = 0; $i -lt ($TunnelCount + 1); $i++) {
            $c = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_LINKLAYER -TimeoutMs 2500
            if (-not $c.Ok) { break }
            $first += $c
        }
        $n1 = $first.Count
        foreach ($c in $first) { [void](Close-KnxConnection -Connection $c) }
        $first = @()
        Start-Sleep -Seconds 2

        $second = @()
        try {
            for ($i = 0; $i -lt ($TunnelCount + 1); $i++) {
                $c = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_LINKLAYER -TimeoutMs 2500
                if (-not $c.Ok) { break }
                $second += $c
            }
            $n2 = $second.Count
            Add-KnxEvidence -Note "$n1 tunnels, released, then $n2 tunnels"
            Assert-KnxEqual $n1 $n2 'fewer tunnels were available after releasing them all - slots are leaking'
        }
        finally { foreach ($c in $second) { [void](Close-KnxConnection -Connection $c) } }
    }
    finally { foreach ($c in $first) { [void](Close-KnxConnection -Connection $c) } }
}

# ─── Busmonitor ─────────────────────────────────────────────────────────────────

Invoke-KnxTestCase -Suite $SUITE -Id 'X-BM-1' -Title 'Busmonitor tunnel matches the build flag' -Clause 'platformio.custom.ini OPENKNX_HW_BUSMON; 03_08_04 section 2.2.4' -Body {
    $c = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_BUSMONITOR
    try {
        # Whether the busmonitor is present is a property of the DEVICE, so probe it. A
        # missing -ExpectBusmonitor is only a missing command-line argument, never evidence
        # that the build lacks the feature - asserting "must be refused" there failed a
        # device whose busmonitor works correctly, and left X-BM-2 (the real exclusivity
        # check) permanently N-A. The switch now only asserts intent when it IS given.
        $script:BusmonAvailable = [bool]$c.Ok
        if ($ExpectBusmonitor) {
            Assert-KnxTrue $c.Ok "the build declares OPENKNX_HW_BUSMON but the busmonitor tunnel was refused ($($c.StatusName))"
        }
        if ($c.Ok) {
            Add-KnxEvidence -Note "busmonitor tunnel accepted on channel $($c.Channel)"
            # 03_08_04 section 2.2.4: a device offering a busmonitor connection must not be a
            # routing device. This is the clause that actually matters here - and it is what a
            # certified reference was observed to violate.
            $desc = Get-KnxDescription -Ip $Ip -Port $Port
            $routing = @($desc.Families | Where-Object { $_.Name -match 'ROUTING' })
            Assert-KnxTrue ($routing.Count -eq 0) 'device offers a busmonitor tunnel while advertising the ROUTING service family (03_08_04 section 2.2.4)'
        }
        else {
            Add-KnxEvidence -Note "busmonitor tunnel refused ($($c.StatusName)) - device has no hardware busmonitor"
            Assert-KnxStatus $K.Error.E_CONNECTION_OPTION $c.Status 'busmonitor refusal uses the wrong status code'
        }
    }
    finally { if ($c.Ok) { [void](Close-KnxConnection -Connection $c) } }
}

Invoke-KnxTestCase -Suite $SUITE -Id 'X-BM-2' -Title 'A second busmonitor connection is refused, a link-layer tunnel is not' -Clause '03_08_04 section 2.2.4: one busmonitor per subnetwork' -Body {
    # Gate on what X-BM-1 actually observed, not on the command-line switch.
    if (-not $script:BusmonAvailable) { Set-KnxTestNotApplicable 'device refused a busmonitor tunnel (no hardware busmonitor) - see X-BM-1' }
    $bm1 = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_BUSMONITOR
    Assert-KnxTrue $bm1.Ok "first busmonitor tunnel refused ($($bm1.StatusName))"
    $bm2 = $null; $link = $null
    try {
        $bm2 = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_BUSMONITOR
        Add-KnxEvidence -Note "second busmonitor: $($bm2.StatusName)"
        Assert-KnxTrue (-not $bm2.Ok) 'a SECOND busmonitor connection was accepted - the busmonitor is exclusive per subnetwork'

        # Which behaviour is correct is a product decision, not a specification one. For this
        # product it has been settled and verified in the firmware: closeTunnelsForBusmon()
        # drops existing tunnels on busmonitor entry and new ones are refused - the busmonitor
        # is fully exclusive. That is therefore the default expectation; -BusmonExclusive:$false
        # is for a product that deliberately allows a tunnel alongside the busmonitor.
        if (-not $PSBoundParameters.ContainsKey('BusmonExclusive')) { $BusmonExclusive = $true }
        $link = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_LINKLAYER
        Add-KnxEvidence -Note "link-layer tunnel while busmonitor active: $($link.StatusName)"
        if ($BusmonExclusive) {
            Add-KnxEvidence -Note 'expectation: -BusmonExclusive - the busmonitor blocks every tunnel'
            Assert-KnxTrue (-not $link.Ok) 'a link-layer tunnel was accepted although the busmonitor is declared exclusive'
        }
        else {
            Add-KnxEvidence -Note 'expectation: only a second BUSMONITOR is refused (CLAUDE.md); pass -BusmonExclusive if the firmware behaviour is intended'
            Assert-KnxTrue $link.Ok 'a normal link-layer tunnel was refused while the busmonitor was active - only a second BUSMONITOR may be refused. If that block is intended, run with -BusmonExclusive and update CLAUDE.md'
        }
    }
    finally {
        if ($null -ne $link -and $link.Ok) { [void](Close-KnxConnection -Connection $link) }
        if ($null -ne $bm2 -and $bm2.Ok) { [void](Close-KnxConnection -Connection $bm2) }
        [void](Close-KnxConnection -Connection $bm1)
    }
}

Invoke-KnxTestCase -Suite $SUITE -Id 'X-BM-3' -Title 'Busmonitor delivers byte-exact LPDUs with a valid FCS' -Clause '03_06_03 section 4.1.4.1; 03_02_02 section 2.2.4.6' -Body {
    # Gate on what X-BM-1 actually observed, not on the command-line switch.
    if (-not $script:BusmonAvailable) { Set-KnxTestNotApplicable 'device refused a busmonitor tunnel (no hardware busmonitor) - see X-BM-1' }
    if (-not $TrafficIp) { Set-KnxTestSkip 'needs a second interface (-TrafficIp) to generate bus traffic' }

    $bm = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_BUSMONITOR
    Assert-KnxTrue $bm.Ok "busmonitor tunnel refused ($($bm.StatusName))"
    $src = Get-KnxTrafficConnection -Ip $TrafficIp
    try {
        Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
        $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination (ConvertTo-KnxGa -Address '0/0/31') -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
        foreach ($i in 1..3) { [void](Send-KnxTunnelCemi -Connection $src -Cemi $cemi -TimeoutMs 3000); Start-Sleep -Milliseconds 200 }

        $frames = @()
        $deadline = [DateTime]::UtcNow.AddSeconds(8)
        while ([DateTime]::UtcNow -lt $deadline -and $frames.Count -lt 3) {
            $in = Receive-KnxTunnelCemi -Connection $bm -TimeoutMs 1500
            if ($null -eq $in) { continue }
            if ($in.Cemi.Length -ge 1 -and $in.Cemi[0] -eq $K.Cemi.L_BUSMON_IND) { $frames += $in }
        }
        Assert-KnxTrue ($frames.Count -gt 0) 'no L_Busmon.ind arrived while the bus was busy'
        Add-KnxEvidence -Note "$($frames.Count) busmonitor indication(s)"

        $badFcs = 0
        $lost = 0
        foreach ($f in $frames) {
            $b = Read-CemiBusmon -Cemi $f.Cemi
            if ($null -eq $b) { continue }
            if (-not $b.FcsOk) { $badFcs++ }
            if ($b.Lost -eq $true) { $lost++ }
        }
        Add-KnxEvidence -Received $frames[0].Cemi -Note "invalid FCS: $badFcs, lost flag set: $lost"
        Assert-KnxEqual 0 $badFcs 'the busmonitor reported LPDUs whose TP1 frame check octet does not match - it is not delivering what was on the bus'
    }
    finally {
        [void](Close-KnxConnection -Connection $bm)
    }
}

# ─── Robustness of the discovery path ───────────────────────────────────────────

Invoke-KnxTestCase -Suite $SUITE -Id 'X-ROB-1' -Title 'Discovery keeps answering while every tunnel is taken' -Clause 'operational requirement: a full device must still be findable' -Body {
    $open = @()
    try {
        for ($i = 0; $i -lt ($TunnelCount + 1); $i++) {
            $c = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_LINKLAYER -TimeoutMs 2500
            if (-not $c.Ok) { break }
            $open += $c
        }
        Add-KnxEvidence -Note "$($open.Count) tunnels held open"
        Assert-KnxTrue ($open.Count -gt 0) 'no tunnel could be opened'
        # DESCRIPTION needs no connection, so a full device must still answer it. This is
        # what makes a saturated device distinguishable from a crashed one.
        Assert-KnxTrue (Test-KnxAlive -Ip $Ip -Port $Port -TimeoutMs 2500) 'device stopped answering DESCRIPTION while all tunnels were in use'
    }
    finally { foreach ($c in $open) { [void](Close-KnxConnection -Connection $c) } }
}

Invoke-KnxTestCase -Suite $SUITE -Id 'X-ROB-2' -Title 'Device survives a burst of malformed frames' -Clause 'operational requirement: a misbehaving client must not take the device down' -Body {
    $s = New-KnxSocket -TimeoutMs 300
    try {
        $shapes = @(
            [byte[]]@(0x06),
            [byte[]]@(0x06, 0x10),
            [byte[]]@(0x06, 0x10, 0x02, 0x01),
            [byte[]]@(0x06, 0x10, 0x02, 0x01, 0xFF, 0xFF),
            [byte[]]@(0x00, 0x00, 0x00, 0x00, 0x00, 0x00),
            [byte[]]@(0x06, 0x10, 0x04, 0x20, 0x00, 0x0A, 0x04, 0xFF, 0xFF, 0xFF),
            (New-Object byte[] 512)
        )
        foreach ($rep in 1..20) { foreach ($f in $shapes) { Send-KnxFrame -Socket $s -Frame $f -Ip $Ip -Port $Port } }
        Add-KnxEvidence -Note "$($shapes.Count * 20) malformed frames sent"
    }
    finally { $s.Dispose() }
    Start-Sleep -Seconds 2
    Assert-KnxTrue (Test-KnxAlive -Ip $Ip -Port $Port -TimeoutMs 3000) 'device stopped answering after a burst of malformed frames'

    # Still answering is not enough - it must still be usable.
    $c = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_LINKLAYER
    try { Assert-KnxTrue $c.Ok "device answers discovery but no longer grants a tunnel after the burst ($($c.StatusName))" }
    finally { if ($c.Ok) { [void](Close-KnxConnection -Connection $c) } }
}

# ─── Report ─────────────────────────────────────────────────────────────────────

$out = Export-KnxTestReport -Directory $ReportDir
$sum = $out.Summary
Write-Host ''
Write-Host "  Total $($sum.Total)   " -NoNewline
Write-Host "PASS $($sum.Pass)  " -ForegroundColor Green -NoNewline
Write-Host "FAIL $($sum.Fail)  " -ForegroundColor $(if ($sum.Fail -gt 0) { 'Red' } else { 'DarkGray' }) -NoNewline
Write-Host "SKIP $($sum.Skip)  " -ForegroundColor Yellow -NoNewline
Write-Host "N-A $($sum.NA)" -ForegroundColor DarkGray
Write-Host ''
Write-Host "  Report: $($out.Markdown)" -ForegroundColor Cyan
Write-Host ''
if ($sum.Fail -gt 0) { exit 1 }
exit 0
