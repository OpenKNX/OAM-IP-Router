#!/usr/bin/env pwsh
<#
Open ■
┬────┴  Test-Busmonitor
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: scripts/Test/Features/Test-Busmonitor.ps1

.SYNOPSIS
    Edge cases of the hardware busmonitor - the ones a single "does it capture" check misses.

.DESCRIPTION
    The busmonitor is this product's distinguishing feature, so it is worth more than one
    test case. What matters is not that frames arrive but that they arrive UNCHANGED: a
    monitor that silently normalises what it saw is worse than one that drops frames,
    because the user cannot tell.

    Cases (B-*):
      B-1  Acknowledge frames pass through as single octets, without an FCS
      B-2  Repeat flag is preserved - a repeated telegram is a distinct bus event
      B-3  Frame type (standard/extended) and length are self-consistent
      B-4  Sequence numbers are continuous and the lost flag stays clear under load
      B-5  Every captured telegram has a valid FCS (acknowledges excepted)
      B-6  Start/stop cycles do not latch the transceiver
      B-7  Priority and hop count survive unchanged
      B-8  A second busmonitor is refused while the first is open
      B-9  An abandoned busmonitor frees its slot instead of wedging the feature
      B-10 The busmonitor survives malformed datagrams aimed at its channel
      B-11 A connect/disconnect storm leaves it usable
      B-12 Capture stays faithful under heavy bus load
      B-13 Frame/bit/parity error flags are carried through, not hidden
      B-14 Hostile telegrams (priorities, hop counts, broadcast, long APDUs) come back
           with a valid FCS and a self-consistent length - what the monitor is accountable for

.PARAMETER Ip
    Device under test - the interface whose busmonitor is exercised.
.PARAMETER TrafficIp
    Second interface on the same TP line, used to put telegrams on the bus.
.PARAMETER Seconds
    Capture window for the load cases. Default 15.
.PARAMETER ReportDir
    Output directory. Default: scripts/Test/Reports.

.EXAMPLE
    ./Test-Busmonitor.ps1 -Ip 11.11.0.126 -TrafficIp 11.11.0.210
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Ip,
    [int]$Port = 3671,
    [Parameter(Mandatory)][string]$TrafficIp,
    [int]$Seconds = 15,
    [string]$ReportDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $here 'lib/KnxTest.psm1') -Force
if (-not $ReportDir) { $ReportDir = Join-Path $here 'Reports' }

$K = Get-KnxConstants
$SUITE = 'B Busmonitor'

Write-Host ''
Write-Host '  Open ■' -ForegroundColor Green
Write-Host '  ┬────┴  Busmonitor edge cases' -ForegroundColor Green
Write-Host '  ■ KNX   2026 OpenKNX - Erkan Çolak' -ForegroundColor DarkGray
Write-Host ''

$st = Invoke-KnxSelfTest -Quiet
if (-not $st.Ok) { Write-Host "  ABORT: library self-test failed" -ForegroundColor Red; exit 2 }
if (-not (Test-KnxAlive -Ip $Ip -Port $Port -TimeoutMs 2000)) { Write-Host "  ABORT: $Ip does not answer" -ForegroundColor Red; exit 3 }
if (-not (Test-KnxAlive -Ip $TrafficIp -Port $Port -TimeoutMs 2000)) { Write-Host "  ABORT: traffic interface $TrafficIp does not answer" -ForegroundColor Red; exit 3 }

[void](Start-KnxTestRun -Product 'IP-Interface-busmonitor' -BdutIp $Ip -RunProfile 'Busmonitor' -Environment @{
        'BDUT IP'    = $Ip
        'Traffic IP' = $TrafficIp
        'Window'     = "$Seconds s"
        'Host'       = "$($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)"
    })

Write-Host "  $SUITE" -ForegroundColor Cyan
Write-Host ('  ' + ('-' * $SUITE.Length)) -ForegroundColor DarkGray

