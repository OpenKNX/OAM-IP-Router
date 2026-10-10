#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Watch-EtsSession
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Tools/Watch-EtsSession.ps1

<#
.SYNOPSIS
    Records a whole ETS session from two independent interfaces at once: one in busmonitor mode and one
    as a group monitor, and reports which memory write procedure ETS used.

.DESCRIPTION
    Two views of the same line, neither of them the device being programmed and neither the interface ETS
    programs through:

      Busmonitor    raw LPDUs including the layer-2 acknowledges and frames that failed their check octet.
                    This is what the line carried.
      Group monitor a link-layer tunnel, so cEMI L_Data.ind as a normal client receives them. This is what
                    an interface delivers.

    Recording both is how a difference between "on the line" and "delivered" becomes visible at all.

    Written for a session that runs while nobody watches the console, so it differs from
    Watch-EtsDownload.ps1 in three ways that were paid for on 2026-09-21:

      - Both files are written and flushed as the telegrams arrive. The older tool collected everything in
        memory and wrote at the end, so stopping it early lost the whole capture.
      - It stops on request: create the file named by -StopFile and it closes both connections properly and
        prints its summary. Killing the process instead leaves the busmonitor connection occupied on the
        witness until its 120 s heartbeat timeout, which then refuses the next capture.
      - The group-monitor tunnel is kept alive the way 03_08_02 5.4 p.14 requires of a client: every
        datagram is acknowledged and a CONNECTIONSTATE_REQUEST goes out when the connection has been quiet.
        A client that only listens loses its tunnel after 120 s and records silence afterwards.

    The result covers the extended memory services as well. A download seen on 2026-09-21 used
    A_MemoryExtended_Write exclusively - 68 writes, each answered - and the older tool called that
    "not verified on the wire" because it only looked at the classic services.

.PARAMETER BusmonIp
    Interface put into busmonitor mode. Must not be the device under test nor the one ETS uses.

.PARAMETER GroupMonIp
    Interface used as a group monitor, with the same restriction.

.PARAMETER Seconds
    Upper bound for the recording. Default 3600.

.PARAMETER OutDir
    Where the two CSV files and the summary are written. Default: scripts/Test/Reports.

.PARAMETER StopFile
    Creating this file ends the recording cleanly. Default: <OutDir>/ets-session.stop.

.PARAMETER Port
    KNXnet/IP port of both interfaces. Default 3671.

.EXAMPLE
    pwsh Tools/Watch-EtsSession.ps1 -BusmonIp 11.11.0.5 -GroupMonIp 11.11.0.2
    Records with Siemens as busmonitor and MDT as group monitor until the stop file appears.

.NOTES
    PowerShell 5.1 compatible, UTF-8 with a byte order mark. Reads only - nothing is put on the line except the two
    connects and the acknowledges a client owes.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BusmonIp,
    [Parameter(Mandatory)][string]$GroupMonIp,
    [int]$Seconds = 3600,
    [string]$OutDir = '',
    [string]$StopFile = '',
    [int]$Port = 3671
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path (Split-Path -Parent $here) 'lib/KnxTest.psm1') -Force -DisableNameChecking
$K = Get-KnxConstants

if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $here) 'Reports' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bmPath = Join-Path $OutDir "ets-session_${stamp}_busmon.csv"
$gmPath = Join-Path $OutDir "ets-session_${stamp}_groupmon.csv"
if (-not $StopFile) { $StopFile = Join-Path $OutDir 'ets-session.stop' }
if (Test-Path $StopFile) { Remove-Item $StopFile -Force }

