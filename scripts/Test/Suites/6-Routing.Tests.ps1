#!/usr/bin/env pwsh
<#
Open ■
┬────┴  6-Routing.Tests
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: scripts/Test/Suites/6-Routing.Tests.ps1

.SYNOPSIS
    TSSH section 6 - Routing. Full coverage for a router; a MUST-NOT check for an interface.

.DESCRIPTION
    Dot-sourced by Invoke-Conformance.ps1, which then calls Invoke-KnxSuiteRouting.

    For an INTERFACE this section is not "not applicable" - it is a negative test. The
    device must not advertise the ROUTING service family and must not act on a
    ROUTING_INDICATION. That property is what makes its hardware busmonitor permissible
    at all (03_08_04 section 2.2.4), so it is verified actively rather than assumed.

    SAFETY: these cases put traffic on a multicast group. Invoke-Conformance.ps1 refuses
    to run this suite on the production group; the suite additionally re-checks it here,
    because a suite that can be dot-sourced directly must carry its own guard.
#>

Set-StrictMode -Version Latest

$script:ProductionMulticastGroup = '224.0.23.12'

function Send-RoutingIndication {
    <#
    .SYNOPSIS
        Sends a ROUTING_INDICATION to the multicast group and returns the socket used.
    #>
    param([string]$Group, [int]$Port, [byte[]]$Cemi)
    $s = New-KnxSocket -TimeoutMs 1500
    try {
        $f = New-KnxRoutingIndication -Cemi $Cemi
        Send-KnxFrame -Socket $s -Frame $f -Ip $Group -Port $Port
        return $f
    }
    finally { $s.Dispose() }
}

function Get-RoutingCounter {
    <#
    .SYNOPSIS
        Reads one of the routing message counters from the KNXnet/IP parameter object.
    #>
    param($Connection, [int]$PropertyId)
    $K = Get-KnxConstants
    $r = Read-KnxProperty -Connection $Connection -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $PropertyId
    if ($null -eq $r.Parsed -or $r.Parsed.IsError) { return -1 }
    $d = $r.Parsed.Data
    if ($d.Length -ge 2) { return (Get-Uint16 -Bytes $d -Offset 0) }
    if ($d.Length -eq 1) { return [int]$d[0] }
    return -1
}

