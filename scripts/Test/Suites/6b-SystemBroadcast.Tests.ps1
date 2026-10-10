#!/usr/bin/env pwsh
# Open ■
# ┬────┴  6b-SystemBroadcast.Tests
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Suites/6b-SystemBroadcast.Tests.ps1

<#
.SYNOPSIS
    KNX IP system broadcast on a router: routing in both directions and the management services.

.DESCRIPTION
    Dot-sourced by Invoke-Conformance.ps1, which then calls Invoke-KnxSuiteSbc.

    Basis: 03_02_06 v01.01.02 4.1.3 and 4.3.5, 03_03_07 3.2.5/3.2.6 and 3.3, 03_05_01 4.5.16.1, and the
    test procedures of 08_TSSK v1.1 2.4.x (KSG668-15.01). Each case names the 08_TSSK test id, which is
    also the id of the KNX validation tool.

    SAFETY: a system broadcast always travels on the system setup group 224.0.23.12. Every case needs
    -IsolatedNetwork (a network without a productive installation, 08_TSSH 1.2.1); the runner drops the
    suite without it and each case re-checks it. The cases that move the routing group of the device
    (08_TSSK runs 80102-80105 that way) also need -IncludeDestructive. Every restore is plain code, so a case
    filter cannot skip it; a failed restore is reported outside the filter and ends the run non-zero.

    Cases that judge what the router puts on IP need multicast reception on this host; the suite proves it
    once (descriptor read on the device's group) and reports those cases NOT-RUN without it. Every case that
    asserts silence carries a positive control in the same case. Datagrams leave and groups are joined on the
    interface that reaches the device, so a second network on this host (e.g. Wi-Fi) is not used.
#>

Set-StrictMode -Version Latest
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib/KnxDevice.psm1') -Force -DisableNameChecking

$script:SbcSetupGroup = '224.0.23.12'
$script:SbcForeignGroup = '225.0.23.12'  # 08_TSSK NonSystemSetupMulticastAddress: same MAC as 224.0.23.12
$script:SbcDeviceDirty = $null           # why later destructive cases must not run
$script:SbcLocalIp = $null               # local interface address towards the device (multicast send and join)

# ── frame building ─────────────────────────────────────────────────────────────────────────────

function New-SbcCemi {
    <#
    .SYNOPSIS
        L_Data.ind to a group (default 0). -System: SB bit of control field 1 zero (03_02_06 4.1.3), else broadcast.
    #>
    param([Parameter(Mandatory)][byte[]]$Tpdu, [int]$Source = 0x00FA, [int]$Destination = 0, [switch]$System, [int]$HopCount = 6)
    $c = New-CemiLData -MessageCode 0x29 -Source $Source -Destination $Destination -IsGroup -Tpdu $Tpdu -Priority 0 -HopCount $HopCount
    if ($System) { $c[2] = [byte]($c[2] -band 0xEF) }
    return , ([byte[]]$c)
}

function New-SbcDatagram {
    <#
    .SYNOPSIS
        KNXnet/IP datagram: ROUTING_SYSTEM_BROADCAST (0533h) or, with -Indication, ROUTING_INDICATION (0530h).
    #>
    param([Parameter(Mandatory)][byte[]]$Cemi, [switch]$Indication)
    $service = if ($Indication) { 0x0530 } else { 0x0533 }
    $len = 6 + $Cemi.Length
    return , ([byte[]](@(0x06, 0x10, (($service -shr 8) -band 0xFF), ($service -band 0xFF), (($len -shr 8) -band 0xFF), ($len -band 0xFF)) + $Cemi))
}

function Send-SbcDatagram {
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671, [Parameter(Mandatory)][byte[]]$Frame)
    $s = New-KnxSocket -TimeoutMs 1500
    try {
        $first = [int]($Ip.Split('.')[0])
        if ($script:SbcLocalIp -and $first -ge 224 -and $first -le 239) {
            $s.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]::MulticastInterface,
                               [System.Net.IPAddress]::Parse($script:SbcLocalIp).GetAddressBytes())
        }
        Send-KnxFrame -Socket $s -Frame $Frame -Ip $Ip -Port $Port
    }
    finally { $s.Dispose() }
}

# TPDUs, 03_03_07. SNP = A_SystemNetworkParameter (3.3.8/3.3.9), NP = A_NetworkParameter (3.2.5/3.2.6).
function Get-SbcTpduSnpRead {
    param([int]$Object = 0, [int]$PropId = 11, [int]$Operand = 1)
    return , ([byte[]]@(0x01, 0xC8, (($Object -shr 8) -band 0xFF), ($Object -band 0xFF), (($PropId -shr 4) -band 0xFF), (($PropId -shl 4) -band 0xF0), $Operand))
}
function Get-SbcTpduSnpResponse {
    param([int]$Object = 0, [int]$PropId = 11, [int]$Operand = 1, [Parameter(Mandatory)][byte[]]$Serial)
    return , ([byte[]](@(0x01, 0xC9, (($Object -shr 8) -band 0xFF), ($Object -band 0xFF), (($PropId -shr 4) -band 0xFF), (($PropId -shl 4) -band 0xF0), $Operand) + $Serial))
}
function Get-SbcTpduDoaWrite {
    param([Parameter(Mandatory)][byte[]]$Serial, [Parameter(Mandatory)][byte[]]$Doa)
    return , ([byte[]](@(0x03, 0xEE) + $Serial + $Doa))
}
function Get-SbcTpduSecure {
    # S-A PDU (APCI 3F1h) with the given SCF (T bit 7, SBC bit 3, service bits 0-2); filler, no crypto check needed.
    param([Parameter(Mandatory)][int]$Scf, [int]$Length = 12, [int]$Seed = 1)
    $body = [byte[]](1..$Length | ForEach-Object { [byte](($_ * 7 + $Seed * 31) -band 0xFF) })
    return , ([byte[]](@(0x03, 0xF1, $Scf) + $body))
}

# ── receiving ──────────────────────────────────────────────────────────────────────────────────

function Open-SbcListener {
    <#
    .SYNOPSIS
        Joins the system setup group and further groups; IP_PKTINFO tells each datagram's group.
    #>
    param([int]$Port = 3671, [string[]]$Groups = @())
    $mc = New-Object System.Net.Sockets.Socket([System.Net.Sockets.AddressFamily]::InterNetwork, [System.Net.Sockets.SocketType]::Dgram, [System.Net.Sockets.ProtocolType]::Udp)
    try {
        $mc.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
        $mc.ReceiveTimeout = 200
        $mc.ReceiveBufferSize = 1048576
        $mc.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $Port)))
        $mc.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]::PacketInformation, $true)
        $local = if ($script:SbcLocalIp) { [System.Net.IPAddress]::Parse($script:SbcLocalIp) } else { [System.Net.IPAddress]::Any }
        foreach ($g in @(@($script:SbcSetupGroup) + @($Groups) | Where-Object { $_ } | Select-Object -Unique)) {
            $opt = New-Object System.Net.Sockets.MulticastOption([System.Net.IPAddress]::Parse($g), $local)
            $mc.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::IP, [System.Net.Sockets.SocketOptionName]::AddMembership, $opt)
        }
        $buf = New-Object byte[] 1024
        for ($i = 0; $i -lt 128; $i++) { try { [void]$mc.Receive($buf) } catch { break } }
    }
    catch { $mc.Dispose(); throw }
    return $mc
}

function Read-SbcFromDevice {
    <#
    .SYNOPSIS
        Routing datagrams (0530h/0533h) from the device within a window: Service, Group, Bytes, Cemi, LData, At (Stopwatch timestamp when read).
    #>
    param([Parameter(Mandatory)]$Listener, [Parameter(Mandatory)][string]$DeviceIp, [int]$CollectMs = 2000)
    $out = New-Object System.Collections.Generic.List[object]
    $buf = New-Object byte[] 1024
    $deadline = [DateTime]::UtcNow.AddMilliseconds($CollectMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        # A blocking receive must not run past the window (ReceiveTimeout 0 would block for ever).
        $Listener.ReceiveTimeout = [int][Math]::Max(1, [Math]::Min(200, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        $flags = [System.Net.Sockets.SocketFlags]::None
        $ep = [System.Net.EndPoint](New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0))
        $pi = New-Object System.Net.Sockets.IPPacketInformation
        try { $n = $Listener.ReceiveMessageFrom($buf, 0, $buf.Length, [ref]$flags, [ref]$ep, [ref]$pi) } catch { continue }
        if ($n -lt 8 -or ([System.Net.IPEndPoint]$ep).Address.ToString() -ne $DeviceIp) { continue }
        $svc = ([int]$buf[2] -shl 8) -bor $buf[3]
        if ($svc -ne 0x0530 -and $svc -ne 0x0533) { continue }
        $bytes = [byte[]]$buf[0..($n - 1)]
        $cemi = [byte[]]$bytes[6..($n - 1)]
        $out.Add([pscustomobject]@{ Service = $svc; Group = "$($pi.Address)"; Bytes = $bytes; Cemi = $cemi; LData = (Read-CemiLData -Cemi $cemi); At = [System.Diagnostics.Stopwatch]::GetTimestamp() })
    }
    return $out.ToArray() # unrolled: callers collect with @()
}

function Test-SbcTpduEqual {
    <#
    .SYNOPSIS
        Same TPDU: equal length, equal APCI bits of octet 0 (the TPCI bits may differ after routing), equal rest.
    #>
    param([byte[]]$A, [byte[]]$B)
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length -or $A.Length -lt 1) { return $false }
    if (($A[0] -band 0x03) -ne ($B[0] -band 0x03)) { return $false }
    for ($i = 1; $i -lt $A.Length; $i++) { if ($A[$i] -ne $B[$i]) { return $false } }
    return $true
}

function Select-SbcTpdu {
    <#
    .SYNOPSIS
        Entries (IP or TP) whose TPDU equals the given one exactly.
    #>
    param([object[]]$Frames, [Parameter(Mandatory)][byte[]]$Tpdu)
    $hits = foreach ($f in @($Frames)) { if ($null -ne $f -and $null -ne $f.LData -and (Test-SbcTpduEqual -A $f.LData.Tpdu -B $Tpdu)) { $f } }
    return $hits
}

function Select-SbcApdu {
    <#
    .SYNOPSIS
        Entries whose TPDU has the APCI of the two given octets and starts with the given payload prefix.
    #>
    param([object[]]$Frames, [Parameter(Mandatory)][byte[]]$Apci, [byte[]]$Prefix = @())
    $hits = foreach ($f in @($Frames)) {
        if ($null -eq $f -or $null -eq $f.LData) { continue }
        $t = $f.LData.Tpdu
        if ($t.Length -lt (2 + $Prefix.Length)) { continue }
        if (($t[0] -band 0x03) -ne ($Apci[0] -band 0x03) -or $t[1] -ne $Apci[1]) { continue }
        $ok = $true
        for ($i = 0; $i -lt $Prefix.Length; $i++) { if ($t[2 + $i] -ne $Prefix[$i]) { $ok = $false; break } }
        if ($ok) { $f }
    }
    return $hits
}

function Test-SbcFrameForm {
    <#
    .SYNOPSIS
        03_02_06 4.1.3 / 4.3.5.3.1 form of a broadcast cEMI: L_Data.ind, group destination 0, SB bit as given.
    .DESCRIPTION
        -System adds the 08_TSSK 2.4.1 rule for S-A_Data / S-A_Sync_Request / S-A_Sync_Response: SCF.SBC = 1 and SCF.T = 1.
    #>
    param([Parameter(Mandatory)]$Entry, [Parameter(Mandatory)][bool]$System)
    $ld = $Entry.LData
    if ($null -eq $ld) { return $false }
    $sbOk = if ($System) { ($ld.Ctrl1 -band 0x10) -eq 0 } else { ($ld.Ctrl1 -band 0x10) -ne 0 }
    $t = $ld.Tpdu
    $scfOk = $true
    if ($System -and $t.Length -ge 3 -and ($t[0] -band 0x03) -eq 0x03 -and $t[1] -eq 0xF1 -and @(0, 2, 3) -contains ($t[2] -band 0x07)) {
        $scfOk = (($t[2] -band 0x88) -eq 0x88)
    }
    return ($ld.MessageCode -eq 0x29 -and ($ld.Ctrl2 -band 0x80) -ne 0 -and $ld.Destination -eq 0 -and $sbOk -and $scfOk)
}

function Test-SbcMetaForm {
    <#
    .SYNOPSIS
        08_TSSK 2.4.1 for one frame from the device: a 0533h arrives on 224.0.23.12 in system broadcast form; others pass.
    #>
    param([Parameter(Mandatory)]$Entry)
    if ($Entry.Service -ne 0x0533) { return $true }
    return ($Entry.Group -eq $script:SbcSetupGroup -and (Test-SbcFrameForm -Entry $Entry -System $true))
}

function Test-SbcHopCount {
    <#
    .SYNOPSIS
        08_TSSK 3.3.7 GlPro_VerifyHopCount without FDSK: 1..6 decremented by one, 7 kept or decremented.
    #>
    param([int]$Sent, [Parameter(Mandatory)]$LData)
    $got = ([int]$LData.Ctrl2 -shr 4) -band 0x07
    if ($Sent -eq 7) { return ($got -eq 7 -or $got -eq 6) }
    return ($got -eq $Sent - 1)
}

# ── device management ──────────────────────────────────────────────────────────────────────────

function Invoke-SbcDm {
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][byte[]]$Cemi)
    $r = Send-KnxDeviceConfiguration -Connection $Connection -Cemi $Cemi
    if ($r -and $r.Cemi) { return , ([byte[]]$r.Cemi) }
    return $null
}

function Set-SbcRoutingMode {
    <#
    .SYNOPSIS
        PID_IP_SBC_CONTROL (router object, PID 120) write then read: Rc of the write, Mode read back (-1: no answer).
    .DESCRIPTION
        Done: Stopwatch timestamp when the write was confirmed; the device took the value no later than this.
    #>
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][int]$Mode)
    $w = Invoke-SbcDm -Connection $Connection -Cemi ([byte[]]@(0xF8, 0x00, 0x06, 0x01, 0x78, 0x00, 0x00, ($Mode -band 0xFF)))
    $done = [System.Diagnostics.Stopwatch]::GetTimestamp()
    $rc = if ($null -ne $w -and $w.Length -ge 6) { [int]$w[5] } else { -1 }
    $r = Invoke-SbcDm -Connection $Connection -Cemi ([byte[]]@(0xF9, 0x00, 0x06, 0x01, 0x78, 0x00, 0x00))
    $m = if ($null -ne $r -and $r.Length -ge 8 -and $r[5] -eq 0) { [int]$r[7] } else { -1 }
    return [pscustomobject]@{ Rc = $rc; Mode = $m; Done = $done }
}

function Get-SbcLcConfig {
    <#
    .SYNOPSIS
        PID_MAIN_LCCONFIG / PID_SUB_LCCONFIG (router object, PID 52/53): value, -1 when the property is absent, $null without answer.
    #>
    param([Parameter(Mandatory)]$Connection)
    $v = @{}
    foreach ($p in @(@{ N = 'Main'; Pid = 0x34 }, @{ N = 'Sub'; Pid = 0x35 })) {
        $r = Invoke-SbcDm -Connection $Connection -Cemi ([byte[]]@(0xFC, 0x00, 0x06, 0x01, $p.Pid, 0x10, 0x01))
        $v[$p.N] = $null
        if ($null -ne $r -and $r.Length -ge 7) { $v[$p.N] = if (($r[5] -band 0xF0) -ne 0 -and $r.Length -ge 8) { [int]$r[7] } else { -1 } }
    }
    return [pscustomobject]@{ Main = $v['Main']; Sub = $v['Sub'] }
}

function Set-SbcProgMode {
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][bool]$On)
    $r = Invoke-SbcDm -Connection $Connection -Cemi ([byte[]]@(0xF6, 0x00, 0x00, 0x01, 0x36, 0x10, 0x01, ([int]$On)))
    return ($null -ne $r -and $r.Length -ge 7 -and ($r[5] -band 0xF0) -ne 0)
}

function Get-SbcSerial {
    param([Parameter(Mandatory)]$Connection)
    $r = Invoke-SbcDm -Connection $Connection -Cemi ([byte[]]@(0xFC, 0x00, 0x00, 0x01, 0x0B, 0x10, 0x01))
    if ($null -ne $r -and $r.Length -ge 13) { return , ([byte[]]$r[7..12]) }
    return $null
}

function Get-SbcRoutingGroup {
    param([Parameter(Mandatory)]$Connection)
    $r = Invoke-SbcDm -Connection $Connection -Cemi ([byte[]]@(0xFC, 0x00, 0x0B, 0x01, 0x42, 0x10, 0x01))
    if ($null -ne $r -and $r.Length -ge 11) { return ('{0}.{1}.{2}.{3}' -f $r[7], $r[8], $r[9], $r[10]) }
    return $null
}

function Open-SbcDm {
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671)
    try {
        $K = Get-KnxConstants
        $c = Open-KnxConnection -Ip $Ip -Port $Port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
        if ($c -and $c.Ok) { return $c }
    }
    catch { }
    return $null
}

function Close-SbcDm { param($Connection) if ($Connection -and $Connection.Ok) { try { Close-KnxConnection -Connection $Connection | Out-Null } catch { } } }

function Exit-SbcDmMode {
    <#
    .SYNOPSIS
        Closes the device management connection before an addressed request: while it is open the cEMI Transport Layer mode ignores such requests (TSSH 8.3.6).
    #>
    param([Parameter(Mandatory)]$Connection)
    $closed = $false
    try { $closed = Close-KnxConnection -Connection $Connection } catch { }
    if (-not $closed) { Set-KnxTestNotRun -MissingInput 'a confirmed DISCONNECT of the device management connection' -Reason 'with the connection possibly open the addressed request would be ignored by the cEMI Transport Layer mode' }
    Start-Sleep -Milliseconds 700   # the mode ends in the device's next loop pass
}

