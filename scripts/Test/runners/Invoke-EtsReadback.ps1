#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Invoke-EtsReadback
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/runners/Invoke-EtsReadback.ps1

<#
.SYNOPSIS
    Replays the read services of a recorded ETS download and compares each answer with
    the one the device gave while ETS was driving it.

.DESCRIPTION
    A conformance case asserts what a clause says. This runner asserts something else, and
    something a clause cannot give: that the device still answers a real ETS the way it did
    before the firmware changed. The request/response pairs come from a busmonitor capture
    of an actual download (doc/test-reference/), so the expectations were produced by the
    tool that matters, not by a reading of the specification.

    Only READ services are replayed - property value reads, the device descriptor and a
    property description. Nothing is written, no load state is touched, and the device is
    left exactly as it was found. That makes this safe to run against a configured device
    and, being cheap, the first thing to run after a flash.

    Some answers legitimately change with the firmware. Those are listed in
    $volatile below with the reason; they are reported as INFO with both values rather
    than silently ignored - an expectation that quietly stops being checked is worse than
    one that fails.

    Exit code 0 when every stable pair matches, 1 otherwise.

.PARAMETER Ip
    Interface or router to tunnel through.

.PARAMETER Pa
    The device the capture was taken against.

.PARAMETER Pairs
    Pair table. Defaults to the capture shipped in doc/test-reference/.

.EXAMPLE
    pwsh runners/Invoke-EtsReadback.ps1 -Ip 11.11.0.126 -Pa 1.1.7
#>

[CmdletBinding()]
param(
    [string] $Ip    = '11.11.0.126',
    [string] $Pa    = '1.1.7',
    [string] $Pairs
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
if (-not $Pairs) {
    $Pairs = Join-Path (Split-Path -Parent (Split-Path -Parent $root)) 'doc/test-reference/ets-readback-pairs.tsv'
}
if (-not (Test-Path $Pairs)) { throw "pair table missing: $Pairs" }

Import-Module (Join-Path $root 'lib/KnxTest.psm1') -Force
# This runner calls the device services itself; D-Device.Tests.ps1 below imports the module too.
Import-Module (Join-Path $root 'lib/KnxDevice.psm1') -Force -DisableNameChecking
. (Join-Path $root 'Suites/D-Device.Tests.ps1')

# Answers that move with the firmware, not with a defect. Keyed by "service|request".
$volatile = @{
    'PropertyValueRead|00 38 10 01' = 'PID 56 PID_VERSION carries the firmware revision in its top bits'
}

$apci = @{
    'PropertyValueRead'       = @{ Send = 0x3D5; Expect = 0x3D6 }
    'DeviceDescriptorRead'    = @{ Send = 0x300; Expect = 0x340 }
    'PropertyDescriptionRead' = @{ Send = 0x3D8; Expect = 0x3D9 }
}

function ConvertFrom-HexText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return , ([byte[]]@()) }
    return , ([byte[]]($Text.Trim() -split '\s+' | ForEach-Object { [Convert]::ToByte($_, 16) }))
}
function ConvertTo-HexText {
    param([byte[]]$Bytes)
    if ($null -eq $Bytes -or $Bytes.Count -eq 0) { return '' }
    return (($Bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' ')
}

$rows = @()
foreach ($line in (Get-Content $Pairs)) {
    if ($line -match '^\s*(#|$)') { continue }
    $c = $line -split "`t"
    if ($c.Count -lt 3) { continue }
    $rows += [pscustomobject]@{ Service = $c[0]; Request = $c[1]; Expected = $c[2] }
}

Write-Host ''
Write-Host ("  ETS-Rueckspielung  {0} ueber {1}  --  {2} Paare" -f $Pa, $Ip, $rows.Count)
Write-Host ''

$session = Open-KnxDeviceSession -Ip $Ip -Pa $Pa -Connect
if (-not $session.Ok) {
    Write-Host ("  session failed: {0}" -f $session.Reason) -ForegroundColor Red
    exit 1
}

$pass = 0; $fail = 0; $info = 0
try {
    foreach ($r in $rows) {
        if (-not $apci.ContainsKey($r.Service)) {
            Write-Host ("  SKIP  {0}  no APCI mapping" -f $r.Service) -ForegroundColor DarkGray
            continue
        }
        $req = ConvertFrom-HexText $r.Request
        $res = Invoke-KnxDeviceService -Session $session -Apci $apci[$r.Service].Send `
                                       -Data $req -ExpectApci $apci[$r.Service].Expect -TimeoutMs 6000
        $got = ''
        if ($null -ne $res.Response -and $res.Response.Count -gt 2) {
            $got = ConvertTo-HexText ([byte[]]$res.Response[2..($res.Response.Count - 1)])
        }
        $key = "{0}|{1}" -f $r.Service, $r.Request
        $label = "{0,-24} {1}" -f $r.Service, $r.Request

        if ($got -eq $r.Expected) {
            $pass++
            Write-Host ("  PASS  {0}" -f $label) -ForegroundColor DarkGreen
        } elseif ($volatile.ContainsKey($key)) {
            $info++
            Write-Host ("  INFO  {0}" -f $label) -ForegroundColor DarkCyan
            Write-Host ("        damals '{0}'  jetzt '{1}'  --  {2}" -f $r.Expected, $got, $volatile[$key]) -ForegroundColor DarkGray
        } else {
            $fail++
            Write-Host ("  FAIL  {0}" -f $label) -ForegroundColor Red
            Write-Host ("        erwartet '{0}'" -f $r.Expected) -ForegroundColor DarkGray
            Write-Host ("        erhalten '{0}'" -f $got) -ForegroundColor DarkGray
        }
    }
}
finally {
    Close-KnxDeviceSession -Session $session
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host ("  {0} identisch, {1} firmware-abhaengig, 0 abweichend" -f $pass, $info) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("  {0} identisch, {1} firmware-abhaengig, {2} ABWEICHEND" -f $pass, $info, $fail) -ForegroundColor Red
    exit 1
}