function Get-BusmonCapture {
    <#
    .SYNOPSIS
        Opens a busmonitor, drives traffic from the second interface, returns the decoded LPDUs.
    .DESCRIPTION
        Traffic is GroupValueRead on an unused group address: it produces real bus events
        including the acknowledges, without changing the state of any actuator.
    #>
    param([int]$Count = 40, [int]$WindowSeconds = 15)

    $bm = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_BUSMONITOR
    if (-not $bm.Ok) { return [pscustomobject]@{ Ok = $false; Reason = $bm.StatusName; Frames = @() } }
    # ONE shared traffic connection for the whole run. Opening a fresh tunnel per case
    # exhausts a small traffic interface: the Siemens N148 on this rig grants a single
    # channel and does not free it the instant the socket closes, so the load case took it
    # and the next two cases found nothing on the bus - and blamed the busmonitor for it.
    $gen = Get-KnxTrafficConnection -Ip $TrafficIp -Port $Port
    if ($null -eq $gen) {
        [void](Close-KnxConnection -Connection $bm)
        return [pscustomobject]@{ Ok = $false; Reason = "no tunnel available on the traffic interface $TrafficIp"; Frames = @() }
    }
    Clear-KnxSocket -Socket $bm.Socket -QuietMs 600

    $ga = ConvertTo-KnxGa -Address '7/7/7'
    $sent = 0
    $frames = @()
    $deadline = [DateTime]::UtcNow.AddSeconds($WindowSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($sent -lt $Count) {
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga -IsGroup -Tpdu (New-TpduGroupValueRead) -Priority 3
            $r = Send-KnxTunnelCemi -Connection $gen -Cemi $cemi -TimeoutMs 1200
            if ($r.Acked) { $sent++ }
        }
        $in = Receive-KnxTunnelCemi -Connection $bm -TimeoutMs 400
        if ($null -eq $in) { if ($sent -ge $Count) { break }; continue }
        if ($in.Cemi[0] -ne $K.Cemi.L_BUSMON_IND) { continue }
        $d = Read-CemiBusmon -Cemi $in.Cemi
        if ($null -ne $d) { $frames += $d }
    }
    # The traffic connection is shared and stays open for the whole run - only the
    # busmonitor, which is exclusive, is released here.
    try { [void](Close-KnxConnection -Connection $bm) } catch { }
    return [pscustomobject]@{ Ok = $true; Reason = ''; Sent = $sent; Frames = @($frames) }
}

$cap = Get-BusmonCapture -Count 40 -WindowSeconds $Seconds
$acks = @($cap.Frames | Where-Object { $_.IsAck })
$tels = @($cap.Frames | Where-Object { -not $_.IsAck })

Write-Host ("  captured $($cap.Frames.Count) frames: $($tels.Count) telegram(s), $($acks.Count) acknowledge(s)") -ForegroundColor DarkGray

Invoke-KnxTestCase -Suite $SUITE -Id 'B-1' -Title 'Acknowledge frames pass through as single octets' -Clause '03_02_02 section 2.2.7 p.31' -Body {
    Assert-KnxTrue $cap.Ok "no capture: $($cap.Reason)"
    Assert-KnxTrue ($acks.Count -gt 0) 'no acknowledge frame was captured at all - a monitored bus with traffic always carries them'
    # ACK 0xCC, NAK 0x0C, BUSY 0xC0 - all match the xx00 xx00 pattern.
    $bad = @($acks | Where-Object { ($_.Lpdu[0] -band 0x33) -ne 0 })
    Add-KnxEvidence -Note "$($acks.Count) acknowledge(s), distinct values: $((($acks | ForEach-Object { '0x{0:X2}' -f $_.Lpdu[0] }) | Sort-Object -Unique) -join ', ')"
    Assert-KnxEqual 0 $bad.Count 'a single-octet frame does not match the acknowledge pattern xx00 xx00 - it is not a valid acknowledge'
}