# --- service names, by the APCI's service part; the low bits of the 10-bit value carry the octet count
# --- for the memory services, so those are compared on the service part only (03_03_07).
function Get-ServiceName {
    param([byte[]]$Tpdu)
    if ($null -eq $Tpdu -or $Tpdu.Length -lt 2) { return $null }
    $apci = ((([int]$Tpdu[0]) -band 0x03) -shl 8) -bor ([int]$Tpdu[1])
    # The memory services carry the octet count in the low bits, so they are compared on the service part.
    # A_GroupValue_* live at 0x000/0x040/0x080 and must not be mistaken for them (they were, in the first
    # version of this table: 115 group telegrams were counted as A_Memory_Read).
    switch ($apci -band 0x3C0) {
        0x000 { return 'GroupValueRead' }
        0x040 { return 'GroupValueResponse' }
        0x080 { return 'GroupValueWrite' }
        0x200 { return 'MemoryRead' }
        0x240 { return 'MemoryResponse' }
        0x280 { return 'MemoryWrite' }
    }
    switch ($apci) {
        0x1FB { return 'MemoryExtWrite' }
        0x1FC { return 'MemoryExtWriteResponse' }
        0x1FD { return 'MemoryExtRead' }
        0x1FE { return 'MemoryExtReadResponse' }
        0x3D5 { return 'PropertyValueRead' }
        0x3D6 { return 'PropertyValueResponse' }
        0x3D7 { return 'PropertyValueWrite' }
        0x3D8 { return 'PropertyDescriptionRead' }
        0x3D9 { return 'PropertyDescriptionResponse' }
        0x300 { return 'DeviceDescriptorRead' }
        0x340 { return 'DeviceDescriptorResponse' }
        0x380 { return 'Restart' }
        0x0C0 { return 'IndividualAddressWrite' }
    }
    return ('APCI_{0:X3}' -f $apci)
}

$counts = @{}
function Add-Count { param([string]$Name) if ($Name) { if (-not $counts.ContainsKey($Name)) { $counts[$Name] = 0 }; $counts[$Name]++ } }

Set-Content -Path $bmPath -Value 'Time,Source,Destination,Service,FcsOk,Lpdu' -Encoding UTF8
Set-Content -Path $gmPath -Value 'Time,MessageCode,Source,Destination,IsGroup,Service,Tpdu' -Encoding UTF8

$bm = Open-KnxConnection -Ip $BusmonIp -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_BUSMONITOR
if (-not $bm.Ok) { Write-Host "  busmonitor refused by $BusmonIp : $($bm.StatusName)" -ForegroundColor Red; exit 2 }
$gm = Open-KnxConnection -Ip $GroupMonIp -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION -Layer $K.Layer.TUNNEL_LINKLAYER
if (-not $gm.Ok) {
    Write-Host "  group monitor refused by $GroupMonIp : $($gm.StatusName)" -ForegroundColor Red
    [void](Close-KnxConnection -Connection $bm); exit 2
}

Write-Host ("  busmonitor    {0}" -f $BusmonIp) -ForegroundColor Cyan
Write-Host ("  group monitor {0}, tunnel address {1}" -f $GroupMonIp, $gm.TunnelPa) -ForegroundColor Cyan
Write-Host ("  writing {0}" -f $bmPath)
Write-Host ("  writing {0}" -f $gmPath)
Write-Host ("  stop with: New-Item -ItemType File '{0}'" -f $StopFile) -ForegroundColor Yellow

