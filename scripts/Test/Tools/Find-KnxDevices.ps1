#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Find-KnxDevices
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Tools/Find-KnxDevices.ps1

<#
.SYNOPSIS
    Lists every KNXnet/IP device on the LAN with the details the test scripts need.

.DESCRIPTION
    Sends a SEARCH_REQUEST to the discovery multicast group and collects every answer,
    then prints IP, individual address, name and advertised service families - i.e. exactly
    the values that go into -Ip, -TrafficIp, -ReferenceIp and -BdutPa.

    Read-only: a SEARCH_REQUEST is what ETS sends when you open the connection dialog.
    It writes nothing and touches no bus.

.PARAMETER Seconds
    How long to collect answers. Default 4 - slow devices need more than one second.

.EXAMPLE
    ./Find-KnxDevices.ps1
#>
[CmdletBinding()]
param([int]$Seconds = 4, [string]$Group = '224.0.23.12', [int]$Port = 3671)

Set-StrictMode -Version Latest
$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Import-Module (Join-Path $here 'lib/KnxTest.psm1') -Force
$K = Get-KnxConstants

. (Join-Path $PSScriptRoot '../lib/KnxLogo.ps1')
Write-KnxLogo -Title 'KNXnet/IP discovery'

$sock = New-KnxSocket -TimeoutMs 1000
try {
    $local = Get-LocalEndpointFor -DestinationIp $Group -Port $Port
    $frame = New-KnxSearchRequest -DiscoveryIp $local -DiscoveryPort (Get-SocketLocalPort -Socket $sock)
    Send-KnxFrame -Socket $sock -Frame $frame -Ip $Group -Port $Port

    $found = @{}
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        $pkt = Receive-KnxFrame -Socket $sock -TimeoutMs $left
        if ($null -eq $pkt) { continue }
        $h = Read-KnxHeader -Frame $pkt.Bytes
        if ($null -eq $h -or $h.Service -ne $K.Service.SEARCH_RESPONSE) { continue }
        # The body is the control HPAI (8 octets) followed by the DIB block.
        if ($h.Body.Length -le 8) { continue }
        $ip = ($pkt.From -split ':')[0]
        if ($found.ContainsKey($ip)) { continue }
        $dibs = Read-KnxDibs -Body $h.Body -Offset 8
        $dev = $null; $fams = @()
        foreach ($d in $dibs) {
            if ($d.Type -eq $K.Dib.DEVICE_INFO) { $dev = $d.Decoded }
            if ($d.Type -eq $K.Dib.SUPP_SVC_FAMILIES) { $fams = @($d.Decoded) }
        }
        $found[$ip] = [pscustomobject]@{ Ip = $ip; Device = $dev; Families = $fams }
    }
}
finally { $sock.Dispose() }

if ($found.Count -eq 0) {
    Write-Host '  No device answered. The discovery group may be blocked on this network;' -ForegroundColor Yellow
    Write-Host '  in that case address each device by its IP directly.' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

Write-Host ("  {0}  {1}  {2}  {3}" -f 'IP'.PadRight(16), 'PA'.PadRight(9), 'Families'.PadRight(34), 'Name')
Write-Host ('  ' + ('-' * 96)) -ForegroundColor DarkGray
foreach ($ip in ($found.Keys | Sort-Object)) {
    $f = $found[$ip]
    $pa = '?'; $name = '?'
    if ($null -ne $f.Device) { $pa = $f.Device.IndividualAddr; $name = $f.Device.FriendlyName }
    $famText = (($f.Families | ForEach-Object { $_.Name }) -join ',')
    # A device advertising ROUTING is a router - never a candidate for the interface tests.
    $col = if ($famText -match 'ROUTING') { 'Yellow' } else { 'Green' }
    Write-Host ("  {0}  {1}  {2}  {3}" -f $ip.PadRight(16), $pa.PadRight(9), $famText.PadRight(34), $name) -ForegroundColor $col
}
Write-Host ''
Write-Host '  Yellow = advertises ROUTING (a router). Green = interface.' -ForegroundColor DarkGray
Write-Host ''