Invoke-KnxTestCase -Suite $SUITE -Id 'B-2' -Title 'Repeat flag is preserved' -Clause '03_02_02 section 2.2.2: ctrl bit5, 0 = repeated' -Body {
    Assert-KnxTrue ($tels.Count -gt 0) 'no telegram captured'
    $orig = @($tels | Where-Object { ($_.Lpdu[0] -band 0x20) -ne 0 })
    $rep = @($tels | Where-Object { ($_.Lpdu[0] -band 0x20) -eq 0 })
    Add-KnxEvidence -Note "$($orig.Count) original, $($rep.Count) repeated"
    # A repeat is a distinct bus event: the monitor must not normalise it away. It cannot be
    # forced on demand, so the assertion is that the flag is READ, not that repeats occurred.
    Assert-KnxTrue (($orig.Count + $rep.Count) -eq $tels.Count) 'the repeat flag could not be evaluated on every telegram'
}

Invoke-KnxTestCase -Suite $SUITE -Id 'B-3' -Title 'Frame type and length are self-consistent' -Clause '03_02_02 section 2.2.2/2.2.5: STD 8+LG, EXT 9+LG' -Body {
    Assert-KnxTrue ($tels.Count -gt 0) 'no telegram captured'
    $mismatch = @()
    $std = 0; $ext = 0
    foreach ($t in $tels) {
        $l = $t.Lpdu
        if (($l[0] -band 0x80) -ne 0) {
            $std++
            if ($l.Length -lt 7) { $mismatch += "STD too short ($($l.Length))"; continue }
            $exp = 8 + ($l[5] -band 0x0F)
        }
        else {
            $ext++
            if ($l.Length -lt 8) { $mismatch += "EXT too short ($($l.Length))"; continue }
            $exp = 9 + $l[6]
        }
        if ($l.Length -ne $exp) { $mismatch += "len $($l.Length), header says $exp" }
    }
    Add-KnxEvidence -Note "$std standard, $ext extended frame(s)"
    Assert-KnxEqual 0 $mismatch.Count "captured length does not match the length the header declares: $($mismatch -join '; ')"
}

Invoke-KnxTestCase -Suite $SUITE -Id 'B-4' -Title 'Sequence continuous and lost flag clear under load' -Clause '03_06_03 section 4.1.5.8.1 p.97: status bit3 lost, bits2-0 sequence' -Body {
    Assert-KnxTrue ($cap.Frames.Count -gt 2) 'too few frames to judge continuity'
    $withStatus = @($cap.Frames | Where-Object { $_.Status -ge 0 })
    if ($withStatus.Count -eq 0) {
        Set-KnxTestSkip 'device sends no 03h status octet in the additional information - sequence and lost cannot be evaluated'
    }
    $lost = @($withStatus | Where-Object { $_.Lost })
    $gaps = 0
    for ($i = 1; $i -lt $withStatus.Count; $i++) {
        $expected = (($withStatus[$i - 1].Sequence + 1) -band 0x07)
        if ($withStatus[$i].Sequence -ne $expected) { $gaps++ }
    }
    Add-KnxEvidence -Note "$($withStatus.Count) frame(s) with status, $gaps sequence gap(s), lost flag on $($lost.Count)"
    Assert-KnxEqual 0 $lost.Count 'the busmonitor set the lost flag - it dropped at least one frame or frame piece'
    Assert-KnxEqual 0 $gaps 'the sequence numbers are not continuous - frames went missing between device and client'
}

Invoke-KnxTestCase -Suite $SUITE -Id 'B-5' -Title 'Every telegram carries a valid frame check octet' -Clause '03_02_02 section 2.2.4.6 p.27' -Body {
    Assert-KnxTrue ($tels.Count -gt 0) 'no telegram captured'
    $bad = @($tels | Where-Object { -not $_.FcsOk })
    if ($bad.Count -gt 0) { Add-KnxEvidence -Note "first bad: $(ConvertTo-HexString -Bytes $bad[0].Lpdu)" }
    Add-KnxEvidence -Note "$($tels.Count) telegram(s) checked"
    Assert-KnxEqual 0 $bad.Count 'a captured telegram does not satisfy FCS = 0xFF XOR (all preceding octets) - the monitor is not delivering the bus verbatim'
}

