#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Test-RigNetwork
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Tools/Test-RigNetwork.ps1

<#
.SYNOPSIS
    Checks that this computer reaches the test rig, and sets or removes the routes it needs.

.DESCRIPTION
    A computer with two interfaces in the rig's subnet (wired to the rig, wireless to the house
    network) sends rig traffic out of the wrong one: the tests then report devices that do not
    answer and discovery requests nobody received, and none of it is about the device under test.

    Without a switch the script only CHECKS and changes nothing:
      - which interface the system uses for each rig device and whether the device answers,
      - which interface it uses for the KNXnet/IP discovery group,
      - and it names what to do when something is off. Exit code 0 means the rig is reachable.

    -Apply sets what is missing for this session: a host route per rig device on the rig
    interface, the device's link address as a fixed neighbour entry (on macOS a host route alone
    stops address resolution, so a learned entry expires and the device goes away after about
    20 minutes), and a route for the multicast range. Nothing is installed and nothing survives a
    restart of the computer.

    -Reset removes exactly what -Apply set. It reads that from a state file in the temp directory.

    -Apply and -Reset need root (sudo) or an elevated Windows shell.

.PARAMETER Interface
    The interface wired to the rig, e.g. en0, eth0 or "Ethernet 2". Without it the script takes
    networkInterface from Test-Bench-Config.json, else the one the last -Apply used, else the only
    interface in the rig's subnet.