function Invoke-KnxSuiteRouting {
    param([Parameter(Mandatory)]$Ctx, [string]$SuiteTitle = '6 Routing')

    $K = Get-KnxConstants
    $ip = $Ctx.BdutIp
    $port = $Ctx.Port
    $group = $Ctx.Multicast

    # ── Interface: the whole section is a MUST-NOT ──────────────────────────────

    if (-not $Ctx.IsRouter) {
        Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-6.NEG.1' -Title 'Interface must not advertise the ROUTING service family' -Clause '03_08_02 Core, Supported Service Families DIB; 03_08_04 section 2.2.4' -Body {
            $d = Get-KnxDescription -Ip $ip -Port $port
            Assert-KnxTrue ($null -ne $d) 'no description'
            Add-KnxEvidence -Received $d.Body -Note ("advertised: " + (($d.Families | ForEach-Object { $_.Name }) -join ', '))
            Assert-KnxTrue (-not (Test-KnxFamilySupported -Body $d.Body -Family $K.Family.ROUTING)) `
                'the device advertises ROUTING - it is therefore a KNXnet/IP routing device, and a routing device must not offer a KNX busmonitor'
        }

        Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-6.NEG.2' -Title 'Interface must not forward a ROUTING_INDICATION to the bus' -Clause 'TSSH 6.1.1 (inverted); 03_08_05 Routing' -Body {
            if ($Ctx.ReadOnly) { Set-KnxTestSkip 'profile ReadOnly - this case emits multicast traffic' }
            if ($group -eq $script:ProductionMulticastGroup) { Set-KnxTestSkip "refusing to emit on the production multicast group $group - pass a lab group via -Multicast" }
            if (-not $Ctx.TrafficIp) { Set-KnxTestSkip 'needs a second interface (-TrafficIp) to observe the bus' }

            # Watch the bus through the traffic interface while a routing indication is
            # emitted. An interface must ignore it: nothing may appear on TP.
            $watch = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp
            Assert-KnxTrue ($null -ne $watch) 'no tunnel available on the traffic interface'
            try {
                Clear-KnxSocket -Socket $watch.Socket -QuietMs 500
                $ga = ConvertTo-KnxGa -Address '0/0/21'
                $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Destination $ga -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
                $sent = Send-RoutingIndication -Group $group -Port $port -Cemi $cemi
                Add-KnxEvidence -Sent $sent -Note "emitted on $group"

                $leaked = $null
                $deadline = [DateTime]::UtcNow.AddSeconds(4)
                while ([DateTime]::UtcNow -lt $deadline) {
                    $in = Receive-KnxTunnelCemi -Connection $watch -TimeoutMs 1200
                    if ($null -eq $in) { continue }
                    $ld = Read-CemiLData -Cemi $in.Cemi
                    if ($null -ne $ld -and $ld.Destination -eq $ga) { $leaked = $in; break }
                }
                if ($null -ne $leaked) { Add-KnxEvidence -Received $leaked.Cemi }
                Assert-KnxTrue ($null -eq $leaked) 'a telegram sent as ROUTING_INDICATION appeared on the TP line - the interface is routing, which it must not do'
            }
            finally { [void](Close-KnxConnection -Connection $watch) }
        }

        foreach ($id in @('H-6.1.1', 'H-6.1.2', 'H-6.1.3', 'H-6.1.4', 'H-6.1.5', 'H-6.1.6', 'H-6.1.7', 'H-6.1.8', 'H-6.1.9', 'H-6.2.1', 'H-6.2.2')) {
            Invoke-KnxTestCase -Suite $SuiteTitle -Id $id -Title 'Routing case (router only)' -Clause "TSSH $($id.Substring(2))" -Body {
                Set-KnxTestNotApplicable 'device is a KNXnet/IP interface: it does not advertise ROUTING, so the routing cases do not apply (verified positively by H-6.NEG.1 and H-6.NEG.2)'
            }
        }
        return
    }

    # ── Router: the full section ────────────────────────────────────────────────

    if ($group -eq $script:ProductionMulticastGroup) {
        foreach ($id in @('H-6.1.1', 'H-6.1.2', 'H-6.1.3', 'H-6.1.4', 'H-6.1.5', 'H-6.1.6', 'H-6.1.7', 'H-6.1.8', 'H-6.1.9', 'H-6.2.1', 'H-6.2.2')) {
            Invoke-KnxTestCase -Suite $SuiteTitle -Id $id -Title 'Routing case' -Clause "TSSH $($id.Substring(2))" -Body {
                Set-KnxTestSkip "refusing to flood the production multicast group $script:ProductionMulticastGroup - pass a lab group via -Multicast"
            }
        }
        return
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-6.1.1' -Title 'Routing Indication - Standard Case 1 (IP to KNX)' -Clause 'TSSH 6.1.1, p.102' -Body {
        if (-not $Ctx.TrafficIp) { Set-KnxTestSkip 'needs a second interface (-TrafficIp) to observe the bus' }
        $watch = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp
        Assert-KnxTrue ($null -ne $watch) 'no tunnel available on the traffic interface'
        try {
            Clear-KnxSocket -Socket $watch.Socket -QuietMs 500
            $ga = ConvertTo-KnxGa -Address '0/0/22'
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Destination $ga -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
            $sent = Send-RoutingIndication -Group $group -Port $port -Cemi $cemi
            Add-KnxEvidence -Sent $sent

            $seen = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(6)
            while ([DateTime]::UtcNow -lt $deadline) {
                $in = Receive-KnxTunnelCemi -Connection $watch -TimeoutMs 1500
                if ($null -eq $in) { continue }
                $ld = Read-CemiLData -Cemi $in.Cemi
                if ($null -ne $ld -and $ld.Destination -eq $ga) { $seen = $in; break }
            }
            Assert-KnxTrue ($null -ne $seen) 'the routed telegram never reached the TP line'
            Add-KnxEvidence -Received $seen.Cemi
        }
        finally { [void](Close-KnxConnection -Connection $watch) }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-6.1.2' -Title 'Routing Indication - Standard Case 2 (KNX to IP)' -Clause 'TSSH 6.1.2, p.102' -Body {
        if (-not $Ctx.TrafficIp) { Set-KnxTestSkip 'needs a second interface (-TrafficIp) to put a telegram on the bus' }
        $mc = New-KnxMulticastSocket -Group $group -Port $port -TimeoutMs 2000
        $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp
        try {
            Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
            $ga = ConvertTo-KnxGa -Address '0/0/23'
            $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $ga -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
            [void](Send-KnxTunnelCemi -Connection $src -Cemi $cemi -TimeoutMs 3000)

            $seen = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(6)
            while ([DateTime]::UtcNow -lt $deadline) {
                $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
                $r = Wait-KnxService -Socket $mc -Service @($K.Service.ROUTING_INDICATION) -TimeoutMs $left
                if ($r.TimedOut) { break }
                $ld = Read-CemiLData -Cemi $r.Header.Body
                if ($null -ne $ld -and $ld.Destination -eq $ga) { $seen = $r; break }
            }
            Assert-KnxTrue ($null -ne $seen) "the bus telegram was never emitted as ROUTING_INDICATION on $group"
            Add-KnxEvidence -Received $seen.Packet.Bytes
        }
        finally {
            $mc.Dispose()
        }
    }

    foreach ($case in @(
            @{ Id = 'H-6.1.3'; Title = 'Changed multicast address, Case 1'; Clause = 'TSSH 6.1.3, p.103' },
            @{ Id = 'H-6.1.4'; Title = 'Changed multicast address, Case 2'; Clause = 'TSSH 6.1.4, p.104' })) {
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title $case.Title -Clause $case.Clause -Body {
            if (-not $Ctx.AllowDestructive) { Set-KnxTestSkip 'rewrites PID_ROUTING_MULTICAST_ADDRESS - needs -IncludeDestructive with profile Full' }
            $mgmt = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
            Assert-KnxTrue $mgmt.Ok "could not open a device management connection ($($mgmt.StatusName))"
            $original = $null
            try {
                $r = Read-KnxProperty -Connection $mgmt -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.ROUTING_MULTICAST_ADDRESS
                Assert-KnxTrue ($null -ne $r.Parsed -and -not $r.Parsed.IsError) 'PID_ROUTING_MULTICAST_ADDRESS not readable'
                $original = [byte[]]$r.Parsed.Data[0..3]

                $newGroup = '224.0.23.14'
                $bytes = ([System.Net.IPAddress]::Parse($newGroup)).GetAddressBytes()
                $w = New-CemiMPropWrite -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.ROUTING_MULTICAST_ADDRESS -Data $bytes
                $wr = Send-KnxDeviceConfiguration -Connection $mgmt -Cemi $w -TimeoutMs 4000
                Assert-KnxTrue ($null -ne $wr.Parsed -and -not $wr.Parsed.IsError) 'could not write the routing multicast address'

                Start-Sleep -Seconds 2
                $back = Read-KnxProperty -Connection $mgmt -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.ROUTING_MULTICAST_ADDRESS
                Assert-KnxTrue ($null -ne $back.Parsed -and -not $back.Parsed.IsError) 'multicast address not readable after the write'
                Assert-KnxBytes $bytes ([byte[]]$back.Parsed.Data[0..3]) 'the device did not take over the new routing multicast address'
                Add-KnxEvidence -Note "switched to $newGroup and back"
            }
            finally {
                if ($null -ne $original -and $mgmt.Ok) {
                    $restore = New-CemiMPropWrite -ObjectType $K.ObjType.KNXNETIP_PARAM -PropertyId $K.Pid.ROUTING_MULTICAST_ADDRESS -Data $original
                    [void](Send-KnxDeviceConfiguration -Connection $mgmt -Cemi $restore -TimeoutMs 4000)
                }
                [void](Close-KnxConnection -Connection $mgmt)
            }
        }
    }

    foreach ($case in @(
            @{ Id = 'H-6.1.5'; Title = 'Property PID_MSG_TRANSMIT_TO_KNX'; Clause = 'TSSH 6.1.5, p.105'; ToKnx = $true },
            @{ Id = 'H-6.1.6'; Title = 'Property PID_MSG_TRANSMIT_TO_IP';  Clause = 'TSSH 6.1.6, p.107'; ToKnx = $false })) {
        $toKnx = $case.ToKnx
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title $case.Title -Clause $case.Clause -Body {
            if (-not $Ctx.TrafficIp) { Set-KnxTestSkip 'needs a second interface (-TrafficIp) to generate the routed traffic' }
            # Not $pid - that is a read-only PowerShell automatic variable (the process id).
            $propId = if ($toKnx) { $K.Pid.MSG_TRANSMIT_TO_KNX } else { $K.Pid.MSG_TRANSMIT_TO_IP }
            $mgmt = Open-KnxConnection -Ip $ip -Port $port -ConnectionType $K.ConnType.DEVICE_MGMT_CONNECTION -Layer -1
            Assert-KnxTrue $mgmt.Ok "could not open a device management connection ($($mgmt.StatusName))"
            try {
                $before = Get-RoutingCounter -Connection $mgmt -PropertyId $propId
                Assert-KnxTrue ($before -ge 0) "counter property $propId not readable"

                if ($toKnx) {
                    $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Destination (ConvertTo-KnxGa -Address '0/0/24') -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
                    foreach ($i in 1..3) { [void](Send-RoutingIndication -Group $group -Port $port -Cemi $cemi); Start-Sleep -Milliseconds 250 }
                }
                else {
                    $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp
                    Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
                    try {
                        $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination (ConvertTo-KnxGa -Address '0/0/25') -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
                        foreach ($i in 1..3) { [void](Send-KnxTunnelCemi -Connection $src -Cemi $cemi -TimeoutMs 3000); Start-Sleep -Milliseconds 250 }
                    }
                    finally { [void](Close-KnxConnection -Connection $src) }
                }

                Start-Sleep -Seconds 2
                $after = Get-RoutingCounter -Connection $mgmt -PropertyId $propId
                Add-KnxEvidence -Note "counter $before -> $after after 3 routed telegrams"
                Assert-KnxTrue ($after -ge 0) "counter property $propId not readable after the traffic"
                Assert-KnxTrue ($after -gt $before) "counter did not advance ($before -> $after) although telegrams were routed"
            }
            finally { [void](Close-KnxConnection -Connection $mgmt) }
        }
    }

    foreach ($case in @(
            @{ Id = 'H-6.1.7'; Title = 'Routing Indication - Mixed Case 1'; Clause = 'TSSH 6.1.7, p.109' },
            @{ Id = 'H-6.1.8'; Title = 'Routing Indication - Mixed Case 2'; Clause = 'TSSH 6.1.8, p.110' },
            @{ Id = 'H-6.1.9'; Title = 'Routing Indication - Mixed Case 3'; Clause = 'TSSH 6.1.9, p.111' })) {
        Invoke-KnxTestCase -Suite $SuiteTitle -Id $case.Id -Title $case.Title -Clause $case.Clause -Body {
            if (-not $Ctx.TrafficIp) { Set-KnxTestSkip 'needs a second interface (-TrafficIp) to drive both directions' }
            # Mixed = traffic in both directions at once; nothing may be lost or duplicated.
            $mc = New-KnxMulticastSocket -Group $group -Port $port -TimeoutMs 2000
            $src = Get-KnxTrafficConnection -Ip $Ctx.TrafficIp
            try {
                Assert-KnxTrue ($null -ne $src) 'no tunnel available on the traffic interface'
                $gaUp = ConvertTo-KnxGa -Address '0/0/26'
                $gaDown = ConvertTo-KnxGa -Address '0/0/27'
                $down = New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Destination $gaDown -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
                $up = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $gaUp -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)

                foreach ($i in 1..3) {
                    [void](Send-RoutingIndication -Group $group -Port $port -Cemi $down)
                    [void](Send-KnxTunnelCemi -Connection $src -Cemi $up -TimeoutMs 3000)
                    Start-Sleep -Milliseconds 200
                }

                $upSeen = 0
                $deadline = [DateTime]::UtcNow.AddSeconds(6)
                while ([DateTime]::UtcNow -lt $deadline) {
                    $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
                    $r = Wait-KnxService -Socket $mc -Service @($K.Service.ROUTING_INDICATION) -TimeoutMs $left
                    if ($r.TimedOut) { break }
                    $ld = Read-CemiLData -Cemi $r.Header.Body
                    if ($null -ne $ld -and $ld.Destination -eq $gaUp) { $upSeen++ }
                }
                Add-KnxEvidence -Note "$upSeen of 3 KNX-to-IP telegrams observed while routing in both directions"
                Assert-KnxTrue ($upSeen -ge 1) 'no KNX-to-IP telegram survived the bidirectional load'
                Assert-KnxTrue (Test-KnxAlive -Ip $ip -Port $port) 'device stopped answering under bidirectional routing load'
            }
            finally {
                $mc.Dispose()
            }
        }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-6.2.1' -Title 'Routing Lost Message - Standard Case' -Clause 'TSSH 6.2.1, p.111' -Body {
        if (-not $Ctx.AllowDestructive) { Set-KnxTestSkip 'overloads the router on purpose - needs -IncludeDestructive with profile Full' }
        $mc = New-KnxMulticastSocket -Group $group -Port $port -TimeoutMs 2000
        try {
            # Push faster than TP can carry until the device reports the overflow.
            $s = New-KnxSocket -TimeoutMs 500
            try {
                $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Destination (ConvertTo-KnxGa -Address '0/0/28') -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
                $f = New-KnxRoutingIndication -Cemi $cemi
                foreach ($i in 1..300) { Send-KnxFrame -Socket $s -Frame $f -Ip $group -Port $port }
            }
            finally { $s.Dispose() }

            $lost = $null
            $busy = $null
            $deadline = [DateTime]::UtcNow.AddSeconds(6)
            while ([DateTime]::UtcNow -lt $deadline) {
                $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
                $r = Wait-KnxService -Socket $mc -Service @($K.Service.ROUTING_LOST_MESSAGE, $K.Service.ROUTING_BUSY) -TimeoutMs $left
                if ($r.TimedOut) { break }
                if ($r.Header.Service -eq $K.Service.ROUTING_LOST_MESSAGE) { $lost = $r; break }
                if ($r.Header.Service -eq $K.Service.ROUTING_BUSY) { $busy = $r }
            }
            if ($null -ne $lost) { Add-KnxEvidence -Received $lost.Packet.Bytes -Note 'ROUTING_LOST_MESSAGE observed' }
            elseif ($null -ne $busy) { Add-KnxEvidence -Received $busy.Packet.Bytes -Note 'only ROUTING_BUSY observed' }
            Assert-KnxTrue (($null -ne $lost) -or ($null -ne $busy)) 'router neither reported ROUTING_LOST_MESSAGE nor ROUTING_BUSY while being overloaded'
            Assert-KnxTrue (Test-KnxAlive -Ip $ip -Port $port) 'device stopped answering after the overload'
        }
        finally { $mc.Dispose() }
    }

    Invoke-KnxTestCase -Suite $SuiteTitle -Id 'H-6.2.2' -Title 'Routing Lost Message - Continuous overflow' -Clause 'TSSH 6.2.2, p.112' -Body {
        if (-not $Ctx.AllowDestructive) { Set-KnxTestSkip 'sustained overload - needs -IncludeDestructive with profile Full' }
        $mc = New-KnxMulticastSocket -Group $group -Port $port -TimeoutMs 2000
        try {
            $s = New-KnxSocket -TimeoutMs 500
            $reports = 0
            try {
                $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_IND -Destination (ConvertTo-KnxGa -Address '0/0/29') -IsGroup -Tpdu (New-TpduGroupValueWrite -Value 1)
                $f = New-KnxRoutingIndication -Cemi $cemi
                $end = [DateTime]::UtcNow.AddSeconds(15)
                while ([DateTime]::UtcNow -lt $end) {
                    foreach ($i in 1..50) { Send-KnxFrame -Socket $s -Frame $f -Ip $group -Port $port }
                    $r = Wait-KnxService -Socket $mc -Service @($K.Service.ROUTING_LOST_MESSAGE, $K.Service.ROUTING_BUSY) -TimeoutMs 200
                    if (-not $r.TimedOut) { $reports++ }
                }
            }
            finally { $s.Dispose() }
            Add-KnxEvidence -Note "$reports overflow report(s) during 15 s of sustained overload"
            Assert-KnxTrue ($reports -ge 1) 'router never reported an overflow during sustained overload'
            # The point of the case is that the device survives, not just that it complains.
            Assert-KnxTrue (Test-KnxAlive -Ip $ip -Port $port) 'device stopped answering after sustained overload'
        }
        finally { $mc.Dispose() }
    }
}