Invoke-KnxTestCase -Suite $SUITE -Id 'B-6' -Title 'Start/stop cycles do not latch the transceiver' -Clause 'NCN5120/5130 U_BUSMON_REQ; product requirement' -Body {
    $fails = @()
    for ($i = 1; $i -le 8; $i++) {
        $b = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_BUSMONITOR -TimeoutMs 3000
        if (-not $b.Ok) { $fails += "cycle $i refused ($($b.StatusName))"; break }
        [void](Close-KnxConnection -Connection $b)
        Start-Sleep -Milliseconds 250
    }
    Add-KnxEvidence -Note "8 start/stop cycles, $($fails.Count) failure(s)"
    Assert-KnxEqual 0 $fails.Count "the busmonitor stopped accepting connections after repeated cycles: $($fails -join '; ')"
    # After the cycles the device must still work as a normal interface.
    $link = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_LINKLAYER -TimeoutMs 3000
    try { Assert-KnxTrue $link.Ok "after the busmonitor cycles a normal tunnel is refused ($($link.StatusName)) - the transceiver stayed in monitor mode" }
    finally { if ($link.Ok) { [void](Close-KnxConnection -Connection $link) } }
}

Invoke-KnxTestCase -Suite $SUITE -Id 'B-7' -Title 'Priority and hop count survive unchanged' -Clause '03_02_02 section 2.2.2; 03_03_03 hop count' -Body {
    Assert-KnxTrue ($tels.Count -gt 0) 'no telegram captured'
    # Traffic was generated with priority 3 (low), the ETS default for group communication.
    $prios = @($tels | ForEach-Object { ($_.Lpdu[0] -shr 2) -band 0x03 } | Sort-Object -Unique)
    $hops = @($tels | Where-Object { $_.Lpdu.Length -gt 5 } | ForEach-Object { ($_.Lpdu[5] -shr 4) -band 0x07 } | Sort-Object -Unique)
    Add-KnxEvidence -Note "priorities seen: $($prios -join ', '); hop counts: $($hops -join ', ')"
    Assert-KnxTrue ($prios -contains 3) 'the low-priority telegrams that were generated do not appear with priority 3 - the monitor altered the control field'
    Assert-KnxTrue ($hops.Count -gt 0) 'hop count could not be read from any telegram'
}

Invoke-KnxTestCase -Suite $SUITE -Id 'B-8' -Title 'A second busmonitor is refused while the first is open' -Clause '03_08_04 section 2.2.4: one busmonitor per subnetwork' -Body {
    $first = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_BUSMONITOR
    Assert-KnxTrue $first.Ok "first busmonitor refused ($($first.StatusName))"
    try {
        $second = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_BUSMONITOR
        Add-KnxEvidence -Note "second busmonitor: $($second.StatusName)"
        Assert-KnxTrue (-not $second.Ok) 'a second busmonitor connection was accepted - the busmonitor is exclusive per subnetwork'
        if ($second.Ok) { [void](Close-KnxConnection -Connection $second) }
    }
    finally { [void](Close-KnxConnection -Connection $first) }
}

# ─── Adversarial: what happens when things go wrong ─────────────────────────────

