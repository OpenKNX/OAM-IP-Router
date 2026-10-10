#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Watch-EtsDownload
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Tools/Watch-EtsDownload.ps1

<#
.SYNOPSIS
    Watches a TP line with a hardware busmonitor while ETS downloads a device, and reports which
    memory write procedure ETS used.

.DESCRIPTION
    The device answers a memory write in verify mode; the answer has to carry what was stored. Which
    of the two procedures of 03_05_02 3.16 ETS runs decides how much that costs on a flash device:

      DMP_MemWrite_RCoV (3.16.3, p.101-102)  Verify Mode is switched on with a write of
                                             PID_DEVICE_CONTROL bit 2, then every A_Memory_Write is
                                             answered with an A_Memory_Response.
      DMP_MemWrite_RCo  (3.16.2, p.100-101)  No verify mode; an A_Memory_Read after every block.

    The tool counts both shapes and prints which one it saw. It only listens - nothing is sent to the
    line except the busmonitor connect, so it cannot disturb the download it watches.

    The witness must be a SECOND interface on the same TP line, not the device being programmed, and
    not the interface ETS is programming through: a busmonitor connection occupies the interface.

.PARAMETER WitnessIp
    Interface with a hardware busmonitor that watches the line.

.PARAMETER Seconds
    How long to listen. Default 300.

.PARAMETER Port
    KNXnet/IP port of the witness. Default 3671.

.PARAMETER Csv
    Also write every decoded management telegram to this file.

.EXAMPLE
    pwsh Tools/Watch-EtsDownload.ps1 -WitnessIp 11.11.0.5 -Seconds 600
    Starts the monitor, then download the device in ETS.

.NOTES
    Needs lib/KnxTest.psm1 from this repository. Reads only; the group monitor of ETS shows the same
    telegrams, this tool just counts and judges them.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WitnessIp,
    [int]$Seconds = 300,
    [int]$Port = 3671,
    [string]$Csv = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path (Split-Path -Parent $here) 'lib/KnxTest.psm1') -Force -DisableNameChecking
$K = Get-KnxConstants

# APCIs that matter here. The 10-bit value carries the octet count in its low bits for the memory
# services, so compare on the service part only.
$SERVICE = @{
    0x200 = 'MemoryRead'; 0x240 = 'MemoryResponse'; 0x280 = 'MemoryWrite'
    0x1FB = 'MemoryExtWrite'; 0x1FC = 'MemoryExtWriteResponse'; 0x1FD = 'MemoryExtRead'; 0x1FE = 'MemoryExtReadResponse'
    0x3D5 = 'PropertyValueRead'; 0x3D6 = 'PropertyValueResponse'; 0x3D7 = 'PropertyValueWrite'
}

function Get-Tpdu {
    <#
    .SYNOPSIS
        The TPDU of a raw TP1 LPDU, or $null when the frame is too short or an acknowledge.
    .DESCRIPTION
        Standard frame: CTRL SA(2) DA(2) [AT|hop|LG] TPDU FCS, total 8+LG, so the TPDU is LG+1 octets
        at offset 6. Extended: CTRL CTRLE SA(2) DA(2) LG TPDU FCS, total 9+LG, TPDU at offset 7
        (03_02_02 2.2.4/2.2.5 p.27-29).
    #>
    param([byte[]]$Lpdu)
    if ($null -eq $Lpdu -or $Lpdu.Length -lt 8) { return $null }
    if (($Lpdu[0] -band 0x80) -ne 0) { $lg = $Lpdu[5] -band 0x0F; $off = 6 } else { $lg = $Lpdu[6]; $off = 7 }
    $end = $off + $lg
    if ($lg -lt 1 -or $end -ge $Lpdu.Length) { return $null }
    return [byte[]]$Lpdu[$off..$end]
}