function Clear-SbcProgMode {
    <#
    .SYNOPSIS
        Switches programming mode off, over a fresh connection when the given one is missing or fails.
    .DESCRIPTION
        Fails the case only when the case had switched it on ($WasOn): it then stays on until a restart.
    #>
    param($Connection, [Parameter(Mandatory)][string]$Ip, [int]$Port = 3671, [bool]$WasOn)
    $off = $false
    if ($Connection) { try { $off = Set-SbcProgMode -Connection $Connection -On $false } catch { }; Close-SbcDm $Connection }
    # One device management slot: a connection the device has not released yet is waited for.
    for ($try = 0; -not $off -and $try -lt 5; $try++) {
        if ($try -gt 0) { Start-Sleep -Milliseconds 1000 }
        $c = Open-SbcDm -Ip $Ip -Port $Port
        if ($c) { try { $off = Set-SbcProgMode -Connection $c -On $false } catch { }; Close-SbcDm $c }
    }
    if (-not $off) {
        Write-Host '    WARNING: programming mode could not be switched off - if it is on, it stays on until the next restart' -ForegroundColor Red
        if ($WasOn) { throw 'KNXTEST_FAIL::programming mode could not be switched off after the case' }
    }
}

function Test-SbcDeviceOnGroup {
    <#
    .SYNOPSIS
        A_DeviceDescriptor_Read as routing indication on the group: $true once the device answers there.
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671, [Parameter(Mandatory)][string]$Group, [Parameter(Mandatory)][int]$Pa, [int]$TimeoutSec = 30)
    $mc = $null
    try {
        $mc = Open-SbcListener -Port $Port -Groups @($Group)
        $req = New-SbcDatagram -Cemi (New-CemiLData -MessageCode 0x29 -Source 0x00FA -Destination $Pa -Tpdu ([byte[]]@(0x03, 0x00)) -Priority 0) -Indication
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
            try { Send-SbcDatagram -Ip $Group -Port $Port -Frame $req } catch { }
            $hit = @(Select-SbcApdu -Frames (Read-SbcFromDevice -Listener $mc -DeviceIp $Ip -CollectMs 1000) -Apci ([byte[]]@(0x03, 0x40)) |
                     Where-Object { $_.Group -eq $Group -and $_.LData.Source -eq $Pa })
            if ($hit.Count -ge 1) { return $true }
        }
        return $false
    }
    catch { return $false }
    finally { if ($mc) { $mc.Dispose() } }
}

function Set-SbcDeviceGroup {
    <#
    .SYNOPSIS
        PID_ROUTING_MULTICAST_ADDRESS over device management, then M_Reset (03_08_03 p.8); $true once proven.
    .DESCRIPTION
        Proof is twofold: PID 66 reads the group, and the device answers a descriptor read ON that group,
        which the read-back alone cannot show (the property holds the value before the restart applies it).
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671, [Parameter(Mandatory)][string]$Group, [Parameter(Mandatory)][int]$Pa)
    try {
        $g = [System.Net.IPAddress]::Parse($Group).GetAddressBytes()
        $dm = Open-SbcDm -Ip $Ip -Port $Port
        if ($null -eq $dm) { return $false }
        try {
            $script:SbcGroupTouched = $true # from here on the device may leave its group: a restore is due
            $w = Invoke-SbcDm -Connection $dm -Cemi ([byte[]](@(0xF6, 0x00, 0x0B, 0x01, 0x42, 0x10, 0x01) + $g))
            if ($null -eq $w -or $w.Length -lt 7 -or ($w[5] -band 0xF0) -eq 0) { return $false }
            [void](Invoke-SbcDm -Connection $dm -Cemi ([byte[]]@(0xF1)))
        }
        finally { Close-SbcDm $dm }
        # 03_05_02 3.7.1.1.2: responsive again within t2 = 5 s; changed KNXnet/IP parameters within 30 s.
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $read = $null
        while ($sw.Elapsed.TotalSeconds -lt 30 -and $read -ne $Group) {
            Start-Sleep -Milliseconds 500
            $c = Open-SbcDm -Ip $Ip -Port $Port
            if ($null -ne $c) { try { $read = Get-SbcRoutingGroup -Connection $c } catch { } finally { Close-SbcDm $c } }
        }
        if ($read -ne $Group) { return $false }
        return (Test-SbcDeviceOnGroup -Ip $Ip -Port $Port -Group $Group -Pa $Pa -TimeoutSec 30)
    }
    catch { return $false }
}

# ── TP side, through the shared traffic tunnel ────────────────────────────────────────────────