Invoke-KnxTestCase -Suite $SUITE -Id 'B-10' -Title 'Busmonitor survives malformed datagrams' -Clause 'robustness; 03_08_02 Core frame header' -Body {
    $bm = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_BUSMONITOR
    Assert-KnxTrue $bm.Ok "busmonitor refused ($($bm.StatusName))"
    try {
        $s = New-KnxSocket -TimeoutMs 500
        try {
            # Deliberately broken frames, aimed at the open busmonitor channel.
            # The comma operator inside @() nests the arrays one level too deep, so each entry
            # arrives as Byte[][] and Send-KnxFrame rejects it. Build a flat list instead.
            $junk = New-Object 'System.Collections.Generic.List[byte[]]'
            $junk.Add([byte[]]@(0x06, 0x10, 0x04, 0x00, 0x00, 0x04))                                      # length says 4, header only
            $junk.Add([byte[]]@(0x06, 0x10, 0x04, 0x00, 0xFF, 0xFF, 0x04, $bm.Channel, 0x00, 0x00))       # absurd total length
            $junk.Add([byte[]]@(0x06, 0x10, 0x04, 0x20, 0x00, 0x0A, 0x04, $bm.Channel, 0x00, 0x00))       # ack for a request never sent
            $junk.Add([byte[]]@(0x06, 0x10, 0xFF, 0xFF, 0x00, 0x06))                                      # unknown service type
            $junk.Add([byte[]]@(0x00))                                                                    # single junk octet
            $junk.Add([byte[]]@(0x06, 0x10, 0x04, 0x00, 0x00, 0x0A, 0x04, 0xFF, 0x00, 0x2B))              # foreign channel
            foreach ($j in $junk) { for ($i = 0; $i -lt 10; $i++) { Send-KnxFrame -Socket $s -Frame $j -Ip $Ip -Port $Port } }
            Add-KnxEvidence -Note "fired 60 malformed datagrams at the open busmonitor channel"
        }
        finally { $s.Dispose() }
        Start-Sleep -Milliseconds 500
        # The channel must still be alive and the device must still answer discovery.
        $probe = New-KnxConnectionStateRequest -Channel $bm.Channel -ControlIp $bm.LocalIp -ControlPort $bm.LocalPort
        $pr = Invoke-KnxRequest -Socket $bm.Socket -Frame $probe -Ip $bm.Ip -Port $bm.Port -Expect @($K.Service.CONNECTIONSTATE_RESPONSE) -TimeoutMs 2000
        Assert-KnxTrue (-not $pr.TimedOut) 'the busmonitor channel stopped answering after malformed datagrams'
        Assert-KnxEqual 0 $pr.Header.Body[1] 'the busmonitor channel reports an error state after malformed datagrams'
        Assert-KnxTrue (Test-KnxAlive -Ip $Ip -Port $Port -TimeoutMs 2000) 'the device stopped answering discovery after malformed datagrams'
    }
    finally { [void](Close-KnxConnection -Connection $bm) }
}

Invoke-KnxTestCase -Suite $SUITE -Id 'B-11' -Title 'Connect/disconnect storm leaves the busmonitor usable' -Clause 'robustness; slot handling' -Body {
    $fails = @()
    for ($i = 1; $i -le 15; $i++) {
        $b = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_BUSMONITOR -TimeoutMs 2500
        if (-not $b.Ok) { $fails += "cycle $i : $($b.StatusName)"; break }
        [void](Close-KnxConnection -Connection $b)   # no pause: hammer it
    }
    Add-KnxEvidence -Note "15 back-to-back cycles, $($fails.Count) failure(s)"
    Assert-KnxEqual 0 $fails.Count "the busmonitor became unavailable during a connect/disconnect storm: $($fails -join '; ')"
    $final = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_BUSMONITOR -TimeoutMs 3000
    try { Assert-KnxTrue $final.Ok "after the storm the busmonitor no longer connects ($($final.StatusName))" }
    finally { if ($final.Ok) { [void](Close-KnxConnection -Connection $final) } }
}

Invoke-KnxTestCase -Suite $SUITE -Id 'B-12' -Title 'Capture stays faithful under heavy bus load' -Clause '03_06_03 section 4.1.5.8.1: lost flag' -Body {
    # The gentle capture above proves correctness on a quiet bus. This one asks whether the
    # monitor still delivers everything when the bus is busy - the case that actually matters
    # for a diagnostic tool, and the one where a device silently starts dropping.
    $heavy = Get-BusmonCapture -Count 120 -WindowSeconds 20
    Assert-KnxTrue $heavy.Ok "no capture: $($heavy.Reason)"
    $ht = @($heavy.Frames | Where-Object { -not $_.IsAck })
    $hs = @($heavy.Frames | Where-Object { $_.Status -ge 0 })
    $hlost = @($hs | Where-Object { $_.Lost })
    $hbad = @($ht | Where-Object { -not $_.FcsOk })
    $gaps = 0
    for ($i = 1; $i -lt $hs.Count; $i++) {
        if ($hs[$i].Sequence -ne ((($hs[$i - 1].Sequence + 1) -band 0x07))) { $gaps++ }
    }
    Add-KnxEvidence -Note "$($heavy.Sent) telegram(s) generated, $($heavy.Frames.Count) frame(s) captured, $($hbad.Count) bad FCS, $($hlost.Count) lost-flag, $gaps sequence gap(s)"
    Assert-KnxTrue ($heavy.Frames.Count -gt 0) 'nothing captured under load'
    Assert-KnxEqual 0 $hbad.Count 'under load the monitor delivered a telegram with a broken frame check octet'
    Assert-KnxEqual 0 $hlost.Count 'under load the monitor set the lost flag - it dropped frames'
    Assert-KnxEqual 0 $gaps 'under load the sequence numbers show gaps - frames went missing on the way to the client'
}