function Get-Service {
    <#
    .SYNOPSIS
        Service name and octet count of a TPDU, or $null when it carries no application PDU.
    #>
    param([byte[]]$Tpdu)
    if ($null -eq $Tpdu -or $Tpdu.Length -lt 2) { return $null }
    if (($Tpdu[0] -band 0x80) -ne 0 -and ($Tpdu[0] -band 0x40) -eq 0) { return $null } # T_ACK / T_Connect
    $apci = ((([int]$Tpdu[0]) -band 0x03) -shl 8) -bor ([int]$Tpdu[1])
    foreach ($svc in @(0x200, 0x240, 0x280)) {
        if (($apci -band 0x3C0) -eq $svc) { return [pscustomobject]@{ Name = $SERVICE[$svc]; Count = ($apci -band 0x3F); Apci = $apci } }
    }
    if ($SERVICE.ContainsKey($apci)) { return [pscustomobject]@{ Name = $SERVICE[$apci]; Count = -1; Apci = $apci } }
    return $null
}

$conn = Open-KnxConnection -Ip $WitnessIp -Port $Port -ConnectionType $K.ConnType.TUNNEL_CONNECTION `
                           -Layer $K.Layer.TUNNEL_BUSMONITOR
if (-not $conn.Ok) { Write-Host "  busmonitor refused by $WitnessIp : $($conn.StatusName)" -ForegroundColor Red; exit 2 }
Write-Host "  watching $WitnessIp for $Seconds s - start the ETS download now" -ForegroundColor Cyan

$rows = New-Object System.Collections.Generic.List[object]
$counts = @{ MemoryWrite = 0; MemoryResponse = 0; MemoryRead = 0; MemoryExtWrite = 0; MemoryExtRead = 0 }
$verifyOn = $false
$verifyWrites = @()   # the data of the last write, to compare with the answer
$echoMatches = 0
$echoDiffers = 0
$deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
$endedEarly = $false
$started = [DateTime]::UtcNow
try {
    while ([DateTime]::UtcNow -lt $deadline) {
        $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        # 03_08_02 5.4 p.14 puts the heartbeat on the CLIENT, and acknowledging what the device pushes
        # does not discharge it: a capture that only listens is disconnected at 120 s. This loop then
        # spun out the rest of its window recording nothing and printed its result over the whole
        # period anyway. Measured on 11.11.0.126: exactly 120.0 s.
        [void](Update-KnxTunnelHeartbeat -Connection $conn -TimeoutMs ([Math]::Min(1500, $left)))
        if (Test-KnxTunnelGone -Connection $conn) {
            Write-Host '  the device ended the busmonitor connection - the capture stops here' -ForegroundColor Yellow
            $endedEarly = $true
            break
        }
        $in = Receive-KnxTunnelCemi -Connection $conn -TimeoutMs ([Math]::Min(1000, $left))
        if ($null -eq $in) {
            if (Test-KnxTunnelGone -Connection $conn) {
                Write-Host '  the device ended the busmonitor connection - the capture stops here' -ForegroundColor Yellow
                $endedEarly = $true
                break
            }
            continue
        }
        $bm = Read-CemiBusmon -Cemi $in.Cemi
        if ($null -eq $bm -or $bm.IsAck -or -not $bm.FcsOk) { continue }
        $tpdu = Get-Tpdu -Lpdu $bm.Lpdu
        if ($null -eq $tpdu) { continue }
        $svc = Get-Service -Tpdu $tpdu
        if ($null -eq $svc) { continue }

        $data = if ($tpdu.Length -gt 2) { [byte[]]$tpdu[2..($tpdu.Length - 1)] } else { [byte[]]@() }
        switch ($svc.Name) {
            'PropertyValueWrite' {
                # object 0, PID 14, element 1: bit 2 is Verify Mode (03_05_02 3.16.3 p.102)
                if ($data.Length -ge 5 -and $data[0] -eq 0 -and $data[1] -eq 14) {
                    $val = $data[4]
                    if (($val -band 0x04) -ne 0) { $verifyOn = $true }
                    Write-Host ("  PID_DEVICE_CONTROL written: 0x{0:X2}{1}" -f $val, $(if (($val -band 4) -ne 0) { ' (verify mode ON)' } else { '' })) -ForegroundColor Yellow
                }
            }
            'MemoryWrite' {
                $counts.MemoryWrite++
                $verifyWrites = if ($data.Length -gt 2) { [byte[]]$data[2..($data.Length - 1)] } else { [byte[]]@() }
            }
            'MemoryResponse' {
                $counts.MemoryResponse++
                $answer = if ($data.Length -gt 2) { [byte[]]$data[2..($data.Length - 1)] } else { [byte[]]@() }
                if ($verifyWrites.Length -gt 0) {
                    if ((ConvertTo-HexString -Bytes $answer) -eq (ConvertTo-HexString -Bytes $verifyWrites)) { $echoMatches++ } else { $echoDiffers++ }
                    $verifyWrites = [byte[]]@()
                }
            }
            'MemoryRead'     { $counts.MemoryRead++ }
            'MemoryExtWrite' { $counts.MemoryExtWrite++ }
            'MemoryExtRead'  { $counts.MemoryExtRead++ }
        }
        $rows.Add([pscustomobject]@{
            Time    = (Get-Date -Format 'HH:mm:ss.fff')
            Service = $svc.Name
            Count   = $svc.Count
            Tpdu    = (ConvertTo-HexString -Bytes $tpdu)
        })
    }
}
finally {
    # Stamped before the close: Close-KnxConnection waits for its answer, and counting that
    # into the covered window would overstate what was actually recorded.
    $stopped = [DateTime]::UtcNow
    try { [void](Close-KnxConnection -Connection $conn) } catch { }
}

if ($Csv) { $rows | Export-Csv -NoTypeInformation -Path $Csv; Write-Host "  wrote $($rows.Count) telegrams to $Csv" }

Write-Host ''
# The result below is only about what was actually recorded. Saying "ETS used procedure X" over a
# window the capture did not cover is the one thing this tool must not do.
$covered = [int]($stopped - $started).TotalSeconds
if ($endedEarly) {
    Write-Host ("  NOTE: the capture covered {0} s of the requested {1} s - the connection ended before the window did." -f $covered, $Seconds) -ForegroundColor Yellow
    Write-Host '        Everything below describes only that part of the session.' -ForegroundColor Yellow
    Write-Host ''
}
Write-Host '  What was on the line' -ForegroundColor Cyan
foreach ($k in @('MemoryWrite', 'MemoryResponse', 'MemoryRead', 'MemoryExtWrite', 'MemoryExtRead')) {
    Write-Host ("    {0,-24} {1}" -f $k, $counts[$k])
}
Write-Host ("    {0,-24} {1}" -f 'answers equal to the write', $echoMatches)
Write-Host ("    {0,-24} {1}" -f 'answers different', $echoDiffers)
Write-Host ''
if ($verifyOn -and $counts.MemoryResponse -gt 0) {
    Write-Host '  ETS used DMP_MemWrite_RCoV: verify mode on, every write answered (03_05_02 3.16.3 p.101-102).' -ForegroundColor Green
}
elseif ($counts.MemoryRead -gt 0 -and $counts.MemoryWrite -gt 0) {
    Write-Host '  ETS used DMP_MemWrite_RCo: a read after the blocks, no verify mode (03_05_02 3.16.2 p.100-101).' -ForegroundColor Green
}
elseif ($counts.MemoryWrite -gt 0 -or $counts.MemoryExtWrite -gt 0) {
    Write-Host '  ETS wrote without reading anything back: the download is not verified on the wire.' -ForegroundColor Green
}
else {
    Write-Host '  No memory service seen. Was the download running, and is the witness on the same TP line?' -ForegroundColor Yellow
}
if ($echoDiffers -gt 0) {
    Write-Host "  $echoDiffers answer(s) carried other data than the write - that is what fails a verified download." -ForegroundColor Red
}