function Send-SbcTp {
    <#
    .SYNOPSIS
        Puts one telegram on TP (default: broadcast, destination 0) and waits for its L_Data.con.
    .DESCRIPTION
        Acked: the interface took the request. Confirmed: a positive L_Data.con for this TPDU arrived (03_06_03 p.80).
        Hop: hop count in that L_Data.con (-1 without one); a normalising interface may put another one on TP.
        Waiting for the confirmation keeps the next request from overtaking it; indications read meanwhile stay for Read-SbcTp.
    #>
    param([Parameter(Mandatory)]$Connection, [Parameter(Mandatory)][byte[]]$Tpdu, [int]$HopCount = 7, [int]$Destination = 0, [int]$ConMs = 1500)
    $cemi = New-CemiLData -MessageCode 0x11 -Source 0 -Destination $Destination -IsGroup -Tpdu $Tpdu -HopCount $HopCount -Priority 0
    $r = Send-KnxTunnelCemi -Connection $Connection -Cemi $cemi
    $out = [pscustomobject]@{ Acked = [bool]($r -and $r.Acked); Confirmed = $false; Hop = -1 }
    if (-not $out.Acked) { return $out }
    if ($null -eq $Connection.PSObject.Properties['SbcHeld']) { Add-Member -InputObject $Connection -NotePropertyName 'SbcHeld' -NotePropertyValue (New-Object System.Collections.ArrayList) -Force }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($ConMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $left = [int][Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $in = Receive-KnxTunnelCemi -Connection $Connection -TimeoutMs $left
        if ($null -eq $in) { if (Test-KnxTunnelGone -Connection $Connection) { break }; continue }
        if ($null -eq $in.Cemi -or $in.Cemi.Length -lt 1) { continue }
        if ($in.Cemi[0] -eq 0x29) { [void]$Connection.SbcHeld.Add([pscustomobject]@{ Cemi = [byte[]]$in.Cemi; At = [System.Diagnostics.Stopwatch]::GetTimestamp() }); continue }
        if ($in.Cemi[0] -ne 0x2E) { continue }
        $ld = Read-CemiLData -Cemi $in.Cemi
        if ($null -eq $ld -or -not $ld.IsGroup -or $ld.Destination -ne $Destination -or -not (Test-SbcTpduEqual -A $ld.Tpdu -B $Tpdu)) { continue }
        $out.Confirmed = (($ld.Ctrl1 -band 0x01) -eq 0)
        $out.Hop = [int]$ld.HopCount
        return $out
    }
    return $out
}

function Read-SbcTp {
    <#
    .SYNOPSIS
        L_Data.ind frames the traffic tunnel reports from TP within a window, including those held by Send-SbcTp: Cemi, LData, At (Stopwatch timestamp when read).
    #>
    param([Parameter(Mandatory)]$Connection, [int]$CollectMs = 2500)
    $out = New-Object System.Collections.Generic.List[object]
    if ($null -ne $Connection.PSObject.Properties['SbcHeld']) {
        foreach ($h in @($Connection.SbcHeld.ToArray())) {
            $ld = Read-CemiLData -Cemi $h.Cemi
            if ($null -ne $ld) { $out.Add([pscustomobject]@{ Cemi = $h.Cemi; LData = $ld; At = $h.At }) }
        }
        $Connection.SbcHeld.Clear()
    }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($CollectMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $left = [int][Math]::Max(1, [Math]::Min(300, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        $in = Receive-KnxTunnelCemi -Connection $Connection -TimeoutMs $left
        if ($null -eq $in -or $null -eq $in.Cemi -or $in.Cemi.Length -lt 1 -or $in.Cemi[0] -ne 0x29) { continue }
        $ld = Read-CemiLData -Cemi $in.Cemi
        if ($null -ne $ld) { $out.Add([pscustomobject]@{ Cemi = $in.Cemi; LData = $ld; At = [System.Diagnostics.Stopwatch]::GetTimestamp() }) }
    }
    return $out.ToArray() # unrolled: callers collect with @()
}

function Read-SbcBoth {
    <#
    .SYNOPSIS
        Reads the listener and the traffic tunnel in turns for a window: Ip and Tp entries as Read-SbcFromDevice / Read-SbcTp give them.
    .DESCRIPTION
        Neither side waits unattended: an unacknowledged tunnel request costs the tunnel (03_08_04 2.6.1).
    #>
    param([Parameter(Mandatory)]$Listener, [Parameter(Mandatory)][string]$DeviceIp, [Parameter(Mandatory)]$Connection, [int]$CollectMs = 3000)
    $ipF = New-Object System.Collections.Generic.List[object]
    $tpF = New-Object System.Collections.Generic.List[object]
    $deadline = [DateTime]::UtcNow.AddMilliseconds($CollectMs)
    while ($true) {
        $l = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds; if ($l -le 0) { break }
        foreach ($f in @(Read-SbcFromDevice -Listener $Listener -DeviceIp $DeviceIp -CollectMs ([Math]::Min(50, $l)))) { $ipF.Add($f) }
        $l = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds; if ($l -le 0) { break }
        foreach ($f in @(Read-SbcTp -Connection $Connection -CollectMs ([Math]::Min(50, $l)))) { $tpF.Add($f) }
    }
    return [pscustomobject]@{ Ip = $ipF.ToArray(); Tp = $tpF.ToArray() }
}

# ── discovery ──────────────────────────────────────────────────────────────────────────────────

function Get-SbcSearchExtended {
    <#
    .SYNOPSIS
        SEARCH_REQUEST_EXTENDED (020Bh, no SRP) to the control endpoint: families of the first 020Ch, $null without one.
    .DESCRIPTION
        03_08_02 7.6.3.1 allows the control endpoint; the DIBs follow the 8 octet HPAI of the response (7.6.4.2).
    #>
    param([Parameter(Mandatory)][string]$Ip, [int]$Port = 3671, [int]$TimeoutMs = 2500)
    $s = New-KnxSocket -TimeoutMs $TimeoutMs
    try {
        $local = Get-LocalEndpointFor -DestinationIp $Ip -Port $Port
        $f = New-KnxFrame -Service 0x020B -Body (New-KnxHpai -Ip $local -Port (Get-SocketLocalPort -Socket $s))
        $r = Invoke-KnxRequest -Socket $s -Frame $f -Ip $Ip -Port $Port -Expect @(0x020C) -TimeoutMs $TimeoutMs
        if ($r.TimedOut) { return $null }
        $fams = @()
        $dibs = Read-KnxDibs -Body $r.Header.Body -Offset 8 # assigned, not @(): it returns ",`$dibs" (one item)
        foreach ($d in $dibs) { if ($d.Type -eq 0x02 -and $null -ne $d.Decoded) { $fams = @($d.Decoded) } }
        return [pscustomobject]@{ Body = $r.Header.Body; Families = $fams }
    }
    finally { $s.Dispose() }
}

# ── suite ──────────────────────────────────────────────────────────────────────────────────────

function Invoke-KnxSuiteSbc {
    param([Parameter(Mandatory)]$Ctx, [string]$SuiteTitle = '6b System Broadcast')

    $ip = $Ctx.BdutIp
    $port = $Ctx.Port
    $foreignSerial = [byte[]]@(0x00, 0x00, 0xDE, 0xAD, 0xBE, 0xEF) # no device carries it: routed, never processed
    $farDoa = [byte[]]@(239, 1, 2, 3)
    $pa = 0
    if ($Ctx.BdutPa) { try { $pa = ConvertTo-KnxPa -Address $Ctx.BdutPa } catch { $pa = 0 } }

    # Device facts read once: serial number and the routing group it really uses (not the -Multicast argument).
    $dev = $null
    if ($Ctx.IsRouter) {
        $dm0 = Open-SbcDm -Ip $ip -Port $port
        if ($null -ne $dm0) {
            try { $dev = [pscustomobject]@{ Serial = (Get-SbcSerial -Connection $dm0); Group = (Get-SbcRoutingGroup -Connection $dm0) } }
            catch { $dev = $null }
            finally { Close-SbcDm $dm0 }
        }
    }
    $devGroup = ''
    if ($null -ne $dev -and $dev.Group) {
        $first = [int](([string]$dev.Group).Split('.')[0])
        if ($first -ge 224 -and $first -le 239) { $devGroup = [string]$dev.Group }
    }
    try { $lip = Get-LocalEndpointFor -DestinationIp $ip; if ($lip -and $lip -ne '0.0.0.0') { $script:SbcLocalIp = $lip } } catch { }
    # Multicast reception from the device, proven once: without it every IP-side result would be void.
    $script:SbcRx = $false
    $isolatedRun = ($null -ne $Ctx.PSObject.Properties['IsolatedNetwork']) -and [bool]$Ctx.IsolatedNetwork
    if ($Ctx.IsRouter -and $isolatedRun -and $devGroup -and $pa) { $script:SbcRx = Test-SbcDeviceOnGroup -Ip $ip -Port $port -Group $devGroup -Pa $pa -TimeoutSec 6 }

    $gate = {
        param([switch]$Destructive, [switch]$Tp, [switch]$Moved, [switch]$Rx)
        if (-not $Ctx.IsRouter) { Set-KnxTestNotApplicable 'system broadcast routing and its management services belong to the router' }
        $isolated = ($null -ne $Ctx.PSObject.Properties['IsolatedNetwork']) -and [bool]$Ctx.IsolatedNetwork
        if (-not $isolated) { Set-KnxTestNotRun -MissingInput '-IsolatedNetwork' -Reason 'sends on the system setup group 224.0.23.12 - only on a network without a productive installation' }
        if ($Ctx.ReadOnly) { Set-KnxTestNotRun -MissingInput '-RunProfile Full' -Reason 'profile ReadOnly - this case writes properties and puts telegrams on IP and TP' }
        if ($null -eq $dev -or $null -eq $dev.Serial -or -not $devGroup) { Set-KnxTestSkip 'serial number or routing group of the device could not be read over device management' }
        if ($Tp -and -not $Ctx.TrafficIp) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'needs a second interface on the same TP line' }
        if ($Rx -and -not $pa) { Set-KnxTestNotRun -MissingInput '-BdutPa' -Reason 'multicast reception from the device is proven with a descriptor read to its individual address' }
        if ($Rx -and -not $script:SbcRx) { Set-KnxTestNotRun -MissingInput 'multicast reception' -Reason "this host receives no multicast from the device on $devGroup (IGMP snooping / interface) - IP-side results would be void" }
        if ($Destructive -or $Moved) {
            if (-not $Ctx.AllowDestructive) { Set-KnxTestNotRun -MissingInput '-IncludeDestructive' -Reason 'moves the routing multicast address of the device and restores it' }
            if (-not $pa) { Set-KnxTestNotRun -MissingInput '-BdutPa' -Reason 'the device individual address is needed to prove the routing group' }
        }
        if ($Destructive -and $script:SbcDeviceDirty) { Set-KnxTestSkip "the device is not in a known state: $($script:SbcDeviceDirty)" }
        if ($Moved -and -not $script:SbcMovedOk) { Set-KnxTestSkip "the device could not be moved to $($script:SbcForeignGroup)" }
    }
    # A failed positive control is a FAIL when the device is required to pass it, NOT-RUN when it rests on configuration the suite does not own; exception: S-6b.17 keeps its 0533h read a precondition (NOT-RUN), as S-6b.1 judges that read.
    # Broadcast routing with the mode disabled rests on LCCONFIG of its direction (PID_MAIN_LCCONFIG (52) IP to TP, PID_SUB_LCCONFIG (53) TP to IP): NOT-RUN when BROADCAST_LOCK (bit 3) is set there or the property cannot be read, returns otherwise.
    $lcRead = {
        param($Dm, [ValidateSet('ToTp', 'ToIp')][string]$Dir)
        $lc = Get-SbcLcConfig -Connection $Dm
        $fmt = { param($x) if ($null -eq $x) { 'no answer' } elseif ($x -lt 0) { 'absent' } else { '0x{0:X2}' -f $x } }
        Add-KnxEvidence -Note ("PID_MAIN_LCCONFIG {0}, PID_SUB_LCCONFIG {1}" -f (& $fmt $lc.Main), (& $fmt $lc.Sub))
        if ($Dir -eq 'ToTp') { [pscustomobject]@{ Name = 'PID_MAIN_LCCONFIG'; Value = $lc.Main } } else { [pscustomobject]@{ Name = 'PID_SUB_LCCONFIG'; Value = $lc.Sub } }
    }
    $lockGate = {
        param($Dm, [string]$What, [ValidateSet('ToTp', 'ToIp')][string]$Dir)
        $v = & $lcRead $Dm $Dir
        # Absent or unanswered: a lock by another mechanism cannot be excluded (08_TSSK 2.4.31 knows none either).
        if ($null -eq $v.Value -or $v.Value -lt 0) { Set-KnxTestNotRun -MissingInput $v.Name -Reason "$What - $($v.Name) could not be read to tell a broadcast lock from a defect" }
        if (($v.Value -band 0x08) -ne 0) { Set-KnxTestNotRun -MissingInput "$($v.Name) without BROADCAST_LOCK" -Reason ("{0} - BROADCAST_LOCK is set in {1} (0x{2:X2})" -f $What, $v.Name, $v.Value) }
    }
    # Optional $T (traffic tunnel) and $Group (current routing group) enable the 08_TSSK 2.4.31 consistency check after a refusal.
    $mode = {
        param($Dm, [int]$Mode, $T = $null, [string]$Group = '')
        $script:SbcModeAsked = [System.Diagnostics.Stopwatch]::GetTimestamp() # the device took the value no earlier than this
        $r = Set-SbcRoutingMode -Connection $Dm -Mode $Mode
        # With rc 0 the device took the value no later than this; S-6b.6 times its probes from here (without a confirmation it is only when the call gave up).
        $script:SbcModeAt = if ($null -ne $r.PSObject.Properties['Done']) { [long]$r.Done } else { [System.Diagnostics.Stopwatch]::GetTimestamp() }
        $script:SbcModeRc = $r.Rc
        Add-KnxEvidence -Note ("mode {0} requested: rc {1}, read back {2}" -f $Mode, $(if ($r.Rc -lt 0) { 'none (no confirmation)' } else { '0x{0:X2}' -f $r.Rc }), $r.Mode)
        if ($Mode -eq 1 -and $r.Rc -eq 0xF3) {
            # 08_TSSK 2.4.31 (80131): E_COMMAND_IMPOSSIBLE only while domain broadcasts are blocked "through whatever mechanism".
            # A lock in either direction counts: with SUB locked, TP to IP system broadcasts would stay blocked under an enabled mode.
            $what = 'the device refuses mode 1 with E_COMMAND_IMPOSSIBLE (03_05_01 4.5.16.1.1)'
            $lc = Get-SbcLcConfig -Connection $Dm
            $fmt = { param($x) if ($null -eq $x) { 'no answer' } elseif ($x -lt 0) { 'absent' } else { '0x{0:X2}' -f $x } }
            Add-KnxEvidence -Note ("PID_MAIN_LCCONFIG {0}, PID_SUB_LCCONFIG {1}" -f (& $fmt $lc.Main), (& $fmt $lc.Sub))
            $known = { param($x) $null -ne $x -and $x -ge 0 }
            $mainLock = (& $known $lc.Main) -and ($lc.Main -band 0x08) -ne 0
            $subLock = (& $known $lc.Sub) -and ($lc.Sub -band 0x08) -ne 0
            if (-not $mainLock -and -not $subLock) {
                if (-not (& $known $lc.Main) -or -not (& $known $lc.Sub)) { Set-KnxTestNotRun -MissingInput 'PID_MAIN/SUB_LCCONFIG' -Reason "$what - LCCONFIG could not be read to tell a broadcast lock from a defect" }
                Assert-KnxTrue $false ("the device refused mode 1 with E_COMMAND_IMPOSSIBLE although neither PID_MAIN_LCCONFIG ({0}) nor PID_SUB_LCCONFIG ({1}) has BROADCAST_LOCK (08_TSSK 2.4.31 (80131))" -f (& $fmt $lc.Main), (& $fmt $lc.Sub))
            }
            if ($null -ne $T -and $Group) {
                # 2.4.31 consistency after the refusal: a locked direction keeps domain broadcasts blocked, an unlocked one still routes them,
                # and no system broadcast crosses in either direction. Every probe carries its own serial as marker.
                $mk = { param([int]$n) Get-SbcTpduSnpResponse -Serial ([byte[]]@(0x00, 0x00, 0xDE, 0xAD, 0xC3, $n)) }
                $domTp = & $mk 1; $sysTp = & $mk 2
                $domIp = & $mk 3; $sysIp = Get-SbcTpduDoaWrite -Serial ([byte[]]@(0x00, 0x00, 0xDE, 0xAD, 0xC3, 0x04)) -Doa $farDoa
                $lsn = $null
                try {
                    if ($script:SbcRx) { $lsn = Open-SbcListener -Port $port -Groups @($Group) }
                    Send-SbcDatagram -Ip $Group -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $domTp) -Indication)
                    Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $sysTp -System -HopCount 7))
                    $okDom = Send-SbcTp -Connection $T -Tpdu $domIp
                    $okSys = Send-SbcTp -Connection $T -Tpdu $sysIp
                    $tp = @(Read-SbcTp -Connection $T -CollectMs 1500)
                    $ipF = if ($lsn) { @(Read-SbcFromDevice -Listener $lsn -DeviceIp $ip -CollectMs 500) } else { @() }
                }
                finally { if ($lsn) { $lsn.Dispose() } }
                # Seen where none may be: FAIL whatever else.
                Assert-KnxTrue (@(Select-SbcTpdu -Frames $tp -Tpdu $sysTp).Count -eq 0) 'after refusing mode 1 the device routed an IP system broadcast to TP (08_TSSK 2.4.31: system broadcast routing must match the refusal)'
                Assert-KnxTrue (@(@(Select-SbcTpdu -Frames $ipF -Tpdu $sysIp) | Where-Object { $_.Service -eq 0x0533 }).Count -eq 0) 'after refusing mode 1 the device routed a TP system broadcast to IP as 0533h (08_TSSK 2.4.31)'
                $tpDomSeen = @(Select-SbcTpdu -Frames $tp -Tpdu $domTp).Count -gt 0
                $ipDomSeen = @(Select-SbcTpdu -Frames $ipF -Tpdu $domIp).Count -gt 0
                if ($mainLock) { Assert-KnxTrue (-not $tpDomSeen) 'after refusing mode 1 the device routed a domain broadcast from IP to TP although PID_MAIN_LCCONFIG blocks it (08_TSSK 2.4.31: the refusal must leave the lock in force)' }
                if ($subLock -and $lsn) { Assert-KnxTrue (-not $ipDomSeen) 'after refusing mode 1 the device routed a domain broadcast from TP to IP although PID_SUB_LCCONFIG blocks it (08_TSSK 2.4.31: the refusal must leave the lock in force)' }
                # A direction read as unlocked must still route domain broadcasts, if its path was shown to work.
                if (-not $mainLock -and (& $known $lc.Main) -and -not (Test-KnxTunnelGone -Connection $T)) { Assert-KnxTrue $tpDomSeen 'after refusing mode 1 the device no longer routes domain broadcasts from IP to TP although PID_MAIN_LCCONFIG does not block them (08_TSSK 2.4.31)' }
                # A probe that went on TP with hop count 0 cannot be routed.
                if (-not $subLock -and (& $known $lc.Sub) -and $lsn -and $okDom.Acked -and $okDom.Confirmed -and $okDom.Hop -ne 0) { Assert-KnxTrue $ipDomSeen 'after refusing mode 1 the device no longer routes domain broadcasts from TP to IP although PID_SUB_LCCONFIG does not block them (08_TSSK 2.4.31)' }
                if (-not $lsn) { Add-KnxEvidence -Note 'no proven multicast reception: the TP to IP half of the 08_TSSK 2.4.31 consistency was not checked' }
                if (-not ($okDom.Acked -and $okDom.Confirmed -and $okSys.Acked -and $okSys.Confirmed)) { Add-KnxEvidence -Note 'a TP probe of the 08_TSSK 2.4.31 consistency was not confirmed on TP' }
                if ($okDom.Hop -eq 0 -or $okSys.Hop -eq 0) { Add-KnxEvidence -Note 'a TP probe of the 08_TSSK 2.4.31 consistency went on TP with hop count 0 - it cannot be routed, so its TP to IP check was not exercised' }
            }
            else { Add-KnxEvidence -Note 'no traffic tunnel in this case: the 08_TSSK 2.4.31 consistency of the refusal was not checked' }
            if ($subLock -and (& $known $lc.Main) -and -not $mainLock) { Add-KnxEvidence -Note 'the refusal is accepted on BROADCAST_LOCK in PID_SUB_LCCONFIG alone; this is more lenient than the 08_TSSK 2.4.31 (80131) matrix, which measures domain broadcast blocking from IP to TP only' }
            $locked = @(@(if ($mainLock) { 'PID_MAIN_LCCONFIG' }) + @(if ($subLock) { 'PID_SUB_LCCONFIG' }))
            Set-KnxTestNotRun -MissingInput 'LCCONFIG without BROADCAST_LOCK' -Reason ("{0} - BROADCAST_LOCK is set in {1}" -f $what, ($locked -join ' and '))
        }
        # A confirmed error fails: for mode 1 anything but E_NO_ERROR / E_COMMAND_IMPOSSIBLE (08_TSSK 2.4.31), for mode 0 any error (setup writes abort on errors).
        # No confirmation at all (-1) is left to the read-back below and to the caller (S-6b.6 times from it).
        if ($Mode -eq 1) { Assert-KnxTrue ($r.Rc -lt 0 -or $r.Rc -eq 0 -or $r.Rc -eq 0xF3) ("the write of mode 1 was confirmed with return code 0x{0:X2}, neither E_NO_ERROR nor E_COMMAND_IMPOSSIBLE (08_TSSK 2.4.31)" -f $r.Rc) }
        else { Assert-KnxTrue ($r.Rc -le 0) ("the write of mode {0} was confirmed with error 0x{1:X2} (03_05_01 4.5.16.1.1; 08_TSSK GlPro_SetupSystemBroadcast aborts on any error)" -f $Mode, $r.Rc) }
        Assert-KnxTrue ($r.Mode -eq $Mode) "the device did not take IP System Broadcast Routing Mode $Mode"
    }
    $openDm = { $c = Open-SbcDm -Ip $ip -Port $port; Assert-KnxTrue ($null -ne $c) 'no device-management connection'; $c }
    $traffic = {
        $t = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp
        if ($null -eq $t) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'no tunnel on the traffic interface' }
        [void](Clear-KnxTunnelTraffic -Connection $t -QuietMs 300)
        if ($null -ne $t.PSObject.Properties['SbcHeld']) { $t.SbcHeld.Clear() }
        $t
    }
    # Before a frame counted on TP (or its absence) is judged: a lost tunnel reads as "not routed".
    $tunnelGate = { param($T) if (Test-KnxTunnelGone -Connection $T) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason 'the traffic tunnel was lost during the case - what TP showed (or did not) means nothing' } }
    # One TP probe ({Name, Tpdu, Hop}), confirmed before the next leaves; returns the hop count the L_Data.con shows.
    # With -Fails a probe that did not reach TP is recorded there (hop -1) so the case can judge what it saw before gating on it.
    $sendTp = {
        param($T, $P, $Fails)
        $r = Send-SbcTp -Connection $T -Tpdu $P.Tpdu -HopCount $P.Hop
        if (-not $r.Acked -or -not $r.Confirmed) {
            $why = "the traffic interface did not put '{0}' on TP (acknowledged {1}, positive L_Data.con {2})" -f $P.Name, $r.Acked, $r.Confirmed
            if ($null -eq $Fails) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason $why }
            [void]$Fails.Add($why)
            return -1
        }
        if ($r.Hop -ne $P.Hop) { Add-KnxEvidence -Note ("'{0}': hop {1} requested, the L_Data.con shows hop {2} on TP" -f $P.Name, $P.Hop, $r.Hop) }
        # A probe that went on TP with hop count 0 cannot be routed: with -Fails it voids what it was sent for.
        if ($null -ne $Fails -and $r.Hop -eq 0 -and $P.Hop -ne 0) { [void]$Fails.Add(("the traffic interface put '{0}' on TP with hop count 0 instead of {1} - it cannot be routed" -f $P.Name, $P.Hop)) }
        $r.Hop
    }
    $tpGate = { param($Fails) if ($Fails.Count -gt 0) { Set-KnxTestNotRun -MissingInput '-TrafficIp' -Reason (@($Fails) -join '; ') } }
    $note = {
        param([object[]]$Frames, [string]$Name)
        foreach ($h in @($Frames)) {
            if ($null -eq $h) { continue }
            if ($null -ne $h.PSObject.Properties['Service']) { Add-KnxEvidence -Received $h.Bytes -Note ("{0}: 0x{1:X4} on {2}" -f $Name, $h.Service, $h.Group) }
            else { Add-KnxEvidence -Received $h.Cemi -Note "$Name on TP" }
        }
    }

    # Probe sets, 08_TSSK 2.4.3/2.4.5 (TP to IP) and 2.4.6/2.4.8/2.4.22 (IP to TP). Hop 0 must go nowhere.
    $toIpEligible = @(
        @{ Name = 'SNP_Read 0/11/1'; Tpdu = (Get-SbcTpduSnpRead); Hop = 7 },
        @{ Name = 'DoA SN Write 4 octets (foreign serial)'; Tpdu = (Get-SbcTpduDoaWrite -Serial $foreignSerial -Doa $farDoa); Hop = 7 },
        @{ Name = 'S-A_Sync_Request SBC=1 T=1'; Tpdu = (Get-SbcTpduSecure -Scf 0x8A -Seed 1); Hop = 7 },
        @{ Name = 'S-A_Data SBC=1 T=1'; Tpdu = (Get-SbcTpduSecure -Scf 0x88 -Seed 2); Hop = 7 },
        @{ Name = 'S-A_Data SBC=1 T=1, hop 6'; Tpdu = (Get-SbcTpduSecure -Scf 0x88 -Seed 3); Hop = 6 })
    $toIpLookalike = @(
        @{ Name = 'SNP_Read 1/11/1'; Tpdu = (Get-SbcTpduSnpRead -Object 1); Hop = 7 },
        @{ Name = 'SNP_Read 0/12/1'; Tpdu = (Get-SbcTpduSnpRead -PropId 12); Hop = 7 },
        @{ Name = 'SNP_Read 0/11/2'; Tpdu = (Get-SbcTpduSnpRead -Operand 2); Hop = 7 },
        @{ Name = 'DoA SN Write 21 octets (plain)'; Tpdu = (Get-SbcTpduDoaWrite -Serial $foreignSerial -Doa ([byte[]](@(239, 1, 2, 3, 1) + (1..16)))); Hop = 7 },
        @{ Name = 'S-A_Sync_Request SBC=0 T=1'; Tpdu = (Get-SbcTpduSecure -Scf 0x82 -Seed 4); Hop = 7 },
        @{ Name = 'S-A_Data SBC=0 T=1'; Tpdu = (Get-SbcTpduSecure -Scf 0x80 -Seed 5); Hop = 7 },
        @{ Name = 'S-A_Sync_Request SBC=1 T=0'; Tpdu = (Get-SbcTpduSecure -Scf 0x0A -Seed 6); Hop = 7 },
        @{ Name = 'S-A_Data SBC=1 T=0'; Tpdu = (Get-SbcTpduSecure -Scf 0x08 -Seed 7); Hop = 7 },
        @{ Name = 'S-A_Sync_Response SBC=1 T=1'; Tpdu = (Get-SbcTpduSecure -Scf 0x8B -Seed 8); Hop = 7 },
        @{ Name = 'SNP_Response 0/11/1'; Tpdu = (Get-SbcTpduSnpResponse -Serial $foreignSerial); Hop = 7 },
        @{ Name = 'A_IndividualAddress_Read'; Tpdu = ([byte[]]@(0x01, 0x00)); Hop = 7 })
    $toIpHop0 = @(
        @{ Name = 'SNP_Read 0/11/1, hop 0'; Tpdu = (Get-SbcTpduSnpRead -Operand 1); Hop = 0 },
        @{ Name = 'S-A_Sync_Request SBC=1 T=1, hop 0'; Tpdu = (Get-SbcTpduSecure -Scf 0x8A -Seed 9); Hop = 0 },
        @{ Name = 'DoA SN Write 4 octets, hop 0'; Tpdu = (Get-SbcTpduDoaWrite -Serial ([byte[]]@(0x00, 0x00, 0xDE, 0xAD, 0xBE, 0xF0)) -Doa $farDoa); Hop = 0 },
        @{ Name = 'S-A_Data SBC=1 T=1, hop 0'; Tpdu = (Get-SbcTpduSecure -Scf 0x88 -Seed 18); Hop = 0 })
    $toTpEligible = @(
        @{ Name = 'SNP_Response 0/11/1'; Tpdu = (Get-SbcTpduSnpResponse -Serial $foreignSerial); Hop = 7 },
        @{ Name = 'S-A_Sync_Response SBC=1 T=1'; Tpdu = (Get-SbcTpduSecure -Scf 0x8B -Seed 10); Hop = 7 },
        @{ Name = 'S-A_Sync_Response SBC=1 T=1, hop 6'; Tpdu = (Get-SbcTpduSecure -Scf 0x8B -Seed 11); Hop = 6 })
    $toTpNotEligible = @(
        @{ Name = 'SNP_Response 1/11/1'; Tpdu = (Get-SbcTpduSnpResponse -Object 1 -Serial $foreignSerial) },
        @{ Name = 'SNP_Response 0/12/1'; Tpdu = (Get-SbcTpduSnpResponse -PropId 12 -Serial $foreignSerial) },
        @{ Name = 'SNP_Response 0/11/2'; Tpdu = (Get-SbcTpduSnpResponse -Operand 2 -Serial $foreignSerial) },
        @{ Name = 'S-A_Sync_Response SBC=0 T=1'; Tpdu = (Get-SbcTpduSecure -Scf 0x83 -Seed 12) },
        @{ Name = 'S-A_Sync_Response SBC=1 T=0 (80122)'; Tpdu = (Get-SbcTpduSecure -Scf 0x0B -Seed 13) },
        @{ Name = 'SNP_Read 0/11/1'; Tpdu = (Get-SbcTpduSnpRead) },
        @{ Name = 'DoA SN Write 4 octets (foreign serial)'; Tpdu = (Get-SbcTpduDoaWrite -Serial $foreignSerial -Doa $farDoa) },
        @{ Name = 'S-A_Sync_Request SBC=1 T=1'; Tpdu = (Get-SbcTpduSecure -Scf 0x8A -Seed 14) },
        @{ Name = 'S-A_Data SBC=1 T=1'; Tpdu = (Get-SbcTpduSecure -Scf 0x88 -Seed 15) },
        @{ Name = 'S-A_Data SBC=1 T=0'; Tpdu = (Get-SbcTpduSecure -Scf 0x08 -Seed 16) },
        @{ Name = 'A_IndividualAddress_Read'; Tpdu = ([byte[]]@(0x01, 0x00)) })

    # ── A: device on its configured routing group ─────────────────────────────────────────────

    # 08_TSSK 2.4.13 (80113) and 2.4.23 (80123); repeated in block B with the device on a foreign group.
    $mgmtCases = {
        param([string]$Suffix, [string]$Group, [switch]$Moved)
        Invoke-KnxTestCase -Suite $SuiteTitle -Id "S-6b.1$Suffix" -Title "A_SystemNetworkParameter_Read by IP system broadcast is answered in programming mode only (routing group $Group)" `
                           -Clause '03_02_06 4.3.5.2 p.11, 4.3.5.3.1-4.3.5.3.2 p.12; 08_TSSK 2.4.13 (80113)' -Body {
            & $gate -Moved:$Moved -Rx
            $dm = $null; $mc = $null
            try {
                $dm = & $openDm
                $mc = Open-SbcListener -Port $port -Groups @($Group)
                $req = New-SbcDatagram -Cemi (New-SbcCemi -Tpdu (Get-SbcTpduSnpRead) -System)
                Assert-KnxTrue (Set-SbcProgMode -Connection $dm -On $false) 'programming mode could not be switched off'
                Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame $req
                $off = @(Select-SbcApdu -Frames (Read-SbcFromDevice -Listener $mc -DeviceIp $ip -CollectMs 2000) -Apci ([byte[]]@(0x01, 0xC9)))
                Assert-KnxTrue (Set-SbcProgMode -Connection $dm -On $true) 'programming mode could not be switched on'
                Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame $req
                $on = @(Select-SbcApdu -Frames (Read-SbcFromDevice -Listener $mc -DeviceIp $ip -CollectMs 2500) -Apci ([byte[]]@(0x01, 0xC9)) -Prefix ([byte[]]@(0x00, 0x00, 0x00, 0xB0, 0x01)))
                & $note $on 'response'
                # An answer outside programming mode is a FAIL on its own; the answer in it gives the silence its meaning.
                Assert-KnxTrue ($off.Count -eq 0) 'the device answered outside programming mode'
                Assert-KnxTrue ($on.Count -eq 1) "expected one A_SystemNetworkParameter_Response in programming mode, got $($on.Count)"
                $r = $on[0]
                Assert-KnxTrue ($r.Service -eq 0x0533 -and $r.Group -eq $script:SbcSetupGroup) ("the response came as 0x{0:X4} on {1}, not as ROUTING_SYSTEM_BROADCAST on 224.0.23.12 (4.3.5.3.1)" -f $r.Service, $r.Group)
                Assert-KnxTrue (Test-SbcFrameForm -Entry $r -System $true) 'the response cEMI violates 03_02_06 4.1.3'
                if ($pa) { Assert-KnxEqual $pa $r.LData.Source 'the response does not carry the device individual address as source' }
                Assert-KnxTrue ($r.LData.Tpdu.Length -ge 13) 'the response is too short to carry the serial number'
                Assert-KnxBytes -Expected $dev.Serial -Actual ([byte[]]$r.LData.Tpdu[7..12]) -Message 'the response carries another serial number'
            }
            finally {
                if ($mc) { $mc.Dispose() }
                if ($dm) { try { [void](Set-SbcProgMode -Connection $dm -On $false) } catch { }; Close-SbcDm $dm }
            }
        }

        Invoke-KnxTestCase -Suite $SuiteTitle -Id "S-6b.2$Suffix" -Title "A_NetworkParameter_Read by broadcast is answered by broadcast in programming mode (routing group $Group)" `
                           -Clause '03_02_06 4.3.5.3.1-4.3.5.3.2 p.12; 03_03_07 3.2.5-3.2.6; 08_TSSK 2.4.23 (80123)' -Body {
            & $gate -Moved:$Moved -Rx
            $dm = $null; $mc = $null
            try {
                $dm = & $openDm
                Assert-KnxTrue (Set-SbcProgMode -Connection $dm -On $true) 'programming mode could not be switched on'
                $mc = Open-SbcListener -Port $port -Groups @($Group)
                Send-SbcDatagram -Ip $Group -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu ([byte[]]@(0x03, 0xDA, 0x00, 0x00, 0x0B, 0x01))) -Indication)
                $resp = @(Select-SbcApdu -Frames (Read-SbcFromDevice -Listener $mc -DeviceIp $ip -CollectMs 2500) -Apci ([byte[]]@(0x03, 0xDB)) -Prefix ([byte[]]@(0x00, 0x00, 0x0B, 0x01)) |
                          Where-Object { -not $pa -or $_.LData.Source -eq $pa })
                & $note $resp 'response'
                Assert-KnxTrue ($resp.Count -eq 1) "expected one A_NetworkParameter_Response from the device, got $($resp.Count)"
                Assert-KnxTrue ($resp[0].Service -eq 0x0530 -and $resp[0].Group -eq $Group) "the response did not come as ROUTING_INDICATION on the routing group $Group"
                Assert-KnxTrue (Test-SbcFrameForm -Entry $resp[0] -System $false) 'the response is no broadcast cEMI (SB bit, destination)'
                Assert-KnxTrue ($resp[0].LData.Tpdu.Length -ge 12) 'the response is too short to carry the serial number'
                Assert-KnxBytes -Expected $dev.Serial -Actual ([byte[]]$resp[0].LData.Tpdu[6..11]) -Message 'the response carries another serial number'
            }
            finally {
                if ($mc) { $mc.Dispose() }
                if ($dm) { try { [void](Set-SbcProgMode -Connection $dm -On $false) } catch { }; Close-SbcDm $dm }
            }
        }
    }

    & $mgmtCases '' $devGroup

    # Validation tool 60204 (TSSH 8.3.4 p.160 run against a router): A_GroupValue_Read in a ROUTING_INDICATION.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'S-6b.20' -Title "A_GroupValue_Read by routing indication is answered by routing indication, never on a device management connection (routing group $devGroup)" `
                       -Clause '03_03_07 3.1; TSSH 8.3.4 p.160; validation tool 60204' -Body {
        # A coupler (mask 091A) loads no group object table, so it has no group object a read could reach.
        if ("$($Ctx.MaskVersion)" -match '^(0x)?091A') { Set-KnxTestNotApplicable 'the router (mask 091A) has no group objects: there is no readable group address by device class' }
        & $gate -Rx
        $readGa = if ($null -ne $Ctx.PSObject.Properties['ReadableGa']) { [string]$Ctx.ReadableGa } else { '' }
        if (-not $readGa) { Set-KnxTestNotRun -MissingInput '-ReadableGa' -Reason 'needs a group address with a readable group object of the router' }
        $ga = ConvertTo-KnxGa -Address $readGa
        $dm = $null; $mc = $null
        try {
            $dm = & $openDm
            $mc = Open-SbcListener -Port $port -Groups @($devGroup)
            $cemi = New-CemiLData -MessageCode 0x29 -Source 0x11FF -Destination $ga -IsGroup -Tpdu ([byte[]](New-TpduGroupValueRead)) -Priority 3
            Send-SbcDatagram -Ip $devGroup -Port $port -Frame (New-SbcDatagram -Cemi $cemi -Indication)
            $resp = @(Read-SbcFromDevice -Listener $mc -DeviceIp $ip -CollectMs 2500 |
                      Where-Object { $_.Service -eq 0x0530 -and $null -ne $_.LData -and $_.LData.Source -eq $pa -and $_.LData.Destination -eq $ga -and $_.LData.Tpdu.Length -ge 2 -and ($_.LData.Tpdu[1] -band 0xC0) -eq 0x40 -and ($_.LData.Tpdu[0] -band 0x03) -eq 0 })
            $onDm = 0
            while ($true) {
                $r = Wait-KnxService -Socket $dm.Socket -Service @((Get-KnxConstants).Service.DEVICE_CONFIGURATION_REQUEST) -TimeoutMs 300
                if ($r.TimedOut) { break }
                $b = $r.Header.Body
                if ($b.Length -ge 5) { Send-KnxFrame -Socket $dm.Socket -Frame (New-KnxDeviceConfigurationAck -Channel $b[1] -Sequence $b[2]) -Ip $ip -Port $port; $onDm++ }
            }
            & $note $resp 'response'
            Assert-KnxTrue ($resp.Count -ge 1) "no A_GroupValue_Response to $readGa as ROUTING_INDICATION on $devGroup"
            Assert-KnxEqual $pa $resp[0].LData.Source 'the response does not carry the router individual address'
            Assert-KnxEqual 0 $onDm 'the router answered on the device management connection too'
        }
        finally {
            if ($mc) { $mc.Dispose() }
            if ($dm) { Close-SbcDm $dm }
        }
    }

    # Validation tool 60203 (TSSH 8.3.3 p.159 run against a router): A_IndividualAddress_Read in a ROUTING_INDICATION.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'S-6b.19' -Title "A_IndividualAddress_Read by routing indication is answered by routing indication in programming mode only, never on a device management connection (routing group $devGroup)" `
                       -Clause '03_03_07 3.2.3 p.19; 03_05_02 2.2 p.12 (NM_IndividualAddress_Read); TSSH 8.3.3 p.159; validation tool 60203' -Body {
        & $gate -Rx
        $dm = $null; $mc = $null
        # Unsolicited DEVICE_CONFIGURATION_REQUESTs on the DM connection are acknowledged and counted; any one is an answer there.
        $dmAnswers = {
            $n = 0
            while ($true) {
                $r = Wait-KnxService -Socket $dm.Socket -Service @((Get-KnxConstants).Service.DEVICE_CONFIGURATION_REQUEST) -TimeoutMs 300
                if ($r.TimedOut) { break }
                $b = $r.Header.Body
                if ($b.Length -ge 5) {
                    Send-KnxFrame -Socket $dm.Socket -Frame (New-KnxDeviceConfigurationAck -Channel $b[1] -Sequence $b[2]) -Ip $ip -Port $port
                    Add-KnxEvidence -Received ([byte[]]$b[4..($b.Length - 1)]) -Note 'cEMI on the device management connection'
                    $n++
                }
            }
            $n
        }
        try {
            $dm = & $openDm
            $mc = Open-SbcListener -Port $port -Groups @($devGroup)
            $req = New-SbcDatagram -Cemi (New-SbcCemi -Tpdu ([byte[]]@(0x01, 0x00)) -Source 0x11FF) -Indication
            Assert-KnxTrue (Set-SbcProgMode -Connection $dm -On $false) 'programming mode could not be switched off'
            Send-SbcDatagram -Ip $devGroup -Port $port -Frame $req
            # Only the router's own answer: a device in programming mode on its line answers too, and the router routes that.
            $off = @(Select-SbcApdu -Frames (Read-SbcFromDevice -Listener $mc -DeviceIp $ip -CollectMs 2000) -Apci ([byte[]]@(0x01, 0x40)) | Where-Object { $_.LData.Source -eq $pa })
            $offDm = & $dmAnswers
            Assert-KnxTrue (Set-SbcProgMode -Connection $dm -On $true) 'programming mode could not be switched on'
            Send-SbcDatagram -Ip $devGroup -Port $port -Frame $req
            $on = @(Select-SbcApdu -Frames (Read-SbcFromDevice -Listener $mc -DeviceIp $ip -CollectMs 2500) -Apci ([byte[]]@(0x01, 0x40)) | Where-Object { $_.LData.Source -eq $pa })
            $onDm = & $dmAnswers
            & $note $off 'response outside programming mode'
            & $note $on 'response'
            Assert-KnxTrue ($off.Count -eq 0) 'the device answered outside programming mode'
            Assert-KnxTrue ($offDm -eq 0) "the device sent $offDm cEMI frame(s) on the device management connection outside programming mode"
            Assert-KnxTrue ($on.Count -eq 1) "expected one A_IndividualAddress_Response in programming mode, got $($on.Count)"
            Assert-KnxTrue ($onDm -eq 0) "the device answered on the device management connection too ($onDm cEMI frame(s))"
            Assert-KnxTrue ($on[0].Service -eq 0x0530 -and $on[0].Group -eq $devGroup) ("the response came as 0x{0:X4} on {1}, not as ROUTING_INDICATION on {2}" -f $on[0].Service, $on[0].Group, $devGroup)
            Assert-KnxTrue (Test-SbcFrameForm -Entry $on[0] -System $false) 'the response is no broadcast cEMI (SB bit, destination)'
            Assert-KnxEqual $pa $on[0].LData.Source 'the response does not carry the individual address the device reports (-BdutPa, SEARCH_RESPONSE)'
        }
        finally {
            if ($mc) { $mc.Dispose() }
            if ($dm) { try { [void](Set-SbcProgMode -Connection $dm -On $false) } catch { }; Close-SbcDm $dm }
        }
    }

    # 08_TSSK 2.4.10 (80110): ineligible system broadcasts aimed at the device get no answer.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'S-6b.3' -Title 'Ineligible IP system broadcasts get no answer from the device' `
                       -Clause '03_02_06 4.3.5.3.6 p.13; 08_TSSK 2.4.10 (80110)' -Body {
        & $gate -Rx
        $dm = $null; $mc = $null; $progOn = $false
        try {
            # 08_TSSK 2.4.10 power-cycles the device first, so that a device implementing operand 3 would answer it; no power control here.
            Add-KnxEvidence -Note 'precondition not established: the device was not power-cycled before the probes (08_TSSK 2.4.10 setup); the operand 3 probe (NM_Read_SerialNumber_By_PowerReset) shows silence outside a power-up window only'
            $dm = & $openDm
            Assert-KnxTrue (Set-SbcProgMode -Connection $dm -On $true) 'programming mode could not be switched on'
            $progOn = $true
            $c = $dm; $dm = $null
            Exit-SbcDmMode -Connection $c
            $mc = Open-SbcListener -Port $port -Groups @($devGroup)
            $probes = @(
                [byte[]]@(0x01, 0x00),                                  # A_IndividualAddress_Read
                [byte[]]@(0x03, 0xD5, 0x00, 0x01, 0x10, 0x01),          # A_PropertyValue_Read object 0, PID 1
                ([byte[]](@(0x03, 0xDC) + $dev.Serial)),               # A_IndividualAddressSerialNumber_Read, own serial
                (Get-SbcTpduSnpRead -PropId 1),                        # wrong PID
                (Get-SbcTpduSnpRead -Operand 3))                       # NM_Read_SerialNumber_By_PowerReset
            foreach ($p in $probes) { Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $p -System)) }
            if ($pa) {
                # A_DeviceDescriptor_Read addressed to the IA, sent as system broadcast frame
                $dd = New-CemiLData -MessageCode 0x29 -Source 0x00FA -Destination $pa -Tpdu ([byte[]]@(0x03, 0x00)) -Priority 0
                $dd[2] = [byte]($dd[2] -band 0xEF)
                Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame (New-SbcDatagram -Cemi $dd)
            }
            # Only what these probes could cause counts: a probe routed back, or an answer service to one of them.
            $answers = @(@(0x01, 0x40), @(0x03, 0xD6), @(0x03, 0x40), @(0x03, 0xDD), @(0x01, 0xC9))
            $silent = @(@(Read-SbcFromDevice -Listener $mc -DeviceIp $ip -CollectMs 2500) | Where-Object { $null -ne $_.LData } | Where-Object {
                    $f = $_; $t = $f.LData.Tpdu
                    (@($probes | Where-Object { Test-SbcTpduEqual -A $t -B $_ }).Count -gt 0) -or
                    (@($answers | Where-Object { $t.Length -ge 2 -and ($t[0] -band 0x03) -eq ($_[0] -band 0x03) -and $t[1] -eq $_[1] }).Count -gt 0) })
            & $note $silent 'after ineligible probes'
            # Positive control: the eligible read is answered.
            Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu (Get-SbcTpduSnpRead) -System))
            $ans = @(Select-SbcApdu -Frames (Read-SbcFromDevice -Listener $mc -DeviceIp $ip -CollectMs 2500) -Apci ([byte[]]@(0x01, 0xC9)))
            Assert-KnxTrue ($silent.Count -eq 0) 'the device answered or routed an ineligible system broadcast'
            Assert-KnxTrue ($ans.Count -ge 1) 'control: the eligible A_SystemNetworkParameter_Read got no answer - the silence above means nothing'
        }
        finally {
            if ($mc) { $mc.Dispose() }
            Clear-SbcProgMode -Connection $dm -Ip $ip -Port $port -WasOn $progOn
        }
    }

    # 08_TSSK 2.4.6 (80106): mode enabled, eligible IP system broadcasts reach TP with the hop count handled.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'S-6b.4' -Title 'Eligible IP system broadcasts are routed to TP while the mode is enabled' `
                       -Clause '03_02_06 4.3.5.2 p.11; 08_TSSK 2.4.6 (80106), 3.3.7' -Body {
        & $gate -Tp
        $dm = $null; $t = & $traffic
        try {
            $dm = & $openDm
            & $mode $dm 1 $t $devGroup
            foreach ($p in $toTpEligible) { Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $p.Tpdu -System -HopCount $p.Hop)) }
            $tp = @(Read-SbcTp -Connection $t -CollectMs 3000)
            # What arrived is judged first (duplicates, form, hop, order); a lost tunnel only voids what is missing.
            $last = -1
            foreach ($p in $toTpEligible) {
                $hit = @(Select-SbcTpdu -Frames $tp -Tpdu $p.Tpdu)
                & $note $hit $p.Name
                Assert-KnxTrue ($hit.Count -le 1) "'$($p.Name)' reached the TP line $($hit.Count) times, expected once"
                if ($hit.Count -eq 0) { continue }
                $idx = [Array]::IndexOf($tp, $hit[0])
                Assert-KnxTrue ($idx -gt $last) "'$($p.Name)' reached TP out of the order it was sent in (08_TSSK 2.4.6)"
                $last = $idx
                Assert-KnxTrue (($hit[0].LData.Ctrl2 -band 0x80) -ne 0 -and $hit[0].LData.Destination -eq 0) "'$($p.Name)': not a broadcast on TP"
                Assert-KnxTrue (Test-SbcHopCount -Sent $p.Hop -LData $hit[0].LData) "'$($p.Name)': hop count $($p.Hop) handled wrongly (08_TSSK 3.3.7)"
            }
            & $tunnelGate $t
            foreach ($p in $toTpEligible) { Assert-KnxTrue (@(Select-SbcTpdu -Frames $tp -Tpdu $p.Tpdu).Count -eq 1) "'$($p.Name)' did not reach the TP line" }
        }
        finally { if ($dm) { try { [void](Set-SbcRoutingMode -Connection $dm -Mode 0) } catch { }; Close-SbcDm $dm } }
    }

    # 08_TSSK 2.4.7/2.4.8/2.4.22 (80107, 80108, 80122): what may not cross from IP to TP.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'S-6b.5' -Title 'Ineligible IP system broadcasts, and all of them with the mode disabled, do not reach TP' `
                       -Clause '03_02_06 4.3.5.2 p.11; 08_TSSK 2.4.7 (80107), 2.4.8 (80108), 2.4.22 (80122)' -Body {
        & $gate -Tp
        $dm = $null; $t = & $traffic
        try {
            $dm = & $openDm
            & $mode $dm 1 $t $devGroup
            foreach ($p in $toTpNotEligible) { Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $p.Tpdu -System -HopCount 7)) }
            $hop0 = $toTpEligible[0].Tpdu
            $hop0b = Get-SbcTpduSecure -Scf 0x8B -Seed 17
            Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $hop0 -System -HopCount 0))
            Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $hop0b -System -HopCount 0))
            $control = $toTpEligible[1].Tpdu
            Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $control -System))
            $tp = @(Read-SbcTp -Connection $t -CollectMs 3000)
            # Frames that reached TP are FAILs on their own; the control only gives the silence its meaning.
            foreach ($p in $toTpNotEligible) {
                $hit = @(Select-SbcTpdu -Frames $tp -Tpdu $p.Tpdu)
                & $note $hit $p.Name
                Assert-KnxTrue ($hit.Count -eq 0) "'$($p.Name)' reached the TP line"
            }
            Assert-KnxTrue (@(Select-SbcTpdu -Frames $tp -Tpdu $hop0).Count -eq 0 -and @(Select-SbcTpdu -Frames $tp -Tpdu $hop0b).Count -eq 0) 'an IP system broadcast with hop count 0 reached the TP line'
            & $tunnelGate $t
            Assert-KnxTrue (@(Select-SbcTpdu -Frames $tp -Tpdu $control).Count -ge 1) 'control: an eligible IP system broadcast did not reach TP - the silence above means nothing'
            # 80107: with the mode disabled even the eligible ones stay off TP.
            & $mode $dm 0
            [void](Clear-KnxTunnelTraffic -Connection $t -QuietMs 300)
            foreach ($p in $toTpEligible) { Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $p.Tpdu -System -HopCount $p.Hop)) }
            $s0t0 = $toTpNotEligible[4].Tpdu # S-A_Sync_Response SBC=1 T=0 (08_TSSK 2.4.22)
            Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $s0t0 -System -HopCount 7))
            # Control for this phase: the same response as a broadcast routing indication is routed regardless of the mode.
            $ctl2 = Get-SbcTpduSnpResponse -Serial ([byte[]]@(0x00, 0x00, 0xDE, 0xAD, 0xC0, 0x01))
            Send-SbcDatagram -Ip $devGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $ctl2) -Indication)
            $tp2 = @(Read-SbcTp -Connection $t -CollectMs 3000)
            foreach ($p in $toTpEligible) {
                $hit = @(Select-SbcTpdu -Frames $tp2 -Tpdu $p.Tpdu)
                & $note $hit "$($p.Name), mode off"
                Assert-KnxTrue ($hit.Count -eq 0) "with the mode disabled '$($p.Name)' reached the TP line"
            }
            Assert-KnxTrue (@(Select-SbcTpdu -Frames $tp2 -Tpdu $s0t0).Count -eq 0) 'with the mode disabled an S-A_Sync_Response SBC=1 T=0 reached the TP line (80122)'
            & $tunnelGate $t
            if (@(Select-SbcTpdu -Frames $tp2 -Tpdu $ctl2).Count -eq 0) { & $lockGate $dm 'control: a broadcast routing indication did not reach TP' 'ToTp' }
            Assert-KnxTrue (@(Select-SbcTpdu -Frames $tp2 -Tpdu $ctl2).Count -ge 1) 'control: a broadcast routing indication did not reach TP although PID_MAIN_LCCONFIG has no BROADCAST_LOCK - the silence above means nothing'
        }
        finally { if ($dm) { try { [void](Set-SbcRoutingMode -Connection $dm -Mode 0) } catch { }; Close-SbcDm $dm } }
    }

    # 08_TSSK 2.4.11 (80111): the mode falls back 20 s after a fresh enable and 20 s after a re-enable; frames in both directions show it.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'S-6b.6' -Title 'The mode falls back 20 s after the last enable, in both routing directions' `
                       -Clause '03_05_01 4.5.16.1.1 p.107; 08_TSSK 2.4.11 (80111), TimeoutIpSystemBroadcastFallbackToDisable 20 s, delta 1 s' -Body {
        & $gate -Tp -Rx
        if ($Ctx.SkipSlow) { Set-KnxTestSkip 'waits for two 20 s fall-backs - excluded by -SkipSlow' }
        $dm = $null; $mc = $null; $t = & $traffic
        try {
            $dm = & $openDm
            [void](Set-SbcProgMode -Connection $dm -On $false)
            $mc = Open-SbcListener -Port $port -Groups @($devGroup)
            $freq = [double][System.Diagnostics.Stopwatch]::Frequency
            $o = [System.Diagnostics.Stopwatch]::GetTimestamp()
            $at = { ([System.Diagnostics.Stopwatch]::GetTimestamp() - $o) / $freq }
            $late = 0.05 # 08_TSSK NetworkLatency (p.19): a probe leaving later than this after its time point does not test that point
            # Lead of the t0 TP probe: a typical time to its L_Data.con, not a bound from 08_TSSK (it gives no TP latency): tunnel request,
            # TP-UART hand-off (~22 ms at 19200 baud), one standard frame with its ack on TP1 (19 octets, ~28 ms), the con back over IP.
            $tpLate = 0.1
            $ipLog = New-Object System.Collections.Generic.List[object]
            $tpLog = New-Object System.Collections.Generic.List[object]
            $tpFails = New-Object System.Collections.Generic.List[string]
            # Frames carry the time they were read (Send-SbcTp holds TP frames with theirs); without one, now.
            $stamp = { param($F) if ($null -ne $F.PSObject.Properties['At']) { ([long]$F.At - $o) / $freq } else { & $at } }
            # Pumps both sides until a time point, then reads both once more: the tunnel stays acknowledged (03_08_04 2.6.1), the listener never fills up.
            $waitUntil = {
                param([double]$Sec)
                while ($true) {
                    $l = [int](($Sec - (& $at)) * 1000); if ($l -le 0) { break }
                    foreach ($f in @(Read-SbcFromDevice -Listener $mc -DeviceIp $ip -CollectMs ([Math]::Min(50, $l)))) { $ipLog.Add([pscustomobject]@{ At = (& $stamp $f); F = $f }) }
                    $l = [int](($Sec - (& $at)) * 1000); if ($l -le 0) { break }
                    foreach ($f in @(Read-SbcTp -Connection $t -CollectMs ([Math]::Min(50, $l)))) { $tpLog.Add([pscustomobject]@{ At = (& $stamp $f); F = $f }) }
                }
                foreach ($f in @(Read-SbcFromDevice -Listener $mc -DeviceIp $ip -CollectMs 1)) { $ipLog.Add([pscustomobject]@{ At = (& $stamp $f); F = $f }) }
                foreach ($f in @(Read-SbcTp -Connection $t -CollectMs 1)) { $tpLog.Add([pscustomobject]@{ At = (& $stamp $f); F = $f }) }
            }
            # Probe pair built ahead of its time point.
            $newProbe = {
                param([int]$Mark, [string]$Name)
                $pIp = Get-SbcTpduDoaWrite -Serial ([byte[]]@(0x00, 0x00, 0xDE, 0xAD, 0xBE, $Mark)) -Doa $farDoa
                $pTp = Get-SbcTpduSnpResponse -Serial ([byte[]]@(0x00, 0x00, 0xDE, 0xAD, 0xBF, $Mark))
                [pscustomobject]@{ Mark = $Mark; Name = $Name; ToIp = $pIp; ToTp = $pTp; Frame = (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $pTp -System -HopCount 7))
                                   Point = -1.0; End = -1.0; Cut = -1.0; SentTp = -1.0; SentIp = -1.0; Out = -1.0; Con = -1.0; Ip = @(); Tp = 0 }
            }
            # SentIp / Out: datagram leaves / sent; SentTp: tunnel request leaves; Con: its positive L_Data.con read (-1: none or not usable). Datagram first, then the TP probe, whose tunnel request waits for its L_Data.con.
            # -Lead (t0), departing from the 08_TSSK send time: the TP probe leaves $tpLate before the time point and its L_Data.con is awaited only until then, so a confirmed probe tests "on before 19 s" without a TP latency bound; the datagram leaves at the time point, and a later L_Data.con only voids the TP half (the pump acknowledges it, 03_08_04 2.6.1).
            $send = {
                param($P, [double]$Point, [bool]$Lead)
                $P.Point = $Point
                if ($Lead) {
                    $P.SentTp = & $at
                    $r = Send-SbcTp -Connection $t -Tpdu $P.ToIp -HopCount 7 -ConMs ([Math]::Max(1, [int](($Point - (& $at)) * 1000)))
                    if ($r.Confirmed -and $r.Hop -ne 0) { $P.Con = & $at } # hop 0 cannot be routed: not usable
                    if ($r.Confirmed -and $r.Hop -ne 7) { Add-KnxEvidence -Note ("'TP probe {0}': hop 7 requested, the L_Data.con shows hop {1} on TP" -f $P.Mark, $r.Hop) }
                    & $waitUntil $Point
                }
                $P.SentIp = & $at
                Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame $P.Frame
                $P.Out = & $at
                if (-not $Lead) {
                    $n = $tpFails.Count
                    $P.SentTp = & $at
                    [void](& $sendTp $t @{ Name = "TP probe $($P.Mark)"; Tpdu = $P.ToIp; Hop = 7 } $tpFails)
                    $P.Con = if ($tpFails.Count -eq $n) { & $at } else { -1.0 }
                }
            }
            # What each side saw of a probe by the end of its window (TimeoutToIp / TimeoutToTp1 = 1 s, 08_TSSK p.19), judged after the run.
            # 50 ms beyond the end (the closing read of each side finishes a few ms after it), but never past a following mode write (Cut).
            $seen = {
                param($P)
                $u = $P.End + 0.05
                if ($P.Cut -ge 0 -and $P.Cut -lt $u) { $u = $P.Cut }
                $P.Ip = @(@(Select-SbcTpdu -Frames @($ipLog | Where-Object { $_.At -le $u } | ForEach-Object { $_.F }) -Tpdu $P.ToIp) | ForEach-Object { $_.Service })
                $P.Tp = @(Select-SbcTpdu -Frames @($tpLog | Where-Object { $_.At -le $u } | ForEach-Object { $_.F }) -Tpdu $P.ToTp).Count
            }
            $state = { param($P) "IP {0}, TP {1}" -f $(if (@($P.Ip).Count) { (@($P.Ip) | ForEach-Object { '{0:X4}h' -f $_ }) -join ',' } else { 'nothing' }), $P.Tp }
            # The timer starts no later than the confirmed write, the anchor 08_TSSK takes as well (t0 = CurrentTime() after the setup).
            $enable = {
                $b = & $at
                & $mode $dm 1 $t $devGroup
                [pscustomobject]@{ Rc = $script:SbcModeRc; Asked = $b; At = ($script:SbcModeAt - $o) / $freq }
            }
            # LoPro_VerifySystemBroadcastModeFallbackToDisabled: t0 = 19 s, t1 = t0 + 2 * delta = 21 s; each window 2 s >= TimeoutToIp.
            $verify = {
                param($A, $P0, $P1)
                & $waitUntil ($A + 19.0 - $tpLate); & $send $P0 ($A + 19.0) $true; $P0.End = $A + 21.0; & $waitUntil $P0.End
                & $send $P1 ($A + 21.0); $P1.End = $A + 23.0; & $waitUntil $P1.End
            }
            $a0 = & $newProbe 1 'first enable, t0'; $a1 = & $newProbe 2 'first enable, t1'
            $k = & $newProbe 3 're-enable + 11 s'; $b0 = & $newProbe 4 're-enable, t0'; $b1 = & $newProbe 5 're-enable, t1'

            # Warm-up: the first datagram and tunnel request pay one-off costs that would otherwise count as lateness of the first probe.
            $wu = Get-SbcTpduSnpResponse -Serial ([byte[]]@(0x00, 0x00, 0xDE, 0xAD, 0xC4, 0x01))
            Send-SbcDatagram -Ip $devGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $wu) -Indication)
            [void](Send-SbcTp -Connection $t -Tpdu $wu)
            [void](& $at)
            # Setup with the mode disabled; fresh enable, verified; then enable, wait 10 s (TimeoutIpSystemBroadcastFallbackToDisable / 2), re-enable, verify.
            & $mode $dm 0
            $e1 = & $enable
            & $verify $e1.At $a0 $a1
            $e2 = & $enable
            $a1.Cut = $e2.Asked
            & $waitUntil ($e2.At + 10.0)
            $e3 = & $enable
            # 11 s after the re-enable is 21 s or more after the enable before it: a device that ignored the re-enable is off here.
            & $waitUntil ($e3.At + 11.0); & $send $k ($e3.At + 11.0); $k.End = $e3.At + 13.0; & $waitUntil $k.End
            & $verify $e3.At $b0 $b1
            foreach ($x in @($a0, $a1, $k, $b0, $b1)) { & $seen $x }

            foreach ($x in @(@{ N = 'fresh enable'; E = $e1 }, @{ N = 'enable before the re-enable'; E = $e2 }, @{ N = 're-enable'; E = $e3 })) {
                Add-KnxEvidence -Note $(if ($x.E.Rc -lt 0) { "{0}: no confirmation, the write gave up {1:N3} s after the request" -f $x.N, ($x.E.At - $x.E.Asked) } else { "{0}: rc 0x{1:X2}, confirmed {2:N3} s after the request" -f $x.N, $x.E.Rc, ($x.E.At - $x.E.Asked) })
            }
            $rel = { param($P, [double]$T) '{0:+0.000;-0.000;0.000} s' -f ($T - $P.Point) }
            foreach ($x in @($a0, $a1, $k, $b0, $b1)) {
                $con = if ($x.Con -lt 0) { 'none usable' } else { & $rel $x $x.Con }
                Add-KnxEvidence -Note ("{0}: from the time point, TP probe sent {1}, L_Data.con {2}; datagram sent {3} to {4}; {5}" -f $x.Name, (& $rel $x $x.SentTp), $con, (& $rel $x $x.SentIp), (& $rel $x $x.Out), (& $state $x))
            }
            # Violations first: a frame seen where none may be is a FAIL whatever the gates below say (they only void missing frames).
            $bad = @($ipLog | ForEach-Object { $_.F } | Where-Object { -not (Test-SbcMetaForm -Entry $_) })
            & $note $bad 'violates 08_TSSK 2.4.1'
            Assert-KnxTrue ($bad.Count -eq 0) "$($bad.Count) ROUTING_SYSTEM_BROADCAST frame(s) from the device violate 08_TSSK 2.4.1 (group 224.0.23.12, L_Data.ind, SB 0, destination 0, SCF.SBC/T)"
            # Each result rests only on what it needs: a0 and a1 on e1, k, b0 and b1 on e3 (e2 is proven applied by its read-back).
            if ($e2.Rc -ne 0) { Add-KnxEvidence -Note 'the enable before the re-enable was not confirmed; its read-back showed mode 1' }
            # Every FAIL a probe proves is raised before any NOT-RUN another probe's gate would give.
            $tunnelLost = Test-KnxTunnelGone -Connection $t
            $t1Bad = {
                param($P, [string]$N)
                Assert-KnxTrue (-not (@($P.Ip) -contains 0x0533)) ("t1 ({0:N2} s after {1}): the TP system broadcast still left as 0533h - the mode had not fallen back ({2})" -f ($P.SentTp - $P.Point + 21.0), $N, (& $state $P))
                Assert-KnxTrue ($P.Tp -eq 0) ("t1 ({0:N2} s after {1}): an IP system broadcast still reached TP - the mode had not fallen back" -f ($P.SentIp - $P.Point + 21.0), $N)
            }
            if ($e1.Rc -eq 0) { & $t1Bad $a1 'the fresh enable' }
            if ($e3.Rc -eq 0) { & $t1Bad $b1 'the re-enable' }
            # Mode on means both halves: the TP probe (4-octet DoA write, foreign serial) leaves as 0533h and the IP system broadcast reaches TP. A half proves "off" only if its probe tested the time point: the datagram sent by +$IpMax (the tunnel alive to see TP), the TP probe confirmed by +$TpMax (it reaches the router no later than its L_Data.con).
            # t0: datagram 50 ms (NetworkLatency), TP probe 0 (sent $tpLate ahead, confirmed by t0, while the mode must still be on); k, 8 s before any allowed fall-back: 1 s for both (the window still holds TimeoutToIp).
            $onResult = {
                param($P, [string]$When, [string]$Why, [double]$IpMax, [double]$TpMax)
                $ipOn = @($P.Ip) -contains 0x0533; $tpOn = $P.Tp -ge 1
                $ipHalf = ($P.Out - $P.Point -le $IpMax) -and -not $tunnelLost
                $tpHalf = $P.Con -ge 0 -and ($P.Con - $P.Point -le $TpMax)
                $con = if ($P.Con -lt 0) { 'none' } else { & $rel $P $P.Con }
                $times = "datagram sent by {0}, TP probe L_Data.con {1}, from the time point; in time: {2}" -f (& $rel $P $P.Out), $con, $(if ($ipHalf -or $tpHalf) { (@(@(if ($ipHalf) { 'datagram' }) + @(if ($tpHalf) { 'TP probe' }))) -join ' and ' } else { 'neither' })
                $v = [pscustomobject]@{ Fail = ''; Void = '' }
                if ($ipOn -and $tpOn) { return $v }
                if (-not $ipOn -and -not $tpOn) {
                    # With the tunnel lost the TP side does not count: only the TP to IP half is judged.
                    if ($ipHalf -or $tpHalf) {
                        $v.Fail = if ($tunnelLost) { "{0}: the mode was off from TP to IP ({1}; IP to TP not counted, the traffic tunnel was lost; {2}) - {3}" -f $When, (& $state $P), $times, $Why }
                                  else { "{0}: the mode was off in both directions ({1}; {2}) - {3}" -f $When, (& $state $P), $times, $Why }
                    }
                }
                elseif (-not $ipOn) {
                    # A lead probe confirmed before the datagram left reached the router first: the routed datagram shows the mode on for it too.
                    if ($P.Con -ge 0 -and $P.Con -le $P.SentIp) { $v.Fail = ("{0}: the IP system broadcast still reached TP, but the TP probe (4-octet DoA write), confirmed before the datagram left (L_Data.con {1}), did not leave as 0533h ({2}) - TP to IP mishandles that frame" -f $P.Name, $con, (& $state $P)) }
                    elseif ($tpHalf) { $v.Fail = ("{0}: the IP system broadcast still reached TP, but the TP probe (4-octet DoA write, L_Data.con {1}) did not leave as 0533h ({2}) - the mode was off by the time the TP probe reached the router, or TP to IP mishandles that frame" -f $P.Name, $con, (& $state $P)) }
                }
                elseif ($ipHalf) { $v.Fail = ("{0}: the TP probe still left as 0533h, but the IP system broadcast (sent by {1}) did not reach TP ({2}) - the mode was off by the time it reached the router, or IP to TP mishandles it" -f $P.Name, (& $rel $P $P.Out), (& $state $P)) }
                if (-not $v.Fail) {
                    $which = if (-not $ipOn -and -not $tpOn) { 'neither half' } elseif (-not $ipOn) { 'the TP to IP half' } else { 'the IP to TP half' }
                    $v.Void = ("{0}: {1}, but {2} ({3}; tunnel lost {4})" -f $P.Name, (& $state $P), $(if ($which -eq 'neither half') { 'neither half tested the time point' } else { "$which, which showed the mode off, did not test the time point" }), $times, $tunnelLost)
                }
                $v
            }
            $voids = @()
            $checks = @()
            if ($e1.Rc -eq 0) { $checks += , @($a0, 't0 (19 s after the fresh enable)', 'it fell back early', $late, 0.0) }
            if ($e3.Rc -eq 0) {
                $checks += , @($k, ('11 s after the re-enable ({0:N1} s after the enable before it was requested)' -f ([Math]::Min($k.SentIp, $k.SentTp) - $e2.Asked)), 'the re-enable did not restart the 20 s, or its timer is shorter than 11 s', 1.0, 1.0)
                $checks += , @($b0, 't0 (19 s after the re-enable)', 'it fell back early after the re-enable', $late, 0.0)
            }
            foreach ($c in $checks) {
                $v = & $onResult $c[0] $c[1] $c[2] $c[3] $c[4]
                Assert-KnxTrue (-not $v.Fail) $(if ($v.Fail) { $v.Fail } else { 'unused' })
                if ($v.Void) { $voids += $v.Void }
            }
            # Gates: an unconfirmed enable, a probe that did not test its point, a TP probe that never went out.
            # The enable before the re-enable needs no gate: its read-back proved it applied before the re-enable was sent.
            foreach ($x in @(@{ N = 'fresh enable'; E = $e1 }, @{ N = 're-enable'; E = $e3 })) {
                if ($x.E.Rc -ne 0) { Set-KnxTestNotRun -MissingInput 'a confirmed PID_IP_SBC_CONTROL write' -Reason ("the {0} was not confirmed - the start of the 20 s is not known" -f $x.N) }
            }
            if ($voids.Count -gt 0) { Set-KnxTestNotRun -MissingInput 'host and traffic interface timing' -Reason ($voids -join '; ') }
            & $tpGate $tpFails
            # The routing indications at t1 rest on LCCONFIG, and on probes that left in time and were confirmed within the window.
            foreach ($x in @($a1, $b1)) {
                $lag = [Math]::Max($x.Out, $x.SentTp) - $x.Point
                if ($lag -gt $late) { Set-KnxTestNotRun -MissingInput 'host timing' -Reason ("'{0}' left {1:N3} s after its time point (more than 08_TSSK NetworkLatency 50 ms) - that point was not tested" -f $x.Name, $lag) }
                if ($x.Con - $x.Point -gt 1.0) { Set-KnxTestNotRun -MissingInput 'traffic interface timing' -Reason ("the L_Data.con of '{0}' came {1:N3} s after its time point - the 2 s window no longer holds TimeoutToIp (1 s) after it" -f $x.Name, ($x.Con - $x.Point)) }
            }
            $ri = { param($P, [string]$N)
                if (-not (@($P.Ip) -contains 0x0530)) { & $lockGate $dm "t1 after $N`: the TP system broadcast did not leave as a routing indication" 'ToIp' }
                Assert-KnxTrue (@($P.Ip) -contains 0x0530) ("t1 after {0}: the TP system broadcast did not leave as a routing indication ({1})" -f $N, (& $state $P))
            }
            & $ri $a1 'the fresh enable'
            & $ri $b1 'the re-enable'
            # The t1 silence on TP needs the tunnel up to the end of the last window.
            & $tunnelGate $t
        }
        finally {
            if ($mc) { $mc.Dispose() }
            if ($dm) { try { [void](Set-SbcRoutingMode -Connection $dm -Mode 0) } catch { }; Close-SbcDm $dm }
        }
    }

    # 4.1.3: a ROUTING_SYSTEM_BROADCAST counts only when received on the system setup group, not by unicast.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'S-6b.7' -Title 'A ROUTING_SYSTEM_BROADCAST sent by unicast to the device is ignored' `
                       -Clause '03_02_06 4.1.3 p.8' -Body {
        & $gate -Rx
        $dm = $null; $mc = $null
        try {
            $dm = & $openDm
            Assert-KnxTrue (Set-SbcProgMode -Connection $dm -On $true) 'programming mode could not be switched on'
            $mc = Open-SbcListener -Port $port -Groups @($devGroup)
            $req = New-SbcDatagram -Cemi (New-SbcCemi -Tpdu (Get-SbcTpduSnpRead) -System)
            Send-SbcDatagram -Ip $ip -Port $port -Frame $req
            $uni = @(Select-SbcApdu -Frames (Read-SbcFromDevice -Listener $mc -DeviceIp $ip -CollectMs 2500) -Apci ([byte[]]@(0x01, 0xC9)))
            & $note $uni 'after unicast'
            Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame $req
            $mcast = @(Select-SbcApdu -Frames (Read-SbcFromDevice -Listener $mc -DeviceIp $ip -CollectMs 2500) -Apci ([byte[]]@(0x01, 0xC9)))
            Assert-KnxTrue ($uni.Count -eq 0) 'the device answered a ROUTING_SYSTEM_BROADCAST received by unicast'
            Assert-KnxTrue ($mcast.Count -ge 1) 'control: the same request on 224.0.23.12 got no answer - the silence above means nothing'
        }
        finally {
            if ($mc) { $mc.Dispose() }
            if ($dm) { try { [void](Set-SbcProgMode -Connection $dm -On $false) } catch { }; Close-SbcDm $dm }
        }
    }

    # 08_TSSK 2.4.20 (80120): group communication in a system broadcast frame is not routed anywhere.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'S-6b.8' -Title 'Group value services in an IP system broadcast frame are not routed' `
                       -Clause '03_02_06 4.1.3 p.8; 08_TSSK 2.4.20 (80120)' -Body {
        & $gate -Tp
        $dm = $null; $t = & $traffic
        try {
            $dm = & $openDm
            & $mode $dm 1 $t $devGroup
            $ga = ConvertTo-KnxGa -Address '31/7/255'
            $gv = @(
                @{ Name = 'A_GroupValue_Read'; Tpdu = [byte[]]@(0x00, 0x00) },
                @{ Name = 'A_GroupValue_Response'; Tpdu = [byte[]]@(0x00, 0x41) },
                @{ Name = 'A_GroupValue_Write'; Tpdu = [byte[]]@(0x00, 0x81) })
            foreach ($g in $gv) { Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $g.Tpdu -Destination $ga -System)) }
            # Control: a write as ordinary routing indication on the routing group must reach TP.
            Send-SbcDatagram -Ip $devGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu ([byte[]]@(0x00, 0x80)) -Destination $ga) -Indication)
            $tp = @(Read-SbcTp -Connection $t -CollectMs 3000 | Where-Object { $_.LData.Destination -eq $ga })
            & $note $tp 'GA 31/7/255'
            # A group value service on TP is a FAIL on its own; the control only gives the absence its meaning.
            foreach ($g in $gv) {
                Assert-KnxTrue (@($tp | Where-Object { $_.LData.Tpdu.Length -ge 2 -and $_.LData.Tpdu[1] -eq $g.Tpdu[1] }).Count -eq 0) "'$($g.Name)' in a system broadcast frame reached TP"
            }
            & $tunnelGate $t
            $ctrl = @($tp | Where-Object { $_.LData.Tpdu.Length -ge 2 -and $_.LData.Tpdu[1] -eq 0x80 })
            if ($ctrl.Count -eq 0) { Set-KnxTestNotRun -MissingInput 'routing of 31/7/255' -Reason 'the router does not route 31/7/255 at all (filter table or LCGRPCONFIG); the absence above means nothing' }
        }
        finally { if ($dm) { try { [void](Set-SbcRoutingMode -Connection $dm -Mode 0) } catch { }; Close-SbcDm $dm } }
    }

    # 08_TSSK 2.4.12 (80112): the mode written back to 0 takes effect at once, in both routing directions.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'S-6b.16' -Title 'Writing the mode back to disabled stops system broadcast routing at once, in both directions' `
                       -Clause '03_05_01 4.5.16.1.1 p.107; 03_02_06 4.3.5.2 p.11; 08_TSSK 2.4.12 (80112)' -Body {
        & $gate -Tp -Rx
        $dm = $null; $mc = $null; $t = & $traffic
        try {
            $dm = & $openDm
            [void](Set-SbcProgMode -Connection $dm -On $false)
            $mc = Open-SbcListener -Port $port -Groups @($devGroup)
            $read = @{ Name = 'SNP_Read 0/11/1'; Tpdu = (Get-SbcTpduSnpRead); Hop = 7 }
            $fails = New-Object System.Collections.Generic.List[string]
            # One phase: TP system broadcast and IP system broadcast as in 08_TSSK 2.4.12, read for max(TimeoutToTp1, TimeoutToIp) with margin.
            $phase = {
                param([int]$Mark, [byte[]]$Extra)
                $resp = Get-SbcTpduSnpResponse -Serial ([byte[]]@(0x00, 0x00, 0xDE, 0xAD, 0xC1, $Mark))
                Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $resp -System -HopCount 7))
                if ($Extra) { Send-SbcDatagram -Ip $devGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $Extra) -Indication) }
                [void](& $sendTp $t $read $fails)
                $b = Read-SbcBoth -Listener $mc -DeviceIp $ip -Connection $t -CollectMs 2500
                [pscustomobject]@{ Ip = @(Select-SbcTpdu -Frames @($b.Ip) -Tpdu $read.Tpdu); Tp = @(Select-SbcTpdu -Frames @($b.Tp) -Tpdu $resp).Count; TpAll = @($b.Tp) }
            }
            & $mode $dm 1 $t $devGroup
            $r1 = & $phase 1 $null
            & $mode $dm 0
            # Control for the TP side of phase 2: a broadcast routing indication is routed whatever the mode.
            $ctl = Get-SbcTpduSnpResponse -Serial ([byte[]]@(0x00, 0x00, 0xDE, 0xAD, 0xC1, 0xFF))
            $r2 = & $phase 2 $ctl
            & $note $r1.Ip 'mode 1, SNP_Read from TP'
            & $note $r2.Ip 'mode 0, SNP_Read from TP'
            # Violations first: a frame seen where none may be is a FAIL whatever the gates below say.
            Assert-KnxTrue (@(@($r1.Ip) + @($r2.Ip) | Where-Object { -not (Test-SbcMetaForm -Entry $_) }).Count -eq 0) 'a 0533h violates 08_TSSK 2.4.1'
            Assert-KnxTrue (@($r2.Ip | Where-Object { $_.Service -eq 0x0533 }).Count -eq 0) 'mode 0: the SNP_Read from TP still left as ROUTING_SYSTEM_BROADCAST'
            Assert-KnxTrue ($r2.Tp -eq 0) 'mode 0: the SNP_Response sent as IP system broadcast still reached TP'
            # Then what must be there: mode 1 first, then the mode 0 control and routing indication, which rest on LCCONFIG.
            & $tpGate $fails
            & $tunnelGate $t
            $sys1 = @($r1.Ip | Where-Object { $_.Service -eq 0x0533 })
            Assert-KnxTrue ($sys1.Count -ge 1 -and $r1.Tp -ge 1) ("mode 1: the SNP_Read from TP left as 0533h {0} time(s), the SNP_Response from IP reached TP {1} time(s); expected both" -f $sys1.Count, $r1.Tp)
            if (@(Select-SbcTpdu -Frames $r2.TpAll -Tpdu $ctl).Count -eq 0) { & $lockGate $dm 'control: a broadcast routing indication did not reach TP' 'ToTp' }
            Assert-KnxTrue (@(Select-SbcTpdu -Frames $r2.TpAll -Tpdu $ctl).Count -ge 1) 'control: a broadcast routing indication did not reach TP although PID_MAIN_LCCONFIG has no BROADCAST_LOCK - the TP silence above means nothing'
            $ri2 = @($r2.Ip | Where-Object { $_.Service -eq 0x0530 -and $_.Group -eq $devGroup })
            if ($ri2.Count -eq 0) { & $lockGate $dm 'the SNP_Read from TP did not leave as a routing indication with the mode disabled' 'ToIp' }
            Assert-KnxTrue ($ri2.Count -eq 1) "mode 0: the SNP_Read from TP left $($ri2.Count) time(s) as ROUTING_INDICATION on $devGroup, expected once"
        }
        finally {
            if ($mc) { $mc.Dispose() }
            if ($dm) { try { [void](Set-SbcRoutingMode -Connection $dm -Mode 0) } catch { }; Close-SbcDm $dm }
        }
    }

    # 08_TSSK 2.4.32 (80132), 03_02_06 4.3.5.3.1 NOTE 2: a routing indication with a system broadcast cEMI (SB 0) is not served.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'S-6b.17' -Title 'Reads in a routing indication with a system broadcast cEMI (SB 0) get no answer in programming mode' `
                       -Clause '03_02_06 4.3.5.3.1 NOTE 2 p.12, 4.3.5.3.2; 08_TSSK 2.4.32 (80132)' -Body {
        & $gate -Rx
        if ($devGroup -ne $script:SbcSetupGroup) { Set-KnxTestNotRun -MissingInput "routing group $($script:SbcSetupGroup)" -Reason "08_TSSK 2.4.32 runs with the routing multicast address on the system setup group; the device routes on $devGroup" }
        $dm = $null; $mc = $null
        try {
            $dm = & $openDm
            Assert-KnxTrue (Set-SbcProgMode -Connection $dm -On $true) 'programming mode could not be switched on'
            $mc = Open-SbcListener -Port $port -Groups @($devGroup)
            $np = [byte[]]@(0x03, 0xDA, 0x00, 0x00, 0x0B, 0x01) # A_NetworkParameter_Read object 0, PID 11, operand 1 (08_TSSK 2.4.32)
            $snp = Get-SbcTpduSnpRead                           # A_SystemNetworkParameter_Read 0/11/1, served before NOTE 2 was applied
            # What these probes could cause from the device itself: an answer to either read, in any service.
            $answers = { param($Frames) @(@(Select-SbcApdu -Frames $Frames -Apci ([byte[]]@(0x03, 0xDB))) + @(Select-SbcApdu -Frames $Frames -Apci ([byte[]]@(0x01, 0xC9))) | Where-Object { $_.LData.Source -eq $pa }) }
            foreach ($q in @($np, $snp)) { Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $q -System) -Indication) }
            $quiet = @(& $answers @(Read-SbcFromDevice -Listener $mc -DeviceIp $ip -CollectMs 2500))
            & $note $quiet 'after routing indications with SB 0'
            # An answer is a FAIL on its own; the controls below only give the silence its meaning.
            Assert-KnxTrue ($quiet.Count -eq 0) "the device answered a routing indication carrying a system broadcast cEMI (SB 0): $($quiet.Count) answer(s) (NOTE 2)"
            # Control 1: management listens at all - the same read as 0533h must be answered (judged by S-6b.1, here a precondition).
            Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $snp -System))
            $sys = @(Select-SbcApdu -Frames @(Read-SbcFromDevice -Listener $mc -DeviceIp $ip -CollectMs 2500) -Apci ([byte[]]@(0x01, 0xC9)) | Where-Object { $_.LData.Source -eq $pa })
            if ($sys.Count -eq 0) { Set-KnxTestNotRun -MissingInput 'an answer to A_SystemNetworkParameter_Read' -Reason 'control: the same read as ROUTING_SYSTEM_BROADCAST got no answer in programming mode - the silence above means nothing' }
            # Control 2: the 08_TSSK 2.4.32 read with SB 1 is a domain broadcast and must be answered (4.3.5.3.2).
            Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $np) -Indication)
            $dom = @(Select-SbcApdu -Frames @(Read-SbcFromDevice -Listener $mc -DeviceIp $ip -CollectMs 2500) -Apci ([byte[]]@(0x03, 0xDB)) | Where-Object { $_.LData.Source -eq $pa })
            Assert-KnxTrue ($dom.Count -ge 1) 'control: A_NetworkParameter_Read by broadcast (SB 1) got no answer in programming mode (4.3.5.3.2) - the silence above means nothing'
        }
        finally {
            if ($mc) { $mc.Dispose() }
            if ($dm) { try { [void](Set-SbcProgMode -Connection $dm -On $false) } catch { }; Close-SbcDm $dm }
        }
    }

    # ── leaving the routing group and coming back ──────────────────────────────────────────────
    # While the device may be off its group, the runner's own restore (Invoke-Conformance.ps1, finally around the suites) holds the way back, so a stopped run still puts it back; a restore armed earlier by the runner is left alone.
    $script:SbcArmed = $false
    $arm = {
        if ($null -eq (Get-Variable -Name RoutingRestoreBytes -Scope Script -ValueOnly -ErrorAction SilentlyContinue)) {
            $script:RoutingRestoreBytes = [byte[]]([System.Net.IPAddress]::Parse($devGroup).GetAddressBytes())
            $script:RoutingRestoreGroup = $devGroup
            $script:SbcArmed = $true
        }
    }
    $disarm = { if ($script:SbcArmed) { $script:RoutingRestoreBytes = $null; $script:RoutingRestoreGroup = ''; $script:SbcArmed = $false } }
    # Puts the device back on its group; a failure stays armed for the runner and ends the run non-zero.
    $goHome = {
        param([string]$After)
        $ok = $false
        try { $ok = Set-SbcDeviceGroup -Ip $ip -Port $port -Group $devGroup -Pa $pa } catch { $ok = $false }
        if ($ok) { & $disarm }
        else {
            $script:SbcDeviceDirty = "restore of the routing group to $devGroup failed after $After"
            $script:routingRestoreFailed = $true # the runner ends non-zero (Invoke-Conformance.ps1)
            Add-KnxRunDropped -Suite $SuiteTitle -Reason "the routing group could not be restored to $devGroup after $After - set PID 66 and reset the device by hand"
        }
        $ok
    }
    # A restore case selected without the case it belongs to: it checks where the device is now.
    $homeCase = {
        param([string]$Id, [string]$Parent)
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $Id -Title "The routing group is on $devGroup ($Parent did not run)" -Clause 'test hygiene' -Body {
            & $gate
            Add-KnxEvidence -Note "$Parent did not change the group in this run: PID 66 is read as it is"
            Assert-KnxTrue ($devGroup -ne $script:SbcForeignGroup) "the device routes on $($script:SbcForeignGroup), the group this suite moves it to - likely left there by an earlier run; set PID 66 back and reset the device by hand"
            $c = & $openDm
            try { Assert-KnxEqual $devGroup (Get-SbcRoutingGroup -Connection $c) "PID_ROUTING_MULTICAST_ADDRESS is not $devGroup - set it and reset the device by hand" }
            finally { Close-SbcDm $c }
        }
    }

    # ── B: device moved to the foreign group, as 08_TSSK runs 80102-80105, 80113, 80123 ──────

    $script:SbcMovedOk = $false
    $script:SbcGroupTouched = $false
    $script:SbcRxForeign = $false
    $stranded = $devGroup -and $devGroup -eq $script:SbcForeignGroup # an earlier run may have left the device there: S-6b.R1 says so once
    $blockB = @('S-6b.9', 'S-6b.10', 'S-6b.11', 'S-6b.12', 'S-6b.1.F', 'S-6b.2.F')
    $selectedB = @($blockB | Where-Object { Test-KnxCaseSelected -Id $_ }).Count -gt 0
    $movable = $selectedB -and $Ctx.IsRouter -and $Ctx.AllowDestructive -and $pa -and $null -ne $dev -and $null -ne $dev.Serial -and $devGroup -and
               $devGroup -ne $script:SbcForeignGroup -and $isolatedRun -and -not $Ctx.ReadOnly -and -not $script:SbcDeviceDirty -and $script:SbcRx
    if ($movable) {
        try {
            & $arm
            $script:SbcMovedOk = Set-SbcDeviceGroup -Ip $ip -Port $port -Group $script:SbcForeignGroup -Pa $pa
            if ($script:SbcMovedOk) { $script:SbcRxForeign = $true } # the move proved this host receives the foreign group

            Invoke-KnxTestCase -Suite $SuiteTitle -Id 'S-6b.9' -Title "Routing on $($script:SbcForeignGroup), the device answers system broadcasts on 224.0.23.12 only" `
                               -Clause '03_02_06 4.1.3 p.8, 4.3.5.2 p.11; 08_TSSK 2.4.1-2.4.2 (80101, 80102)' -Body {
                & $gate -Moved -Rx
                $dm = $null; $mc = $null
                try {
                    $dm = & $openDm
                    Assert-KnxTrue (Set-SbcProgMode -Connection $dm -On $true) 'programming mode could not be switched on'
                    $mc = Open-SbcListener -Port $port -Groups @($script:SbcForeignGroup)
                    $req = New-SbcDatagram -Cemi (New-SbcCemi -Tpdu (Get-SbcTpduSnpRead) -System)
                    Send-SbcDatagram -Ip $script:SbcForeignGroup -Port $port -Frame $req
                    Send-SbcDatagram -Ip $ip -Port $port -Frame $req
                    $wrong = @(Select-SbcApdu -Frames (Read-SbcFromDevice -Listener $mc -DeviceIp $ip -CollectMs 2500) -Apci ([byte[]]@(0x01, 0xC9)))
                    Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame $req
                    $right = @(Select-SbcApdu -Frames (Read-SbcFromDevice -Listener $mc -DeviceIp $ip -CollectMs 2500) -Apci ([byte[]]@(0x01, 0xC9)))
                    & $note $wrong 'on the routing group / unicast'
                    & $note $right 'on 224.0.23.12'
                    Assert-KnxTrue ($wrong.Count -eq 0) 'the device answered a ROUTING_SYSTEM_BROADCAST that did not arrive on 224.0.23.12 (4.1.3)'
                    Assert-KnxTrue ($right.Count -eq 1 -and $right[0].Service -eq 0x0533 -and $right[0].Group -eq $script:SbcSetupGroup) "routing on $($script:SbcForeignGroup), the device did not answer a system broadcast on 224.0.23.12 exactly once (4.3.5.2)"
                    Assert-KnxTrue (Test-SbcMetaForm -Entry $right[0]) 'the response violates 08_TSSK 2.4.1 (L_Data.ind, SB 0, destination 0)'
                }
                finally {
                    if ($mc) { $mc.Dispose() }
                    if ($dm) { try { [void](Set-SbcProgMode -Connection $dm -On $false) } catch { }; Close-SbcDm $dm }
                }
            }

            # 08_TSSK 2.4.3 (80103) and 2.4.4 (80104): the mode decides between 0533h on 224.0.23.12 and 0530h on the routing group; routing is judged against the hop count the L_Data.con shows on TP, and a changed hop count leaves 3.3.7 unexercised (NOT-RUN).
            # The router's output is the cross-check: one decrement more than the L_Data.con explains means the interface decremented on the wire (NOT-RUN). 80121 follows the 2.4.21 procedure (two routing indications); 08_TSSK A8 assumes T=0 frames are not routed at all - the two conflict.
            foreach ($case in @(@{ Id = 'S-6b.10'; Mode = 1; Tool = '2.4.3 (80103)' }, @{ Id = 'S-6b.11'; Mode = 0; Tool = '2.4.4 (80104)' })) {
                $what = if ($case.Mode -eq 1) { 'as ROUTING_SYSTEM_BROADCAST on 224.0.23.12 while the mode is enabled' } else { 'as ROUTING_INDICATION on the routing group while the mode is disabled' }
                Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title "Eligible TP system broadcasts are routed $what" `
                                   -Clause "03_02_06 4.1.3 p.8; 08_TSSK $($case.Tool), 2.4.21 (80121), 3.3.7" -Body {
                    & $gate -Moved -Tp -Rx
                    $dm = $null; $mc = $null; $t = & $traffic
                    try {
                        $dm = & $openDm
                        [void](Set-SbcProgMode -Connection $dm -On $false)
                        & $mode $dm $case.Mode $t $script:SbcForeignGroup
                        $mc = Open-SbcListener -Port $port -Groups @($script:SbcForeignGroup)
                        # 08_TSSK 2.4.21 (80121): S-AL with SBC=1 and T=0 leaves as a routing indication, with the mode enabled and disabled.
                        $t0 = @(@{ Name = 'S-A_Sync_Request SBC=1 T=0'; Tpdu = (Get-SbcTpduSecure -Scf 0x0A -Seed 20); Hop = 7 },
                                @{ Name = 'S-A_Data SBC=1 T=0'; Tpdu = (Get-SbcTpduSecure -Scf 0x08 -Seed 19); Hop = 7 })
                        $fails = New-Object System.Collections.Generic.List[string]
                        $wire = @{}
                        foreach ($p in @($toIpEligible) + @($t0)) { $wire[$p.Name] = & $sendTp $t $p $fails }
                        # From the write request: the device took the mode no earlier, so this is the longest it can have been on.
                        $onFor = ([System.Diagnostics.Stopwatch]::GetTimestamp() - $script:SbcModeAsked) / [double][System.Diagnostics.Stopwatch]::Frequency
                        $frames = @((Read-SbcBoth -Listener $mc -DeviceIp $ip -Connection $t -CollectMs 3000).Ip)
                        foreach ($p in @($t0) + @($toIpEligible)) { & $note @(Select-SbcTpdu -Frames $frames -Tpdu $p.Tpdu) $p.Name }
                        # Violations first: a frame seen where none may be is a FAIL whatever the gates below say.
                        $bad = @($frames | Where-Object { -not (Test-SbcMetaForm -Entry $_) })
                        Assert-KnxTrue ($bad.Count -eq 0) "$($bad.Count) ROUTING_SYSTEM_BROADCAST frame(s) from the device violate 08_TSSK 2.4.1"
                        foreach ($p in @($t0) + @($toIpEligible)) {
                            $hit = @(Select-SbcTpdu -Frames $frames -Tpdu $p.Tpdu)
                            Assert-KnxTrue ($hit.Count -le 1) "'$($p.Name)' left the TP line $($hit.Count) times"
                            # Hop 0 in the L_Data.con of a probe sent with another hop count: the TP gate below voids it, a routed copy is only evidence.
                            if ([int]$wire[$p.Name] -eq 0 -and $hit.Count -gt 0) { Add-KnxEvidence -Note ("'{0}': L_Data.con shows hop 0, yet it was routed with hop {1} - the interface did not keep the hop count" -f $p.Name, $hit[0].LData.HopCount) }
                            if ($case.Mode -eq 0 -or @($t0 | Where-Object { $_.Name -eq $p.Name }).Count -gt 0) {
                                Assert-KnxTrue (@($hit | Where-Object { $_.Service -eq 0x0533 }).Count -eq 0) "'$($p.Name)' left as ROUTING_SYSTEM_BROADCAST (mode $($case.Mode), 80121 for T=0)"
                            }
                        }
                        # Gates for the frames that must be there.
                        & $tpGate $fails
                        if ($case.Mode -eq 1 -and $onFor -gt 19.0) { Set-KnxTestNotRun -MissingInput 'traffic interface timing' -Reason ("the probes took up to {0:N1} s after the enable request - the mode may have fallen back before the last one (no earlier than 19 s, 08_TSSK 2.4.11)" -f $onFor) }
                        $changed = @()
                        $rewrote = @()
                        foreach ($p in $t0) {
                            $hit = @(Select-SbcTpdu -Frames $frames -Tpdu $p.Tpdu)
                            if ([int]$wire[$p.Name] -eq 0) { $changed += $p.Name; continue }
                            # With the mode enabled domain broadcasts must be routed whatever LCCONFIG says (08_TSSK 2.4.31); only mode 0 may be locked.
                            if ($case.Mode -eq 0 -and $hit.Count -eq 0) { & $lockGate $dm "'$($p.Name)' did not leave TP as a routing indication" 'ToIp' }
                            Assert-KnxTrue ($hit.Count -eq 1 -and $hit[0].Service -eq 0x0530 -and $hit[0].Group -eq $script:SbcForeignGroup) "'$($p.Name)' was not routed exactly once as ROUTING_INDICATION on the routing group (80121)"
                            Assert-KnxTrue (Test-SbcFrameForm -Entry $hit[0] -System $false) "'$($p.Name)': the routing indication carries no broadcast cEMI (SB bit, destination)"
                        }
                        foreach ($p in $toIpEligible) {
                            $w = [int]$wire[$p.Name]
                            if ($w -ne $p.Hop) { $changed += $p.Name }
                            if ($w -eq 0) { continue }
                            $hit = @(Select-SbcTpdu -Frames $frames -Tpdu $p.Tpdu)
                            if ($case.Mode -eq 1) { $want = @($hit | Where-Object { $_.Service -eq 0x0533 -and $_.Group -eq $script:SbcSetupGroup }) }
                            else { $want = @($hit | Where-Object { $_.Service -eq 0x0530 -and $_.Group -eq $script:SbcForeignGroup }) }
                            if ($case.Mode -eq 0 -and $hit.Count -eq 0) { & $lockGate $dm "'$($p.Name)' did not leave TP as a routing indication" 'ToIp' }
                            Assert-KnxTrue ($hit.Count -eq 1 -and $want.Count -eq 1) "'$($p.Name)': expected exactly one frame $what, got $($hit.Count) frame(s), $($want.Count) as expected"
                            Assert-KnxTrue (Test-SbcFrameForm -Entry $want[0] -System ($case.Mode -eq 1)) "'$($p.Name)': the cEMI form does not match the service (SB bit, destination, SCF)"
                            $okHop = Test-SbcHopCount -Sent $w -LData $want[0].LData
                            if (-not $okHop -and $w -ge 2 -and (Test-SbcHopCount -Sent ($w - 1) -LData $want[0].LData)) {
                                $rewrote += ("'{0}' (L_Data.con hop {1}, routed with hop {2})" -f $p.Name, $w, $want[0].LData.HopCount); continue
                            }
                            Assert-KnxTrue $okHop "'$($p.Name)': hop count $w on TP left as hop $($want[0].LData.HopCount) (08_TSSK 3.3.7)"
                        }
                        if ($rewrote.Count -gt 0) { Set-KnxTestNotRun -MissingInput 'a traffic interface that keeps the hop count' -Reason ("one decrement more than the L_Data.con explains - the interface decremented on the wire: {0}" -f ($rewrote -join ', ')) }
                        if ($changed.Count -gt 0) { Set-KnxTestNotRun -MissingInput 'a traffic interface that keeps the hop count' -Reason ("the traffic interface changed the hop count of {0}; routing passed against the hop count on TP, 3.3.7 for the requested one was not exercised" -f ($changed -join ', ')) }
                    }
                    finally {
                        if ($mc) { $mc.Dispose() }
                        if ($dm) { try { [void](Set-SbcRoutingMode -Connection $dm -Mode 0) } catch { }; Close-SbcDm $dm }
                    }
                }
            }

            # 08_TSSK 2.4.5 (80105): look-alikes leave as routing indications on the routing group; hop 0 goes nowhere.
            Invoke-KnxTestCase -Suite $SuiteTitle -Id 'S-6b.12' -Title 'TP broadcasts that only look like system broadcasts leave as ROUTING_INDICATION, never as 0533h' `
                               -Clause '03_02_06 4.1.3 p.8; 08_TSSK 2.4.5 (80105) p.165-168' -Body {
                & $gate -Moved -Tp -Rx
                $dm = $null; $mc = $null; $t = & $traffic
                try {
                    $dm = & $openDm
                    [void](Set-SbcProgMode -Connection $dm -On $false)
                    & $mode $dm 1 $t $script:SbcForeignGroup
                    $mc = Open-SbcListener -Port $port -Groups @($script:SbcForeignGroup)
                    $fails = New-Object System.Collections.Generic.List[string]
                    $wire = @{}
                    foreach ($p in @($toIpLookalike) + @($toIpHop0)) { $wire[$p.Name] = & $sendTp $t $p $fails }
                    # Control, sent last: an eligible probe must still leave as 0533h, or "never as 0533h" above means nothing.
                    $ctl = @{ Name = 'S-A_Data SBC=1 T=1 (control)'; Tpdu = (Get-SbcTpduSecure -Scf 0x88 -Seed 21); Hop = 7 }
                    $wire[$ctl.Name] = & $sendTp $t $ctl $fails
                    $onFor = ([System.Diagnostics.Stopwatch]::GetTimestamp() - $script:SbcModeAsked) / [double][System.Diagnostics.Stopwatch]::Frequency
                    $frames = @((Read-SbcBoth -Listener $mc -DeviceIp $ip -Connection $t -CollectMs 3000).Ip)
                    foreach ($p in @($toIpLookalike) + @($toIpHop0)) { & $note @(Select-SbcTpdu -Frames $frames -Tpdu $p.Tpdu) $p.Name }
                    # The hop 0 probes and the control are eligible PDUs: how they leave is judged by the hop 0 rule and the control, never as look-alikes.
                    $notHop0 = @($toIpHop0 | Where-Object { [int]$wire[$_.Name] -ne 0 })
                    $judged = @($frames | Where-Object { $f = $_; @(@($toIpHop0) + @($ctl) | Where-Object { $null -ne $f.LData -and (Test-SbcTpduEqual -A $f.LData.Tpdu -B $_.Tpdu) }).Count -eq 0 })
                    # Violations first: a frame seen where none may be is a FAIL whatever the gates below say.
                    $sys0533 = @($judged | Where-Object { $_.Service -eq 0x0533 })
                    $sys = @($toIpLookalike | Where-Object { $q = $_; @($sys0533 | Where-Object { $null -ne $_.LData -and (Test-SbcTpduEqual -A $_.LData.Tpdu -B $q.Tpdu) }).Count -gt 0 } | ForEach-Object { $_.Name })
                    $stray = @($sys0533 | Where-Object { $f = $_; $null -eq $f.LData -or @($toIpLookalike | Where-Object { Test-SbcTpduEqual -A $f.LData.Tpdu -B $_.Tpdu }).Count -eq 0 }).Count
                    Assert-KnxTrue ($sys.Count -eq 0 -and $stray -eq 0) ("look-alike left as ROUTING_SYSTEM_BROADCAST: {0}" -f $(if ($sys.Count) { $sys -join ', ' } else { "$stray frame(s) matching no probe" }))
                    # A hop 0 probe that is routed all the same: this rig cannot tell a router that ignores hop 0 from an interface that changed it on the wire.
                    $rewrote = @()
                    foreach ($p in @($toIpLookalike) + @($toIpHop0)) {
                        $hit = @(Select-SbcTpdu -Frames $frames -Tpdu $p.Tpdu)
                        Assert-KnxTrue ($hit.Count -le 1) "'$($p.Name)' left the TP line $($hit.Count) times"
                        if ([int]$wire[$p.Name] -eq 0 -and $hit.Count -gt 0) { $rewrote += ("'{0}' (L_Data.con hop 0, routed with hop {1})" -f $p.Name, $hit[0].LData.HopCount) }
                    }
                    # Gates for the frames that must be there; "never as 0533h" means something only while mode 1 was on (fall-back no earlier than 19 s).
                    & $tpGate $fails
                    if ($onFor -gt 19.0) { Set-KnxTestNotRun -MissingInput 'traffic interface timing' -Reason ("the probes took up to {0:N1} s after the enable request - the mode may have fallen back before the last one" -f $onFor) }
                    # A look-alike that went on TP with hop count 0 cannot show how it is routed.
                    $unexercised = @($notHop0 | ForEach-Object { $_.Name })
                    foreach ($p in $toIpLookalike) {
                        if ([int]$wire[$p.Name] -eq 0) { $unexercised += $p.Name; continue }
                        $hit = @(Select-SbcTpdu -Frames $frames -Tpdu $p.Tpdu)
                        $ri = @($hit | Where-Object { $_.Service -eq 0x0530 -and $_.Group -eq $script:SbcForeignGroup })
                        # Mode 1 is on here: a missing routing indication is a FAIL even with BROADCAST_LOCK (08_TSSK 2.4.31).
                        Assert-KnxTrue ($hit.Count -eq 1 -and $ri.Count -eq 1) "'$($p.Name)': expected exactly one ROUTING_INDICATION on $($script:SbcForeignGroup), got $($hit.Count) frame(s)"
                    }
                    $ctlHit = @(Select-SbcTpdu -Frames $frames -Tpdu $ctl.Tpdu)
                    & $note $ctlHit $ctl.Name
                    Assert-KnxTrue (@($ctlHit | Where-Object { $_.Service -eq 0x0533 -and $_.Group -eq $script:SbcSetupGroup }).Count -eq 1) "control: an eligible S-A_Data SBC=1 T=1 sent after the look-alikes did not leave as 0533h on 224.0.23.12 - mode 1 did not route system broadcasts, the absence of 0533h above means nothing"
                    if ($rewrote.Count -gt 0) { Set-KnxTestNotRun -MissingInput 'a traffic interface that keeps hop count 0' -Reason ("routed although the L_Data.con shows hop 0 - either the interface changed it on the wire or the router ignores hop 0; this rig cannot tell: {0}" -f ($rewrote -join ', ')) }
                    if ($unexercised.Count -gt 0) { Set-KnxTestNotRun -MissingInput 'a traffic interface that keeps the hop count' -Reason ("the traffic interface put {0} on TP with another hop count than requested, so their rule was not exercised" -f ($unexercised -join ', ')) }
                }
                finally {
                    if ($mc) { $mc.Dispose() }
                    if ($dm) { try { [void](Set-SbcRoutingMode -Connection $dm -Mode 0) } catch { }; Close-SbcDm $dm }
                }
            }

            & $mgmtCases '.F' $script:SbcForeignGroup -Moved
        }
        finally {
            # Restore in plain code: a case filter cannot skip it. A device whose PID 66 was never written has nothing to restore.
            $restored = $true
            $restoreNote = 'PID_ROUTING_MULTICAST_ADDRESS was never written in block B - nothing to restore'
            if ($script:SbcGroupTouched) { $restoreNote = ''; $restored = & $goHome 'block B' }
            else { & $disarm }
            $script:SbcMovedOk = $false
            $script:SbcGroupTouched = $false
            Invoke-KnxTestCase -Suite $SuiteTitle -Id 'S-6b.R1' -Title "The routing group is back on $devGroup after block B" -Clause 'test hygiene' -Body {
                if ($restoreNote) { Add-KnxEvidence -Note $restoreNote }
                Assert-KnxTrue $restored "restore failed: the device may stay on $($script:SbcForeignGroup) - set PID 66 to $devGroup and reset it by hand"
            }
        }
    }
    elseif ((-not $selectedB -or $stranded) -and (Test-KnxCaseSelected -Id 'S-6b.R1')) { & $homeCase 'S-6b.R1' 'block B' }
    if (-not $movable -and $selectedB) {
        # One placeholder per selected id, so a filtered run never ends without a result row.
        foreach ($bId in @($blockB | Where-Object { Test-KnxCaseSelected -Id $_ })) {
            Invoke-KnxTestCase -Suite $SuiteTitle -Id $bId -Title 'Block B: system broadcast with the device on a foreign routing group (80102-80105, 80113, 80123)' -Clause '08_TSSK 2.4.1-2.4.5, 2.4.13, 2.4.23' -Body {
                & $gate -Destructive -Rx
                if (-not $dev.Serial) { Set-KnxTestSkip 'the serial number of the device could not be read' }
                Set-KnxTestSkip "the device already routes on $($script:SbcForeignGroup), or its state is not known"
            }
        }
    }

    # ── C: the 4 octet domain address write, 08_TSSK 2.4.15/2.4.25 (80115, 80125) ────────────────

    foreach ($case in @(@{ Id = 'S-6b.13'; Sbc = $true; Tool = '2.4.15 (80115)' }, @{ Id = 'S-6b.14'; Sbc = $false; Tool = '2.4.25 (80125)' })) {
        $how = if ($case.Sbc) { 'by IP system broadcast' } else { 'by broadcast on the routing group' }
        $script:SbcWritten = $false
        # try/finally: a stopped run still restores; the runner holds the way back meanwhile ($arm).
        try {
            Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title "A_DomainAddressSerialNumber_Write (4 octets) $how moves the routing multicast address" `
                               -Clause "03_02_06 4.3.5.3.4 p.12; 03_04_01 (4 octet IP DoA); 08_TSSK $($case.Tool)" -Body {
                & $gate -Destructive -Rx
                if ($devGroup -eq $script:SbcForeignGroup) { Set-KnxTestNotRun -MissingInput "routing group != $($script:SbcForeignGroup)" -Reason 'the device already routes on the group this case moves it to' }
                $tpdu = Get-SbcTpduDoaWrite -Serial $dev.Serial -Doa ([System.Net.IPAddress]::Parse($script:SbcForeignGroup).GetAddressBytes())
                & $arm
                $script:SbcWritten = $true # from here on the device may have moved: block C restores in any case
                if ($case.Sbc) { $f = New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $tpdu -System); Send-SbcDatagram -Ip $script:SbcSetupGroup -Port $port -Frame $f }
                else { $f = New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $tpdu) -Indication; Send-SbcDatagram -Ip $devGroup -Port $port -Frame $f }
                Add-KnxEvidence -Sent $f
                # 4.3.5.3.4: the client waits 1 s, then tries the new group every second for up to 60 s.
                Start-Sleep -Milliseconds 1000
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $there = Test-SbcDeviceOnGroup -Ip $ip -Port $port -Group $script:SbcForeignGroup -Pa $pa -TimeoutSec 60
                Add-KnxEvidence -Note ("answer on {0}: {1} after {2:N1} s" -f $script:SbcForeignGroup, $there, $sw.Elapsed.TotalSeconds)
                $now = $null
                $dm = Open-SbcDm -Ip $ip -Port $port
                if ($null -ne $dm) { try { $now = Get-SbcRoutingGroup -Connection $dm } finally { Close-SbcDm $dm } }
                Add-KnxEvidence -Note "PID 66 after the write: $(if ($null -eq $now) { 'no answer' } else { $now })"
                if ($null -ne $now) { Assert-KnxEqual $script:SbcForeignGroup $now 'PID_ROUTING_MULTICAST_ADDRESS does not hold the written domain address' }
                # Moved by PID 66 but silent on the group: NOT-RUN unless block B proved this host receives that group (03_02_06 4.3.5.3.4: 60 s, then failed).
                if (-not $there -and $now -eq $script:SbcForeignGroup -and -not $script:SbcRxForeign) { Set-KnxTestNotRun -MissingInput "multicast reception on $($script:SbcForeignGroup)" -Reason "PID 66 holds $($script:SbcForeignGroup), but no descriptor answer arrived there within 60 s - this host may not receive that group" }
                Assert-KnxTrue $there "no A_DeviceDescriptor_Response on $($script:SbcForeignGroup) within 60 s"
                if ($null -eq $now) { Set-KnxTestNotRun -MissingInput 'PID_ROUTING_MULTICAST_ADDRESS' -Reason 'the device answers on the written group, but PID 66 could not be read back' }
            }
        }
        finally {
            if ($script:SbcWritten) {
                $restored = & $goHome $case.Id
                Invoke-KnxTestCase -Suite $SuiteTitle -Id "$($case.Id).R" -Title "The routing group is back on $devGroup after $($case.Id)" -Clause 'test hygiene' -Body {
                    Assert-KnxTrue $restored "restore failed: the device may stay on $($script:SbcForeignGroup) - set PID 66 to $devGroup and reset it by hand"
                }
                $script:SbcWritten = $false
            }
            elseif (-not (Test-KnxCaseSelected -Id $case.Id) -and (Test-KnxCaseSelected -Id "$($case.Id).R")) { & $homeCase "$($case.Id).R" $case.Id }
        }
    }

    # 03_02_06 4.3.5.3.1 NOTE 2: a domain address write in a routing indication with SB 0 leaves the routing multicast address alone.
    $script:SbcWritten = $false
    $script:SbcCtlMoved = ''
    # try/finally: a stopped run still restores; the runner holds the way back meanwhile ($arm).
    try {
        Invoke-KnxTestCase -Suite $SuiteTitle -Id 'S-6b.18' -Title 'A_DomainAddressSerialNumber_Write in a routing indication with a system broadcast cEMI (SB 0) is ignored' `
                           -Clause '03_02_06 4.3.5.3.1 NOTE 2 p.12, 4.3.5.3.4' -Body {
            & $gate -Destructive -Rx
            if ($devGroup -eq $script:SbcForeignGroup) { Set-KnxTestNotRun -MissingInput "routing group != $($script:SbcForeignGroup)" -Reason 'the device already routes on the group the write names' }
            $dm = $null; $mc = $null; $progOn = $false
            try {
                $dm = & $openDm
                $before = Get-SbcRoutingGroup -Connection $dm
                if ($before -ne $devGroup) { Set-KnxTestNotRun -MissingInput 'PID_ROUTING_MULTICAST_ADDRESS' -Reason "PID 66 read '$before' before the probe, not $devGroup" }
                Assert-KnxTrue (Set-SbcProgMode -Connection $dm -On $true) 'programming mode could not be switched on'
                $progOn = $true
                $mc = Open-SbcListener -Port $port -Groups @($devGroup)
                $doa = Get-SbcTpduDoaWrite -Serial $dev.Serial -Doa ([System.Net.IPAddress]::Parse($script:SbcForeignGroup).GetAddressBytes())
                $f = New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $doa -System) -Indication
                & $arm
                $script:SbcWritten = $true # from here on the device may have moved: the finally below checks and restores it
                Send-SbcDatagram -Ip $devGroup -Port $port -Frame $f
                Add-KnxEvidence -Sent $f
                # 4.3.5.3.4: a device that takes the write accepts it within 1 s; read back after twice that, retried while a restart may last (03_05_02 t2 = 5 s).
                Start-Sleep -Milliseconds 2000
                $after = $null
                $sw = [Diagnostics.Stopwatch]::StartNew()
                while ($null -eq $after -and $sw.Elapsed.TotalSeconds -lt 10) {
                    if ($null -eq $dm) { $dm = Open-SbcDm -Ip $ip -Port $port }
                    if ($null -ne $dm) { $after = Get-SbcRoutingGroup -Connection $dm }
                    if ($null -eq $after) { if ($dm) { Close-SbcDm $dm }; $dm = $null; Start-Sleep -Milliseconds 1000 }
                }
                Add-KnxEvidence -Note "PID 66 before $before, after $(if ($null -eq $after) { 'no answer' } else { $after })"
                if ($null -ne $after) { Assert-KnxEqual $devGroup $after 'PID_ROUTING_MULTICAST_ADDRESS changed on a domain address write in a routing indication with SB 0 (NOTE 2)' }
                else {
                    Assert-KnxTrue (-not (Test-SbcDeviceOnGroup -Ip $ip -Port $port -Group $script:SbcForeignGroup -Pa $pa -TimeoutSec 10)) "the device answers on $($script:SbcForeignGroup) after a domain address write in a routing indication with SB 0 (NOTE 2)"
                    Set-KnxTestNotRun -MissingInput 'PID_ROUTING_MULTICAST_ADDRESS' -Reason 'PID 66 could not be read back within 10 s after the probe, and the device does not answer on the written group'
                }
                Assert-KnxTrue (Set-SbcProgMode -Connection $dm -On $true) 'programming mode could not be switched on again'
                # Control 1, required (4.3.5.3.2): a broadcast routing indication on the same group is still served there.
                Send-SbcDatagram -Ip $devGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu ([byte[]]@(0x03, 0xDA, 0x00, 0x00, 0x0B, 0x01))) -Indication)
                $dom = @(Select-SbcApdu -Frames @(Read-SbcFromDevice -Listener $mc -DeviceIp $ip -CollectMs 2500) -Apci ([byte[]]@(0x03, 0xDB)) | Where-Object { $_.LData.Source -eq $pa -and $_.Group -eq $devGroup })
                Assert-KnxTrue ($dom.Count -ge 1) "control: A_NetworkParameter_Read by broadcast on $devGroup got no answer there in programming mode (4.3.5.3.2) - the unchanged PID 66 means nothing"
                # Control 2: the same write with SB 1 is processed (4.3.5.3.4); a device that ignores every domain address write proves nothing above.
                $c = $dm; $dm = $null
                Exit-SbcDmMode -Connection $c
                Send-SbcDatagram -Ip $devGroup -Port $port -Frame (New-SbcDatagram -Cemi (New-SbcCemi -Tpdu $doa) -Indication)
                $script:SbcCtlMoved = 'sent'
                Start-Sleep -Milliseconds 1000
                $moved = Test-SbcDeviceOnGroup -Ip $ip -Port $port -Group $script:SbcForeignGroup -Pa $pa -TimeoutSec 60
                if ($moved) { $script:SbcCtlMoved = 'moved' }
                Add-KnxEvidence -Note "control: the same write with SB 1 moved the device to $($script:SbcForeignGroup): $moved"
                if (-not $moved) { Set-KnxTestNotRun -MissingInput 'domain address write support' -Reason 'control: the same write as broadcast (SB 1) did not move the device either (Security Mode or not supported) - the unchanged PID 66 above means nothing' }
            }
            finally {
                if ($mc) { $mc.Dispose() }
                # The read-back loop or control 2 may have dropped the connection: programming mode goes off over a fresh one then.
                Clear-SbcProgMode -Connection $dm -Ip $ip -Port $port -WasOn $progOn
            }
        }
    }
    finally {
        if ($script:SbcWritten) {
            # PID 66 and the answer on the group both show the device where it was.
            $atHome = $false
            $c = Open-SbcDm -Ip $ip -Port $port
            if ($null -ne $c) { try { $atHome = ((Get-SbcRoutingGroup -Connection $c) -eq $devGroup) } catch { } finally { Close-SbcDm $c } }
            if ($atHome) { $atHome = Test-SbcDeviceOnGroup -Ip $ip -Port $port -Group $devGroup -Pa $pa -TimeoutSec 10 }
            $restored = $atHome
            if ($atHome) { & $disarm } else { $restored = & $goHome 'S-6b.18' }
            Invoke-KnxTestCase -Suite $SuiteTitle -Id 'S-6b.18.R' -Title "The routing group is on $devGroup after S-6b.18" -Clause 'test hygiene' -Body {
                $why = switch ($script:SbcCtlMoved) { 'moved' { 'moved by the SB 1 control' } 'sent' { 'not found on its group after the SB 1 control was sent' } default { 'not found on its group after the SB 0 probe' } }
                $how = if ($restored) { 'restored by PID 66 write and reset' } else { 'the restore by PID 66 write and reset failed' }
                Add-KnxEvidence -Note $(if ($atHome) { 'the device was on its group, no restore needed' } else { "the device was $why`: $how" })
                Assert-KnxTrue $restored "restore failed: the device may stay on $($script:SbcForeignGroup) - set PID 66 to $devGroup and reset it by hand"
            }
            $script:SbcWritten = $false
        }
        elseif (-not (Test-KnxCaseSelected -Id 'S-6b.18') -and (Test-KnxCaseSelected -Id 'S-6b.18.R')) { & $homeCase 'S-6b.18.R' 'S-6b.18' }
    }

    # 08_TSSK 2.4.30 (80130): IP system broadcast support is advertised as routing version 2 or higher.
    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'S-6b.15' -Title 'The supported service families DIB reports routing version 2 or higher' `
                       -Clause '03_08_02 7.6.4; 08_TSSK 2.4.30 (80130) p.197' -Body {
        if (-not $Ctx.IsRouter) { Set-KnxTestNotApplicable 'only a router advertises the routing service family' }
        $K = Get-KnxConstants
        $d = Get-KnxDescription -Ip $ip -Port $port
        Assert-KnxTrue ($null -ne $d) 'no DESCRIPTION_RESPONSE'
        $r = @($d.Families | Where-Object { $_.Id -eq $K.Family.ROUTING })
        Add-KnxEvidence -Received $d.Body -Note ("families: " + (@($d.Families | ForEach-Object { "$($_.Name) v$($_.Version)" }) -join ', '))
        Assert-KnxTrue ($r.Count -eq 1) 'the routing service family is not advertised'
        Assert-KnxTrue ($r[0].Version -ge 2) "routing is advertised as version $($r[0].Version)"
        # With Core v2 the same DIB in SEARCH_RESPONSE_EXTENDED (GlPro_ReadSupportedServiceFamiliesDib(coreV2 = true)).
        $core = @($d.Families | Where-Object { $_.Id -eq $K.Family.CORE })
        if ($core.Count -ge 1 -and $core[0].Version -ge 2) {
            $x = Get-SbcSearchExtended -Ip $ip -Port $port
            Assert-KnxTrue ($null -ne $x) 'Core v2 is advertised, but SEARCH_REQUEST_EXTENDED got no SEARCH_RESPONSE_EXTENDED'
            Add-KnxEvidence -Received $x.Body -Note ("extended search families: " + (@($x.Families | ForEach-Object { "$($_.Name) v$($_.Version)" }) -join ', '))
            $rx = @($x.Families | Where-Object { $_.Id -eq $K.Family.ROUTING })
            Assert-KnxTrue ($rx.Count -eq 1) 'SEARCH_RESPONSE_EXTENDED does not advertise the routing service family'
            Assert-KnxTrue ($rx[0].Version -ge 2) "SEARCH_RESPONSE_EXTENDED advertises routing as version $($rx[0].Version)"
        }
        else { Add-KnxEvidence -Note 'Core v1 advertised: no SEARCH_REQUEST_EXTENDED (08_TSSK 2.4.30)' }
    }
}