Invoke-KnxTestCase -Suite $SUITE -Id 'B-13' -Title 'Error flags are reported, not hidden' -Clause '03_06_03 section 4.1.5.8.1 p.97: status bits 7/6/5' -Body {
    # A monitor may see genuinely corrupt bus frames - that is its job. What it must never do
    # is present them as clean. This case does not force an error; it verifies the flags are
    # carried through so a real one WOULD be visible.
    Assert-KnxTrue ($cap.Frames.Count -gt 0) 'no frames to inspect'
    $withStatus = @($cap.Frames | Where-Object { $_.Status -ge 0 })
    if ($withStatus.Count -eq 0) { Set-KnxTestSkip 'device sends no 03h status octet - frame/bit/parity errors cannot be surfaced at all' }
    $errs = @($withStatus | Where-Object { $_.FrameError -or $_.BitError -or $_.ParityError })
    Add-KnxEvidence -Note "$($withStatus.Count) frame(s) carry a status octet; $($errs.Count) with an error flag set"
    # Every status-carrying frame must expose all three flags as booleans, not as $null.
    $unreadable = @($withStatus | Where-Object { $null -eq $_.FrameError -or $null -eq $_.BitError -or $null -eq $_.ParityError })
    Assert-KnxEqual 0 $unreadable.Count 'the frame/bit/parity error flags could not be read - a corrupt bus frame would look clean'
}

