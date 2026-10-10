#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Test-Features
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Features/Test-Features.ps1

<#
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
    Declares the intended design for X-BM-2:

      set     an active busmonitor blocks EVERY tunnel, including link layer. This is what
              the firmware does - it answers with an explicit message
              ("HW busmonitor active (bus TX paused)") - and what doc/reference/ARCHITECTURE.md
              section 6 describes (03_08_04 section 2.2.4).
      unset   only a SECOND busmonitor is refused; a link-layer tunnel stays available, which
              keeps the device programmable while somebody is watching the bus.

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

. (Join-Path $PSScriptRoot '../lib/KnxLogo.ps1')
Write-KnxLogo -Title 'Feature and behaviour tests'

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
        'Mask version'     = $(Get-KnxMaskVersionText -Ip $Ip -Port $Port)
        'Host'             = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
    })

Write-Host "  $SUITE" -ForegroundColor Cyan
Write-Host ('  ' + ('-' * $SUITE.Length)) -ForegroundColor DarkGray

# ─── Identity ───────────────────────────────────────────────────────────────────

Invoke-KnxTestCase -Suite $SUITE -Id 'X-ID-1' -Title 'Mask version matches the product role' -Clause 'doc/reference/ARCHITECTURE.md section 2; platformio.custom.ini MASK_VERSION' -Body {
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

Invoke-KnxTestCase -Suite $SUITE -Id 'X-ID-2' -Title 'Advertised service families match the product' -Clause '03_08_02 Core; doc/reference/ARCHITECTURE.md section 1 "router vs interface is a capability"' -Body {
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

# ─── Property read helpers ──────────────────────────────────────────────────────

function Read-KnxPropertyRetry {
    <#
    .SYNOPSIS
        M_PropRead with one resend when the device does not answer at all.
    .DESCRIPTION
        A lost datagram and an element that does not exist look the same to the caller, and
        only the first of the two is worth asking again. An error confirmation is the
        device's answer, so it is returned as it is. Returns $null when nothing came back
        twice.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][int]$ObjectType,
        [Parameter(Mandatory)][int]$PropertyId,
        [int]$ElementCount = 1,
        [int]$StartIndex = 1
    )
    $r = Read-KnxProperty -Connection $Connection -ObjectType $ObjectType -PropertyId $PropertyId `
                          -ElementCount $ElementCount -StartIndex $StartIndex
    if ($null -ne $r -and $null -ne $r.Parsed) { return $r }
    # A late confirmation of the first attempt would otherwise be read as the answer to the second.
    if ($null -ne $Connection.Socket) { Clear-KnxSocket -Socket $Connection.Socket }
    $r = Read-KnxProperty -Connection $Connection -ObjectType $ObjectType -PropertyId $PropertyId `
                          -ElementCount $ElementCount -StartIndex $StartIndex
    if ($null -ne $r -and $null -ne $r.Parsed) { return $r }
    return $null
}

function Get-KnxPropertyElementCount {
    <#
    .SYNOPSIS
        Number of elements a property currently holds, read from start index 0.
    .DESCRIPTION
        03_03_07: a read at start index 0 answers with the current number of elements instead
        of data, and it answers even when the property holds none. Returns -1 when the
        property did not answer or is not implemented - which is not the same as "it holds
        nothing", and the caller must keep the two apart.
    #>
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][int]$ObjectType,
        [Parameter(Mandatory)][int]$PropertyId
    )
    $r = Read-KnxPropertyRetry -Connection $Connection -ObjectType $ObjectType -PropertyId $PropertyId -ElementCount 1 -StartIndex 0
    if ($null -eq $r -or $null -eq $r.Parsed -or $r.Parsed.IsError) { return -1 }
    if ($r.Parsed.Data.Length -lt 2) { return -1 }
    return (Get-Uint16 -Bytes $r.Parsed.Data -Offset 0)
}