$nBm = 0; $nGm = 0; $lost = 0; $fcsBad = 0
$deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
try {
    while ([DateTime]::UtcNow -lt $deadline -and -not (Test-Path $StopFile)) {

        # Sync-KnxTunnel is a pump: what its heartbeat catches is acknowledged and parked, not returned.
        # A capture is the one consumer with no Receive-KnxTunnelCemi behind it, so it takes the parked
        # frames itself - otherwise every frame inside a heartbeat window is missing from the CSV.
        $r = Sync-KnxTunnel -Connection $bm -Ms 250
        # foreach with a unary comma, not a pipeline: a byte[] sent through ForEach-Object is unrolled
        # into its individual octets, and the decode below would then be handed single numbers.
        # Sync's Frames is a VIEW of what it parked, so taking both would write every telegram twice.
        # The queue is the single source here.
        $bmFrames = @()
        foreach ($rec in @(Read-KnxTunnelParked -Connection $bm)) { $bmFrames += , ([byte[]]$rec.Cemi) }
        foreach ($f in $bmFrames) {
            $b = Read-CemiBusmon -Cemi $f
            if ($null -eq $b) { continue }
            if ($b.Lost) { $lost++ }
            if (-not $b.FcsOk) { $fcsBad++ }
            $l = $b.Lpdu
            $src = ''; $dst = ''; $svc = ''
            # 03_02_02 2.2.2 p.26: bit 7 of the control octet tells the two layouts apart. Standard is
            # CTRL SA(2) DA(2) NPCI TPDU FCS, extended CTRL CTRLE SA(2) DA(2) LG TPDU FCS -- every field
            # after the control octet shifts by one, so one layout for both named the wrong addresses and
            # read the service out of the address octets.
            $ext = (($l[0] -band 0x80) -eq 0)
            $o = if ($ext) { 1 } else { 0 }
            if (-not $b.IsAck -and $l.Length -ge (8 + $o)) {
                $src = '{0}.{1}.{2}' -f (($l[1 + $o] -shr 4) -band 0x0F), ($l[1 + $o] -band 0x0F), $l[2 + $o]
                $dst = '{0:X2}{1:X2}' -f $l[3 + $o], $l[4 + $o]
                $svc = Get-ServiceName -Tpdu ([byte[]]$l[(6 + $o)..($l.Length - 2)])
                Add-Count $svc
            }
            $hex = ($l | ForEach-Object { $_.ToString('X2') }) -join ' '
            Add-Content -Path $bmPath -Encoding UTF8 -Value ('{0},{1},{2},{3},{4},{5}' -f (Get-Date -Format 'HH:mm:ss.fff'), $src, $dst, $svc, $b.FcsOk, $hex)
            $nBm++
        }
        if ($r.Disconnected) { Write-Host '  the busmonitor connection was ended by the device' -ForegroundColor Yellow; break }

        $g = Sync-KnxTunnel -Connection $gm -Ms 250
        $gmFrames = @()
        foreach ($rec in @(Read-KnxTunnelParked -Connection $gm)) { $gmFrames += , ([byte[]]$rec.Cemi) }
        foreach ($f in $gmFrames) {
            $ld = Read-CemiLData -Cemi $f
            if ($null -eq $ld) { continue }
            $svc = Get-ServiceName -Tpdu $ld.Tpdu
            $hex = ($ld.Tpdu | ForEach-Object { $_.ToString('X2') }) -join ' '
            Add-Content -Path $gmPath -Encoding UTF8 -Value ('{0},{1:X2},{2},{3:X4},{4},{5},{6}' -f `
                (Get-Date -Format 'HH:mm:ss.fff'), $f[0], (ConvertFrom-KnxPa -Raw $ld.Source), $ld.Destination, $ld.IsGroup, $svc, $hex)
            $nGm++
        }
        if ($g.Disconnected) { Write-Host '  the group monitor tunnel was ended by the device' -ForegroundColor Yellow; break }

        # 03_08_02 5.4 p.14 puts the heartbeat on the client. Acknowledging what the device pushes does not
        # discharge it: a client that sends nothing of its own is disconnected after 120 s.
        [void](Update-KnxTunnelHeartbeat -Connection $gm)
    }
}
finally {
    # What the last heartbeat or the loop's final pass parked is still on the connections. Closing
    # without taking it discards the tail of the capture - the one part nobody notices is missing.
    foreach ($pair in @(@{ C = $bm; P = $bmPath; Bm = $true }, @{ C = $gm; P = $gmPath; Bm = $false })) {
        foreach ($rec in @(Read-KnxTunnelParked -Connection $pair.C)) {
            $tail = [byte[]]$rec.Cemi
            if ($pair.Bm) {
                $b2 = Read-CemiBusmon -Cemi $tail
                if ($null -eq $b2) { continue }
                $hex2 = ($b2.Lpdu | ForEach-Object { $_.ToString('X2') }) -join ' '
                Add-Content -Path $pair.P -Encoding UTF8 -Value ('{0},,,,{1},{2}' -f (Get-Date -Format 'HH:mm:ss.fff'), $b2.FcsOk, $hex2)
                $nBm++
            }
            else {
                $ld2 = Read-CemiLData -Cemi $tail
                if ($null -eq $ld2) { continue }
                $hex2 = ($ld2.Tpdu | ForEach-Object { $_.ToString('X2') }) -join ' '
                Add-Content -Path $pair.P -Encoding UTF8 -Value ('{0},{1:X2},{2},{3:X4},{4},,{5}' -f `
                    (Get-Date -Format 'HH:mm:ss.fff'), $tail[0], (ConvertFrom-KnxPa -Raw $ld2.Source), $ld2.Destination, $ld2.IsGroup, $hex2)
                $nGm++
            }
        }
    }
    foreach ($c in @($bm, $gm)) { try { [void](Close-KnxConnection -Connection $c) } catch { } }
    if (Test-Path $StopFile) { Remove-Item $StopFile -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
$dropBm = 0; $dropGm = 0
if ($null -ne $bm.PSObject.Properties['PendingDropped']) { $dropBm = [int]$bm.PendingDropped }
if ($null -ne $gm.PSObject.Properties['PendingDropped']) { $dropGm = [int]$gm.PendingDropped }
if (($dropBm + $dropGm) -gt 0) {
    Write-Host ("  NOTE: the parked queue overflowed - {0} busmonitor and {1} group monitor frame(s) were dropped." -f $dropBm, $dropGm) -ForegroundColor Yellow
    Write-Host '        The capture below is short by that many telegrams.' -ForegroundColor Yellow
}
Write-Host ("  busmonitor    {0} frames ({1} with a bad check octet, {2} marked lost)" -f $nBm, $fcsBad, $lost)
Write-Host ("  group monitor {0} frames" -f $nGm)
Write-Host ''
Write-Host '  Management services seen on the line' -ForegroundColor Cyan
foreach ($k in ($counts.Keys | Sort-Object)) { Write-Host ("    {0,-28} {1}" -f $k, $counts[$k]) }

function Get-Count { param([string]$Name) if ($counts.ContainsKey($Name)) { return $counts[$Name] } return 0 }
$extW = Get-Count 'MemoryExtWrite'; $extWr = Get-Count 'MemoryExtWriteResponse'
$memW = Get-Count 'MemoryWrite';    $memR  = Get-Count 'MemoryRead'; $memResp = Get-Count 'MemoryResponse'
Write-Host ''
if ($extW -gt 0) {
    $result = if ($extWr -ge $extW) { 'every write was answered' } else { "$extWr answers for $extW writes - not every write was confirmed" }
    Write-Host ("  ETS used the EXTENDED memory services: {0} writes, {1} answers ({2})." -f $extW, $extWr, $result) -ForegroundColor Green
    Write-Host ('  A_MemoryExtended_Write carries its own response (03_03_07), so the classic verify mode of' )
    Write-Host ('  03_05_02 3.16.3 is not involved either way.')
}
elseif ($memW -gt 0 -and $memResp -gt 0) {
    Write-Host '  ETS used DMP_MemWrite_RCoV: verify mode on, every write answered (03_05_02 3.16.3 p.101-102).' -ForegroundColor Green
}
elseif ($memW -gt 0 -and $memR -gt 0) {
    Write-Host '  ETS used DMP_MemWrite_RCo: a read after the blocks, no verify mode (03_05_02 3.16.2 p.100-101).' -ForegroundColor Green
}
elseif ($memW -gt 0 -or $extW -gt 0) {
    Write-Host '  ETS wrote without reading anything back: the download is not verified on the wire.' -ForegroundColor Yellow
}
else {
    Write-Host '  No memory write was seen - this capture holds no download.' -ForegroundColor Yellow
}