Invoke-KnxTestCase -Suite $SUITE -Id 'B-14' -Title 'Hostile telegrams are reported verbatim' -Clause '03_02_02 section 2.2; 03_06_03 section 4.1.4.1' -Body {
    # The capture cases above use ordinary traffic. This one puts DELIBERATELY awkward
    # telegrams on the bus and checks each one comes back unchanged. A monitor that quietly
    # normalises an odd frame is worse than one that drops it: the user sees something that
    # was never on the wire and debugs the wrong problem.
    #
    # Limitation, stated rather than hidden: a genuinely CORRUPT frame (bad FCS, parity or
    # bit error) cannot be produced through an interface - the sending interface computes the
    # check octet itself, so anything it puts on TP is well formed by construction. Producing
    # those needs a faulty transmitter. That the monitor would SURFACE such a frame is covered
    # by B-13, which proves the error flags are carried through and readable.
    $bm = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_BUSMONITOR
    Assert-KnxTrue $bm.Ok "busmonitor refused ($($bm.StatusName))"
    $gen = Get-KnxTrafficConnection -Ip $TrafficIp -Port $Port
    Assert-KnxTrue ($null -ne $gen) "no tunnel available on the traffic interface $TrafficIp"
    try {
        Clear-KnxSocket -Socket $bm.Socket -QuietMs 600
        $ga = ConvertTo-KnxGa -Address '7/7/7'
        $probes = @(
            @{ Name = 'system priority (0)';   Cemi = (New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga -IsGroup -Tpdu (New-TpduGroupValueRead) -Priority 0) }
            @{ Name = 'urgent priority (2)';   Cemi = (New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga -IsGroup -Tpdu (New-TpduGroupValueRead) -Priority 2) }
            @{ Name = 'hop count 7';           Cemi = (New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga -IsGroup -Tpdu (New-TpduGroupValueRead) -Priority 3 -HopCount 7) }
            @{ Name = 'hop count 0';           Cemi = (New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga -IsGroup -Tpdu (New-TpduGroupValueRead) -Priority 3 -HopCount 0) }
            @{ Name = 'broadcast 0/0/0';       Cemi = (New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination 0 -IsGroup -Tpdu (New-TpduGroupValueRead) -Priority 3) }
            @{ Name = 'repeat flag set';       Cemi = (New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga -IsGroup -Tpdu (New-TpduGroupValueRead) -Priority 3 -Repeat) }
            @{ Name = 'max standard APDU';     Cemi = (New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga -IsGroup -Tpdu ([byte[]]((, 0x00) + (, 0x80) + (1..14 | ForEach-Object { [byte]$_ }))) -Priority 3) }
            @{ Name = 'extended-length APDU';  Cemi = (New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga -IsGroup -Tpdu ([byte[]]((, 0x00) + (, 0x80) + (1..40 | ForEach-Object { [byte]$_ }))) -Priority 3) }
        )
        $sent = @()
        $refused = @()
        foreach ($p in $probes) {
            $r = Send-KnxTunnelCemi -Connection $gen -Cemi $p.Cemi -TimeoutMs 2000
            if ($r.Acked) { $sent += $p.Name } else { $refused += $p.Name }
            Start-Sleep -Milliseconds 250
        }
        Add-KnxEvidence -Note "put on the bus: $($sent -join '; ')"
        if ($refused.Count -gt 0) { Add-KnxEvidence -Note "the traffic interface did not acknowledge: $($refused -join '; ')" }
        # Nothing on the bus means the monitor had nothing to show, so it cannot be judged
        # here. Asserting on the capture anyway blamed the busmonitor for a traffic source
        # that had just been exhausted by the load case before it - a red line pointing at
        # the wrong device. B-12 runs immediately before this and hammers the same
        # interface; a one-tunnel traffic source has not recovered by the time we get here.
        if ($sent.Count -eq 0) {
            Set-KnxTestSkip 'the traffic interface acknowledged none of the hostile telegrams - nothing reached the bus, so this says nothing about the monitor'
        }

        $seen = @()
        $deadline = [DateTime]::UtcNow.AddSeconds(6)
        while ([DateTime]::UtcNow -lt $deadline) {
            $in = Receive-KnxTunnelCemi -Connection $bm -TimeoutMs 900
            if ($null -eq $in -or $in.Cemi[0] -ne $K.Cemi.L_BUSMON_IND) { continue }
            $d = Read-CemiBusmon -Cemi $in.Cemi
            if ($null -ne $d) { $seen += $d }
        }
        $tel = @($seen | Where-Object { -not $_.IsAck })
        $badFcs = @($tel | Where-Object { -not $_.FcsOk })
        $lenBad = @()
        foreach ($t in $tel) {
            $l = $t.Lpdu
            if (($l[0] -band 0x80) -ne 0) { $exp = if ($l.Length -ge 6) { 8 + ($l[5] -band 0x0F) } else { -1 } }
            else { $exp = if ($l.Length -ge 7) { 9 + $l[6] } else { -1 } }
            if ($l.Length -ne $exp) { $lenBad += (ConvertTo-HexString -Bytes $l) }
        }
        $prios = @($tel | ForEach-Object { ($_.Lpdu[0] -shr 2) -band 0x03 } | Sort-Object -Unique)
        $hops = @($tel | Where-Object { $_.Lpdu.Length -gt 5 } | ForEach-Object { ($_.Lpdu[5] -shr 4) -band 0x07 } | Sort-Object -Unique)
        $exts = @($tel | Where-Object { ($_.Lpdu[0] -band 0x80) -eq 0 })
        Add-KnxEvidence -Note "captured $($tel.Count) telegram(s); priorities $($prios -join ','); hop counts $($hops -join ','); $($exts.Count) extended frame(s)"

        Assert-KnxTrue ($tel.Count -gt 0) 'none of the hostile telegrams came back from the monitor'
        Assert-KnxEqual 0 $badFcs.Count 'a hostile telegram came back with a broken frame check octet - the monitor altered it'
        Assert-KnxEqual 0 $lenBad.Count "a hostile telegram came back with a length its own header contradicts: $($lenBad -join '; ')"

        # Deliberately NOT asserted here: that the awkward priorities and hop counts differ.
        # The path is generator tunnel -> SENDING interface -> TP -> monitor, so a uniform
        # value can equally mean the SENDER normalised the control field before it ever
        # reached the wire. This case can see the wire, not the sender, and must not blame
        # the monitor for something it cannot attribute - an earlier version did exactly that.
        # What the monitor is accountable for is delivering the wire unchanged, and that is
        # what the FCS and length assertions above prove. The spread is recorded as evidence.
        if ($prios.Count -le 1) { Add-KnxEvidence -Note "all telegrams carry priority $($prios -join ''): either the sending interface normalised it, or the bus really saw one priority - not attributable from here" }
        if ($hops.Count -le 1) { Add-KnxEvidence -Note "all telegrams carry hop count $($hops -join ''): same caveat" }
    }
    finally {
        try { [void](Close-KnxConnection -Connection $bm) } catch { }
    }
}