function Get-KnxPropertyBlocks {
    <#
    .SYNOPSIS
        Splits an element count into read blocks of at most 15 elements.
    .DESCRIPTION
        The cEMI element-count field is four bits, so 16 wraps to 0 and a block never asks
        for more than 15. Each block carries its absolute start index.
    #>
    param([Parameter(Mandatory)][int]$Count)
    $b = @()
    $i = 1
    while ($i -le $Count) {
        $n = [Math]::Min(15, $Count - $i + 1)
        $b += @{ s = $i; n = $n }
        $i += $n
    }
    return , $b
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
    $assigned = @()
    $reservedElsewhere = 0     # slots this client can never be given: reserved for a DIFFERENT IP
    $mgmt = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
    if ($mgmt.Ok) {
        try {
            # Ask the device how many elements the property holds before reading it. A read that starts
            # past the last element answers with element count 0, which the parser reports as an error -
            # the same shape a failed read has. Sizing the blocks from the reported count keeps the two
            # apart: within the count, a block that does not come back leaves the pool half-known and the case must not
            # judge on it; an unreadable count means the property is not there and the expected number
            # falls back to the build flag.
            $paaCount = Get-KnxPropertyElementCount -Connection $mgmt -ObjectType $K.ObjType.KNXNETIP_PARAM `
                                                    -PropertyId $K.Pid.ADDITIONAL_INDIVIDUAL_ADDRESSES
            if ($paaCount -lt 0) {
                Add-KnxEvidence -Note "PID_ADDITIONAL_INDIVIDUAL_ADDRESSES did not report an element count - the pool is unknown, so $TunnelCount from the build flag is used as the expectation"
            }
            else {
                if ($paaCount -eq 0) {
                    Add-KnxEvidence -Note "PID_ADDITIONAL_INDIVIDUAL_ADDRESSES holds no elements - the pool is empty, so $TunnelCount from the build flag is used as the expectation"
                }
                foreach ($blk in (Get-KnxPropertyBlocks -Count $paaCount)) {
                    $pr = Read-KnxPropertyRetry -Connection $mgmt -ObjectType $K.ObjType.KNXNETIP_PARAM `
                                                -PropertyId $K.Pid.ADDITIONAL_INDIVIDUAL_ADDRESSES -ElementCount $blk.n -StartIndex $blk.s
                    if ($null -eq $pr -or $pr.Parsed.IsError) {
                        Set-KnxTestNotApplicable "PID_ADDITIONAL_INDIVIDUAL_ADDRESSES reports $paaCount element(s) but slots $($blk.s)..$($blk.s + $blk.n - 1) did not read back - the address pool is unknown, so the number of grantable tunnels cannot be derived"
                    }
                    $d = $pr.Parsed.Data
                    for ($o = 0; ($o + 1) -lt $d.Length; $o += 2) {
                        $raw = Get-Uint16 -Bytes $d -Offset $o
                        if ($raw -gt 0) { $assigned += (ConvertFrom-KnxPa -Raw $raw) }
                    }
                }
            }

            # A slot reserved for another client (control bit 7, the client IP in property 202) is withheld from this one; control byte and IP are paired per block by absolute slot number, so a failed half-read shifts nothing.
            # Element counts first, as for the address pool: a slot is tied to a client IP only when both properties answer (otherwise nothing counts as reserved), and only as many slots as both hold are paired.
            $slots = @()
            $ctrlCount = Get-KnxPropertyElementCount -Connection $mgmt -ObjectType $K.ObjType.KNXNETIP_PARAM `
                                                     -PropertyId $K.Pid.CUSTOM_RESERVED_TUNNELS_CTRL
            $ipCount = Get-KnxPropertyElementCount -Connection $mgmt -ObjectType $K.ObjType.KNXNETIP_PARAM `
                                                   -PropertyId $K.Pid.CUSTOM_RESERVED_TUNNELS_IP
            if (($ctrlCount -lt 0) -ne ($ipCount -lt 0)) {
                Add-KnxEvidence -Note "only one half of the tunnel reservation answered (control $ctrlCount element(s), IP $ipCount) - a slot cannot be tied to a client IP, so none is counted as withheld"
            }
            if ($ctrlCount -ge 0 -and $ipCount -ge 0) {
                $resCount = [Math]::Min($ctrlCount, $ipCount)
                if ($ctrlCount -ne $ipCount) {
                    Add-KnxEvidence -Note "tunnel reservation control holds $ctrlCount element(s) and IP holds $ipCount - only the first $resCount slot(s) can be paired"
                }
                foreach ($blk in (Get-KnxPropertyBlocks -Count $resCount)) {
                    $pc = Read-KnxPropertyRetry -Connection $mgmt -ObjectType $K.ObjType.KNXNETIP_PARAM `
                                                -PropertyId $K.Pid.CUSTOM_RESERVED_TUNNELS_CTRL -ElementCount $blk.n -StartIndex $blk.s
                    $pi = Read-KnxPropertyRetry -Connection $mgmt -ObjectType $K.ObjType.KNXNETIP_PARAM `
                                                -PropertyId $K.Pid.CUSTOM_RESERVED_TUNNELS_IP -ElementCount $blk.n -StartIndex $blk.s
                    $cOk = ($null -ne $pc -and -not $pc.Parsed.IsError)
                    $iOk = ($null -ne $pi -and -not $pi.Parsed.IsError)
                    # Plain assignments, not "$c = if (...) { @() }": an if-statement that yields an
                    # empty collection assigns $null, and the .Count below then throws under StrictMode
                    # and the case ends as an unhandled error instead of a result.
                    $c = @()
                    $pip = @()
                    if ($cOk) { $c = @($pc.Parsed.Data) }
                    if ($iOk) { $pip = @($pi.Parsed.Data) }
                    # One control byte and four IP octets per slot. That ratio is the invariant, not the
                    # requested length: a block that answers with fewer slots than asked is still pairable
                    # over the slots it did return, and demanding $blk.n octets rejected it.
                    if (-not $cOk -or -not $iOk -or $c.Count -eq 0 -or $pip.Count -ne (4 * $c.Count)) {
                        Set-KnxTestNotApplicable "the tunnel reservation of slots $($blk.s)..$($blk.s + $blk.n - 1) cannot be paired (control $($c.Count) octet(s), IP $($pip.Count) - four IP octets per control byte are needed) - which slots are withheld from this client is unknown, so the grantable count cannot be derived"
                    }
                    if ($c.Count -lt $blk.n) {
                        Add-KnxEvidence -Note "tunnel reservation slots $($blk.s)..$($blk.s + $blk.n - 1) answered with $($c.Count) slot(s); the rest is read as not reserved"
                    }
                    for ($j = 0; $j -lt $c.Count; $j++) {
                        $slots += [pscustomobject]@{
                            Slot = $blk.s + $j
                            Ctrl = [int]$c[$j]
                            Ip   = '{0}.{1}.{2}.{3}' -f $pip[4 * $j], $pip[4 * $j + 1], $pip[4 * $j + 2], $pip[4 * $j + 3]
                        }
                    }
                }
            }
            $mine = [string]$mgmt.LocalIp
            # The reservation is an OpenKNX extension, not KNX: the stack applies it only when BOTH tables hold
            # exactly KNX_TUNNELING elements (ip_tunnel_server.cpp reservedTunnelsCtrl/Ip). A partial table is
            # ignored there and every slot is grantable, so withholding slots for it here was a false FAIL.
            $resActive = ($ctrlCount -eq $TunnelCount -and $ipCount -eq $TunnelCount)
            if (-not $resActive -and @($slots | Where-Object { ($_.Ctrl -band 0x80) -ne 0 }).Count -gt 0) {
                Add-KnxEvidence -Note "tunnel reservation is inactive (control $ctrlCount, IP $ipCount element(s), the device applies it only at $TunnelCount each) - no slot is counted as withheld"
            }
            foreach ($sl in $slots) {
                if (-not $resActive) { break }
                if (($sl.Ctrl -band 0x80) -eq 0) { continue }
                if ($sl.Ip -eq $mine) { continue }
                $reservedElsewhere++
                Add-KnxEvidence -Note "tunnel slot $($sl.Slot) is reserved for $($sl.Ip), so it is not offered to this client ($mine)"
            }
        }
        finally { [void](Close-KnxConnection -Connection $mgmt) }
    }
    # Only DISTINCT addresses can be granted: the server never opens two tunnels with the
    # same individual address (03_08_04 section 2.2.4). An unassigned ETS entry shows up here
    # as a duplicate of its neighbour, so counting non-zero entries overstates the capacity.
    $distinct = @($assigned | Sort-Object -Unique)
    $expected = $TunnelCount - $reservedElsewhere
    if ($assigned.Count -gt 0) {
        $expected = $distinct.Count - $reservedElsewhere
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
        # Each stage of a full run is its own process, so a tunnel the PREVIOUS stage left open is not
        # closed by Close-KnxTrafficConnection above - the device only reaps it after the 120 s heartbeat.
        # Counting once therefore reported a firmware defect three times for a slot that was simply still
        # held; run alone, the same device grants the whole pool every time. Retry past the reap window
        # and judge the BETTER pass, so a shortfall that survives it is the real thing.
        $granted = $open.Count
        $resultRefusal = $refusal
        $resultAddrs = $addrs
        if ($open.Count -lt $expected) {
            Add-KnxEvidence -Note "first pass granted $($open.Count) of $expected - releasing and waiting out the 120 s heartbeat reap before counting again"
            foreach ($c in $open) { [void](Close-KnxConnection -Connection $c) }
            $open = @()
            $refusal = -1
            Start-Sleep -Seconds 125
            for ($i = 0; $i -lt ($TunnelCount + 2); $i++) {
                $c = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_LINKLAYER -TimeoutMs 2500
                if ($c.Ok) { $open += $c; continue }
                $refusal = $c.Status
                break
            }
            $addrs2 = @($open | ForEach-Object { $_.TunnelPa })
            Add-KnxEvidence -Note "second pass granted $($open.Count) of ${expected}: $($addrs2 -join ', ')"
            # The better pass decides, not the later one. Taking the second unconditionally handed the
            # result to whichever run a foreign client happened to hold a slot during, and charged the
            # device for it. Count first, then the refusal: Open-KnxConnection reports a timeout as
            # status -1, so a pass that ended without an answer says nothing about the refusal code and
            # must lose to a pass of the same size that ended in a real CONNECT_RESPONSE status.
            # Count, refusal status and address list are carried over together so they keep describing
            # the same pass.
            $takeSecond = $open.Count -gt $granted
            if (-not $takeSecond -and $open.Count -eq $granted -and $resultRefusal -lt 0 -and $refusal -ge 0) {
                $takeSecond = $true
                Add-KnxEvidence -Note "both passes granted $granted; the first ended without an answer, the second with a refusal status - judging the second"
            }
            if ($takeSecond) { $granted = $open.Count; $resultRefusal = $refusal; $resultAddrs = $addrs2 }
            else { Add-KnxEvidence -Note "judging the first pass: it granted $granted, the second $($open.Count)" }
        }
        # Naming the addresses that never appeared turns a shortfall from a bare result into a
        # lead: a slot reserved for a different client withholds its address, and a foreign client
        # holds one invisibly - neither is visible over KNXnet/IP, so the names are what let the
        # operator tell a configuration from a defect. Computed from the pass the result judges,
        # so the names belong to the run that is being reported on.
        $missing = @($distinct | Where-Object { $resultAddrs -notcontains $_ })
        if ($missing.Count -gt 0) {
            Add-KnxEvidence -Note "never offered: $($missing -join ', ') - reserved for another client, or held by one during the run"
        }
        Assert-KnxTrue ($granted -gt 0) 'no tunnel could be opened'
        Assert-KnxEqual $expected $granted "the device has $expected tunnel address(es) assignable to this client but grants $granted"
        Assert-KnxTrue ($resultRefusal -ge 0) "device accepted $granted tunnels without ever refusing"
        # Both codes are accepted here for the same reason as in H-5.1.2: this case reaches A limit
        # without setting up WHICH one. H-5.3.4 and H-5.3.5 are the cases that separate them.
        Assert-KnxStatusAny -Accept @($K.Error.E_NO_MORE_CONNECTIONS, $K.Error.E_NO_MORE_UNIQUE_CONNECTIONS) `
                            -Actual $resultRefusal `
                            -Message 'the tunnel past the configured maximum was refused with the wrong status'
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
            # 08_TSSH 5.1.4 p.65 and 03_08_04 Figure 6 p.27 (step 4.a) give E_CONNECTION_OPTION; the text of
            # step 4.a p.28 gives E_TUNNELLING_LAYER. This product follows the figure and the test specification.
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
            Add-KnxEvidence -Note 'expectation: only a second BUSMONITOR is refused (-BusmonExclusive not set); pass -BusmonExclusive if the firmware behaviour is intended'
            Assert-KnxTrue $link.Ok 'a normal link-layer tunnel was refused while the busmonitor was active - only a second BUSMONITOR may be refused. If that block is intended, run with -BusmonExclusive'
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
    if (-not $TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface (-TrafficIp) to generate bus traffic' }
    # Traffic tunnel first: the wait for a slot happens with no busmonitor open, so an exclusive
    # channel is not left unserviced while it runs.
    $src = Get-KnxTrafficConnection -Ip $TrafficIp


    $bm = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_BUSMONITOR
    Assert-KnxTrue $bm.Ok "busmonitor tunnel refused ($($bm.StatusName))"

    try {
        # NOT an assertion: a traffic interface whose slots are still held says nothing about the
        # device under test. Run standalone this never happens; run after another stage it does,
        # and failing here pointed the red line at the wrong device.
        if ($null -eq $src) {
            Set-KnxTestSkip "the traffic interface $TrafficIp granted no tunnel while we waited - its slots are still held by an earlier stage, so this says nothing about the busmonitor"
        }
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
# Shared printer, so the console carries the same buckets as the Markdown table and the JSON.
Write-KnxRunSummary
Write-Host ''
Write-Host "  Report: $($out.Markdown)" -ForegroundColor Cyan
Write-Host ''
if ($sum.Fail -gt 0) { exit 1 }
exit 0