.PARAMETER Hosts
    The rig devices, as a list or as one comma separated string. Default: every address named in
    Test-Bench-Config.json, else in Profiles/*.json.

.PARAMETER Multicast
    A group to check the multicast route with. Default 224.0.23.12, the KNXnet/IP discovery group.

.PARAMETER Apply
    Set the routes and neighbour entries for this session.

.PARAMETER Reset
    Remove what -Apply set.

.PARAMETER Quiet
    Print only problems and the result line.

.EXAMPLE
    ./Test-RigNetwork.ps1
.EXAMPLE
    sudo pwsh ./Test-RigNetwork.ps1 -Apply -Interface en0
.EXAMPLE
    sudo pwsh ./Test-RigNetwork.ps1 -Reset

.NOTES
    Run and measured on macOS. The Linux and Windows branches follow the documentation of
    ip(8) and of the NetTCPIP cmdlets and have not been run on a rig yet.
#>

[CmdletBinding()]
param(
    [string]$Interface = '',
    [string[]]$Hosts = @(),
    [string]$Multicast = '224.0.23.12',
    [switch]$Apply,
    [switch]$Reset,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
# One place for every user: -Apply runs as root, the check does not, and each has its own temp directory.
$legacyStatePath = Join-Path ([System.IO.Path]::GetTempPath()) 'openknx-rig-network.json'
$statePath = $legacyStatePath
if ($PSVersionTable.PSEdition -eq 'Core' -and ($IsMacOS -or $IsLinux)) { $statePath = '/tmp/openknx-rig-network.json' }

# ─── Platform ───────────────────────────────────────────────────────────────────

$os = 'windows'
if ($PSVersionTable.PSEdition -eq 'Core') {
    if ($IsMacOS) { $os = 'macos' } elseif ($IsLinux) { $os = 'linux' }
}

function Invoke-Tool {
    <#
    .SYNOPSIS
        Runs an external tool and returns its output as one string; never throws on a non-zero exit.
    #>
    param([string]$Exe, [string[]]$ArgList)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { return ((& $Exe @ArgList 2>&1) | Out-String) }
    catch { return '' }
    finally { $ErrorActionPreference = $old }
}

function Test-Elevated {
    if ($os -eq 'windows') {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    return ((Invoke-Tool 'id' @('-u')).Trim() -eq '0')
}

function Test-Reply {
    <#
    .SYNOPSIS
        One echo request; -Bound sends it out of the given interface.
    #>
    param([string]$Ip, [string]$Bound = '', [string]$SourceIp = '')
    $out = ''
    if ($os -eq 'macos') {
        if ($Bound) { $out = Invoke-Tool '/sbin/ping' @('-b', $Bound, '-c', '1', '-t', '1', $Ip) }
        else { $out = Invoke-Tool '/sbin/ping' @('-c', '1', '-t', '1', $Ip) }
    }
    elseif ($os -eq 'linux') {
        if ($Bound) { $out = Invoke-Tool 'ping' @('-I', $Bound, '-c', '1', '-W', '1', $Ip) }
        else { $out = Invoke-Tool 'ping' @('-c', '1', '-W', '1', $Ip) }
    }
    else {
        if ($SourceIp) { $out = Invoke-Tool 'ping' @('-S', $SourceIp, '-n', '1', '-w', '1000', $Ip) }
        else { $out = Invoke-Tool 'ping' @('-n', '1', '-w', '1000', $Ip) }
    }
    return ($out -match 'bytes from|TTL=')
}

function Get-RouteInterface {
    <#
    .SYNOPSIS
        The interface the system would send a packet for this address out of.
    #>
    param([string]$Ip)
    if ($os -eq 'macos') {
        if ((Invoke-Tool '/sbin/route' @('-n', 'get', $Ip)) -match 'interface:\s*(\S+)') { return $Matches[1] }
    }
    elseif ($os -eq 'linux') {
        if ((Invoke-Tool 'ip' @('-o', 'route', 'get', $Ip)) -match '\sdev\s+(\S+)') { return $Matches[1] }
    }
    else {
        try {
            $r = Find-NetRoute -RemoteIPAddress $Ip -ErrorAction Stop | Select-Object -First 1
            if ($r) { return "$($r.InterfaceAlias)" }
        }
        catch { }
    }
    return ''
}

function Get-LinkAddress {
    <#
    .SYNOPSIS
        The link address the system learned for this address on the interface, or ''.
    #>
    param([string]$Ip, [string]$If)
    if ($os -eq 'macos') {
        foreach ($line in ((Invoke-Tool '/usr/sbin/arp' @('-an')) -split "`n")) {
            if ($line -match "\($([regex]::Escape($Ip))\) at ([0-9a-fA-F:]+) on $([regex]::Escape($If)) ifscope" -and $line -notmatch 'permanent') { return $Matches[1] }
        }
    }
    elseif ($os -eq 'linux') {
        if ((Invoke-Tool 'ip' @('neigh', 'show', $Ip, 'dev', $If)) -match 'lladdr\s+([0-9a-fA-F:]+)') { return $Matches[1] }
    }
    return ''
}

# ─── Rig description ────────────────────────────────────────────────────────────

function Get-ProfileHosts {
    $found = New-Object System.Collections.Generic.List[string]
    $dir = Join-Path $testRoot 'Profiles'
    if (-not (Test-Path $dir)) { return @() }
    foreach ($f in (Get-ChildItem -Path $dir -Filter '*.json')) {
        $text = Get-Content -Path $f.FullName -Raw
        foreach ($m in [regex]::Matches($text, '\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b')) {
            $ip = $m.Groups[1].Value
            $first = [int]($ip.Split('.')[0])
            # a multicast group is no device
            if ($first -lt 224 -and -not $found.Contains($ip)) { $found.Add($ip) }
        }
    }
    return @($found | Sort-Object { [version]$_ })
}

function Get-LocalInterfaces {
    <#
    .SYNOPSIS
        Every interface that is up, with its IPv4 address and prefix mask.
    #>
    $list = @()
    foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
        foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
            if ($ua.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
            $mask = $null
            try { $mask = $ua.IPv4Mask } catch { }
            if ($null -eq $mask) { continue }
            $list += [pscustomobject]@{ Name = $ni.Name; Ip = "$($ua.Address)"; Mask = "$mask"; Index = 0 }
        }
    }
    return $list
}

function Test-SameSubnet {
    param([string]$A, [string]$B, [string]$Mask)
    $x = [System.Net.IPAddress]::Parse($A).GetAddressBytes()
    $y = [System.Net.IPAddress]::Parse($B).GetAddressBytes()
    $m = [System.Net.IPAddress]::Parse($Mask).GetAddressBytes()
    for ($i = 0; $i -lt 4; $i++) { if (($x[$i] -band $m[$i]) -ne ($y[$i] -band $m[$i])) { return $false } }
    return $true
}

function Read-State {
    foreach ($p in @($statePath, $legacyStatePath)) {
        if (-not (Test-Path $p)) { continue }
        try { return (Get-Content -Path $p -Raw | ConvertFrom-Json) } catch { }
    }
    return $null
}

# ─── Output ─────────────────────────────────────────────────────────────────────

function Write-Line {
    param([string]$Mark, [string]$Text, [string]$Color = 'Gray')
    if ($Quiet -and $Mark -eq 'OK') { return }
    Write-Host ("  {0,-5} {1}" -f $Mark, $Text) -ForegroundColor $Color
}

. (Join-Path $testRoot 'lib/KnxLogo.ps1')
. (Join-Path $testRoot 'lib/KnxBench.ps1')
if (-not $Quiet) { Write-KnxLogo -Title 'Rig network check' }
$bench = Read-KnxBenchConfig -TestRoot $testRoot

# One comma separated string is accepted as well: -File passes an array only as separate arguments.
$Hosts = @($Hosts | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
if ($Hosts.Count -eq 0) { $Hosts = @(Get-KnxBenchHosts -Bench $bench) }
if ($Hosts.Count -eq 0) { $Hosts = @(Get-ProfileHosts) }
if ($Hosts.Count -eq 0) { Write-Host '  no rig devices given and none found in Test-Bench-Config.json or Profiles/*.json' -ForegroundColor Red; exit 2 }

$state = Read-State
$locals = @(Get-LocalInterfaces)
$inSubnet = @($locals | Where-Object { Test-SameSubnet -A $_.Ip -B $Hosts[0] -Mask $_.Mask })

if (-not $Interface -and (Test-KnxObjectHas $bench 'networkInterface') -and $bench.networkInterface) { $Interface = "$($bench.networkInterface)" }
if (-not $Interface -and $state -and $state.interface) { $Interface = "$($state.interface)" }
if (-not $Interface -and $inSubnet.Count -eq 1) { $Interface = $inSubnet[0].Name }
$rigLocal = $inSubnet | Where-Object { $_.Name -eq $Interface } | Select-Object -First 1

# ─── Reset ──────────────────────────────────────────────────────────────────────

if ($Reset) {
    if ($null -eq $state) { Write-Host "  nothing to reset - no state file ($statePath)" -ForegroundColor Yellow; exit 0 }
    if (-not (Test-Elevated)) { Write-Host "  -Reset needs root: sudo pwsh $PSCommandPath -Reset" -ForegroundColor Red; exit 2 }
    $if = "$($state.interface)"
    foreach ($h in @($state.hosts)) {
        if ($os -eq 'macos') {
            [void](Invoke-Tool '/usr/sbin/arp' @('-d', "$h", 'ifscope', $if))
            [void](Invoke-Tool '/sbin/route' @('-n', 'delete', '-host', "$h"))
        }
        elseif ($os -eq 'linux') {
            [void](Invoke-Tool 'ip' @('neigh', 'del', "$h", 'dev', $if))
            [void](Invoke-Tool 'ip' @('route', 'del', "$h/32", 'dev', $if))
        }
        else {
            Remove-NetRoute -DestinationPrefix "$h/32" -InterfaceAlias $if -Confirm:$false -ErrorAction SilentlyContinue
        }
        Write-Line 'DEL' "$h"
    }
    if ($state.multicastSet) {
        if ($os -eq 'macos') {
            [void](Invoke-Tool '/sbin/route' @('-n', 'delete', '-net', '224.0.0.0/4'))
            if ($state.multicastWas) { [void](Invoke-Tool '/sbin/route' @('-n', 'add', '-net', '224.0.0.0/4', '-interface', "$($state.multicastWas)")) }
        }
        elseif ($os -eq 'linux') { [void](Invoke-Tool 'ip' @('route', 'del', '224.0.0.0/4', 'dev', $if)) }
        else { Remove-NetRoute -DestinationPrefix "$Multicast/32" -InterfaceAlias $if -Confirm:$false -ErrorAction SilentlyContinue }
        Write-Line 'DEL' 'multicast route'
    }
    foreach ($p in @($statePath, $legacyStatePath)) { if (Test-Path $p) { Remove-Item -Path $p -Force } }
    Write-Host '  the routes of the last -Apply are removed' -ForegroundColor Green
    exit 0
}

# ─── Apply ──────────────────────────────────────────────────────────────────────

if ($Apply) {
    if (-not $Interface) {
        Write-Host "  -Apply needs -Interface: $(@($inSubnet | ForEach-Object { $_.Name }) -join ', ') are in the rig's subnet" -ForegroundColor Red
        exit 2
    }
    if ($null -eq $rigLocal) { Write-Host "  $Interface has no address in the subnet of $($Hosts[0])" -ForegroundColor Red; exit 2 }
    if (-not (Test-Elevated)) { Write-Host "  -Apply needs root: sudo pwsh $PSCommandPath -Apply -Interface $Interface" -ForegroundColor Red; exit 2 }

    $set = @()
    foreach ($h in $Hosts) {
        if ($os -eq 'macos') {
            # Without the host route a bound request resolves the address; with it nothing is resolved.
            [void](Invoke-Tool '/usr/sbin/arp' @('-d', $h, 'ifscope', $Interface))
            [void](Invoke-Tool '/sbin/route' @('-n', 'delete', '-host', $h))
            if (-not (Test-Reply -Ip $h -Bound $Interface)) { Write-Line 'SKIP' "$h does not answer on $Interface - left alone" 'Yellow'; continue }
            $mac = Get-LinkAddress -Ip $h -If $Interface
            if (-not $mac) { Write-Line 'SKIP' "$h answered but no link address was learned" 'Yellow'; continue }
            [void](Invoke-Tool '/usr/sbin/arp' @('-s', $h, $mac, 'ifscope', $Interface))
            [void](Invoke-Tool '/sbin/route' @('-n', 'add', '-host', $h, '-interface', $Interface))
            Write-Line 'SET' "$h  ->  $Interface  ($mac)"
        }
        elseif ($os -eq 'linux') {
            [void](Invoke-Tool 'ip' @('route', 'replace', "$h/32", 'dev', $Interface))
            if (-not (Test-Reply -Ip $h -Bound $Interface)) { Write-Line 'WARN' "$h does not answer on $Interface" 'Yellow' }
            Write-Line 'SET' "$h  ->  $Interface"
        }
        else {
            Remove-NetRoute -DestinationPrefix "$h/32" -InterfaceAlias $Interface -Confirm:$false -ErrorAction SilentlyContinue
            [void](New-NetRoute -DestinationPrefix "$h/32" -InterfaceAlias $Interface -NextHop '0.0.0.0' -RouteMetric 1 -PolicyStore ActiveStore)
            Write-Line 'SET' "$h  ->  $Interface"
        }
        $set += $h
    }

    $mcWas = Get-RouteInterface -Ip $Multicast
    $mcSet = $false
    if ($mcWas -ne $Interface) {
        if ($os -eq 'macos') {
            [void](Invoke-Tool '/sbin/route' @('-n', 'delete', '-net', '224.0.0.0/4'))
            [void](Invoke-Tool '/sbin/route' @('-n', 'add', '-net', '224.0.0.0/4', '-interface', $Interface))
        }
        elseif ($os -eq 'linux') { [void](Invoke-Tool 'ip' @('route', 'replace', '224.0.0.0/4', 'dev', $Interface)) }
        else { [void](New-NetRoute -DestinationPrefix "$Multicast/32" -InterfaceAlias $Interface -NextHop '0.0.0.0' -RouteMetric 1 -PolicyStore ActiveStore) }
        $mcSet = $true
        Write-Line 'SET' "multicast  ->  $Interface  (was $mcWas)"
    }

    # A second -Apply keeps what the first one found, so -Reset still restores the original state.
    if ($state -and $state.multicastSet) { $mcSet = $true; $mcWas = "$($state.multicastWas)" }
    $all = @($set)
    if ($state) { foreach ($h in @($state.hosts)) { if ($all -notcontains "$h") { $all += "$h" } } }
    [pscustomobject]@{ interface = $Interface; hosts = $all; multicastSet = $mcSet; multicastWas = $mcWas; when = (Get-Date).ToString('s') } |
        ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8
    if ($os -ne 'windows') { [void](Invoke-Tool 'chmod' @('644', $statePath)) }
    Write-Host ''
}

# ─── Check ──────────────────────────────────────────────────────────────────────

$problems = 0
if (-not $Quiet) {
    Write-Host "  interfaces in the rig's subnet: $(@($inSubnet | ForEach-Object { "$($_.Name) $($_.Ip)" }) -join ' | ')" -ForegroundColor DarkGray
    Write-Host "  rig interface: $(if ($Interface) { $Interface } else { 'not known - pass -Interface' })" -ForegroundColor DarkGray
    Write-Host ''
}
if ($inSubnet.Count -eq 0) { Write-Line 'FAIL' "no interface of this computer is in the subnet of $($Hosts[0])" 'Red'; exit 1 }

$srcIp = ''
if ($rigLocal) { $srcIp = $rigLocal.Ip }
foreach ($h in $Hosts) {
    $via = Get-RouteInterface -Ip $h
    if (Test-Reply -Ip $h) { Write-Line 'OK' "$h answers (via $via)" 'Green'; continue }
    $problems++
    if ($Interface -and $via -and $via -ne $Interface) {
        Write-Line 'FAIL' "$h is sent out of $via, the rig is on $Interface" 'Red'
    }
    elseif ($Interface -and (Test-Reply -Ip $h -Bound $Interface -SourceIp $srcIp)) {
        Write-Line 'FAIL' "$h answers on $Interface but not on the route the tests use" 'Red'
    }
    else {
        Write-Line 'FAIL' "$h does not answer (route via $via) - switched off, or its address is not resolved" 'Red'
    }
}

$mcVia = Get-RouteInterface -Ip $Multicast
if ($Interface -and $mcVia -and $mcVia -ne $Interface) {
    $problems++
    Write-Line 'FAIL' "multicast $Multicast is sent out of $mcVia, the rig is on $Interface - discovery and routing cases will see nothing" 'Red'
}
elseif ($mcVia) { Write-Line 'OK' "multicast $Multicast leaves on $mcVia" 'Green' }
else { Write-Line 'WARN' "the interface for multicast $Multicast could not be read" 'Yellow' }

Write-Host ''
if ($problems -eq 0) { Write-Host '  the rig is reachable' -ForegroundColor Green; exit 0 }
$elev = 'sudo pwsh'
if ($os -eq 'windows') { $elev = 'pwsh (elevated)' }
$ifArg = '-Interface <name>'
if ($Interface) { $ifArg = "-Interface $Interface" }
Write-Host "  $problems problem(s). To set the routes for this session:" -ForegroundColor Red
Write-Host "    $elev $PSCommandPath -Apply $ifArg" -ForegroundColor Red
Write-Host "  and afterwards, to remove them:  $elev $PSCommandPath -Reset" -ForegroundColor DarkGray
exit 1