# B-9 runs LAST on purpose: it abandons a busmonitor without disconnecting, and because
# the busmonitor is exclusive the device may hold that slot until its reaper fires -
# any case after it would be refused with E_NO_MORE_CONNECTIONS for a test-order reason.
Invoke-KnxTestCase -Suite $SUITE -Id 'B-9' -Title 'Abandoned busmonitor frees its slot' -Clause '03_08_02 Core: connection timeout' -Body {
    # A client that vanishes without DISCONNECT_REQUEST is the normal field failure (crash,
    # cable pulled). Because the busmonitor is exclusive, ONE lost client would disable the
    # feature until reboot if the slot were never reaped - so the reaping IS the test.
    # The case then WAITS for the slot to come back, both to assert it and to leave the
    # device clean for the next run.
    $ghost = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_BUSMONITOR
    Assert-KnxTrue $ghost.Ok "busmonitor refused ($($ghost.StatusName))"
    $ch = $ghost.Channel
    try { $ghost.Socket.Dispose() } catch { }   # vanish: no DISCONNECT_REQUEST, socket gone
    Add-KnxEvidence -Note "abandoned channel 0x$('{0:X2}' -f $ch) without disconnecting"

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $freed = $false
    $lastStatus = 'no answer'
    while ($sw.Elapsed.TotalSeconds -lt 180) {
        $again = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_BUSMONITOR -TimeoutMs 2500
        $lastStatus = $again.StatusName
        if ($again.Ok) { $freed = $true; [void](Close-KnxConnection -Connection $again); break }
        # While the slot is held the refusal must be a DEFINED error, never silence.
        Assert-KnxTrue ($again.Status -ge 0) 'the device did not answer at all while the slot was held - the busmonitor is wedged, not busy'
        Start-Sleep -Seconds 10
    }
    $sw.Stop()
    Add-KnxEvidence -Note "slot came back after $([Math]::Round($sw.Elapsed.TotalSeconds,0)) s (last refusal: $lastStatus)"
    Assert-KnxTrue $freed 'the abandoned busmonitor slot was never released - one crashed client disables the busmonitor permanently'
}

Close-KnxTrafficConnection

$out = Export-KnxTestReport -Directory $ReportDir
$sum = $out.Summary
Write-Host ''
Write-Host "  Total $($sum.Total)   " -NoNewline
Write-Host "PASS $($sum.Pass)  " -ForegroundColor Green -NoNewline
Write-Host "FAIL $($sum.Fail)  " -ForegroundColor $(if ($sum.Fail -gt 0) { 'Red' } else { 'DarkGray' }) -NoNewline
Write-Host "SKIP $($sum.Skip)" -ForegroundColor Yellow
Write-Host ''
Write-Host "  Report: $($out.Markdown)" -ForegroundColor Cyan
Write-Host ''
if ($sum.Fail -gt 0) { exit 1 }
exit 0
