#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Invoke-DptVectors
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/runners/Invoke-DptVectors.ps1

<#
.SYNOPSIS
    Runs the datapoint converter of lib/knx against a vector table on this machine.
    No device, no bus, no network.

.DESCRIPTION
    KNX_Encode_Value and KNX_Decode_Value are pure functions: a value goes in, octets
    come out, and back. That makes them the one part of the stack that can be settled
    on a desk - and the part where a wrong bound is invisible until a peer reads a
    plausible but wrong number off the bus.

    The host driver (host/dpt/dpt-driver.cpp) links the REAL converter sources. It
    carries no expectations of its own; those live in host/dpt/vectors.tsv next to the
    reason each one exists. A wrong expectation therefore cannot hide inside the code
    under test, and every vector states which clause or fix it covers.

    Each vector is one line:
        id <TAB> dir <TAB> main.sub.index <TAB> input <TAB> expected <TAB> why
          dir      enc | dec
          input    enc: a number, or "tm:Y,M,D,h,m,s,wd"   dec: payload hex
          expected OK | REJECT | OK=<output>  (OK=... also compares the produced payload or value)

    Exit code 0 when every vector matches, 1 otherwise.

.PARAMETER Rebuild
    Rebuild the driver even when the binary is newer than its sources.

.PARAMETER ShowAll
    Print every vector, not only the failures.

.EXAMPLE
    pwsh runners/Invoke-DptVectors.ps1
    Builds the driver if needed and reports only what failed.

.EXAMPLE
    pwsh runners/Invoke-DptVectors.ps1 -ShowAll
    Prints the produced payload or value for every vector.

.NOTES
    The driver needs a C++17 compiler. On macOS it uses xcrun so the SDK path is
    resolved the same way PlatformIO does; a bare clang++ fails with "cstdint not found".
#>

[CmdletBinding()]
param(
    [switch] $Rebuild,
    [switch] $ShowAll
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$hostDir = Join-Path (Split-Path -Parent $here) 'host/dpt'
# Built outside the repository and named after the source tree it was built from: a binary next to the
# sources would be taken as up to date on a checkout for another OS, and one shared name would hand one
# checkout's converter to another.
$knxSrc  = Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $here))) 'lib/knx/src'
$srcKey  = [BitConverter]::ToString([System.Security.Cryptography.SHA1]::Create().ComputeHash(
               [System.Text.Encoding]::UTF8.GetBytes(((Resolve-Path $knxSrc).Path)))).Replace('-', '').Substring(0, 12)
$driver  = Join-Path ([System.IO.Path]::GetTempPath()) "openknx-dpt-driver-$srcKey"
if ($env:OS -eq 'Windows_NT') { $driver += '.exe' }
$srcDrv  = Join-Path $hostDir 'dpt-driver.cpp'
$vectors = Join-Path $hostDir 'vectors.tsv'

if (-not (Test-Path $vectors)) { throw "Vector table missing: $vectors" }
if (-not (Test-Path $knxSrc))  { throw "knx sources missing: $knxSrc" }

$needBuild = $Rebuild -or (-not (Test-Path $driver))
if (-not $needBuild) {
    $bin = (Get-Item $driver).LastWriteTimeUtc
    foreach ($f in @($srcDrv,
                     (Join-Path $knxSrc 'knx/dptconvert.cpp'), (Join-Path $knxSrc 'knx/dptconvert.h'),
                     (Join-Path $knxSrc 'knx/dpt.cpp'), (Join-Path $knxSrc 'knx/dpt.h'),
                     (Join-Path $knxSrc 'knx/knx_value.cpp'), (Join-Path $knxSrc 'knx/knx_value.h'),
                     (Join-Path $knxSrc 'knx/bits.h'))) {
        if ((Get-Item $f).LastWriteTimeUtc -gt $bin) { $needBuild = $true; break }
    }
}

if ($needBuild) {
    Write-Host '  building host driver ...' -ForegroundColor DarkGray
    $sources = @($srcDrv,
                 (Join-Path $knxSrc 'knx/dptconvert.cpp'),
                 (Join-Path $knxSrc 'knx/dpt.cpp'),
                 (Join-Path $knxSrc 'knx/knx_value.cpp'))
    $cxxArgs = @('-std=c++17','-O1',"-I$knxSrc","-I$knxSrc/knx",'-o',$driver) + $sources
    $onMac = (Get-Variable -Name IsMacOS -ErrorAction SilentlyContinue) -and $IsMacOS
    if ($onMac) {
        # xcrun with only the Command Line Tools has no SDK path; the full Xcode is used when it is there.
        $savedDevDir = $env:DEVELOPER_DIR
        try {
            if (Test-Path '/Applications/Xcode.app/Contents/Developer') { $env:DEVELOPER_DIR = '/Applications/Xcode.app/Contents/Developer' }
            $sdk = & xcrun --show-sdk-path
            if (-not $sdk) { throw 'xcrun found no SDK' }
            & xcrun clang++ @('-isysroot', $sdk.Trim()) @cxxArgs
        }
        finally { $env:DEVELOPER_DIR = $savedDevDir }
    } else {
        & c++ @cxxArgs
    }
    if ($LASTEXITCODE -ne 0) { throw 'driver build failed' }
}

# Expectations keyed by id, so a reordered driver output cannot silently pass.
$expect = @{}
$why    = @{}
Get-Content $vectors | ForEach-Object {
    if ($_ -match '^\s*(#|$)') { return }
    $c = $_ -split "`t"
    if ($c.Count -ge 5) { $expect[$c[0]] = $c[4]; $why[$c[0]] = if ($c.Count -ge 6) { $c[5] } else { '' } }
}

$vectorLines = Get-Content $vectors | Where-Object { $_ -notmatch '^\s*(#|$)' } |
         ForEach-Object { ($_ -split "`t")[0..3] -join "`t" }

# Pinned to a zone with a UTC offset: a converter that routes a duration through mktime() shifts it
# there, and on a UTC machine that defect would stay invisible. A fixed offset without DST rules is
# understood by the C runtimes on macOS, Linux and Windows alike. Restored afterwards.
$savedTz = $env:TZ
try {
    $env:TZ = 'CET-1'
    $results = $vectorLines | & $driver
}
finally { $env:TZ = $savedTz }

$pass = 0; $fail = 0
Write-Host ''
foreach ($line in $results) {
    $c = $line -split "`t"
    if ($c.Count -lt 3) { continue }
    $id = $c[0]; $got = $c[1]; $val = $c[2]
    if (-not $expect.ContainsKey($id)) {
        Write-Host ("  ORPHAN {0}  driver produced an id the table does not know" -f $id) -ForegroundColor Yellow
        $fail++; continue
    }
    # "OK=<output>" also pins what the converter produced; a bare OK only proves it was accepted.
    $want = $expect[$id]; $wantVal = $null
    if ($want -like 'OK=*') { $wantVal = $want.Substring(3); $want = 'OK' }
    if ($got -eq $want -and ($null -eq $wantVal -or $val -eq $wantVal)) {
        $pass++
        if ($ShowAll) { Write-Host ("  PASS   {0,-14} {1,-7} {2}" -f $id, $got, $val) -ForegroundColor DarkGreen }
    } else {
        $fail++
        Write-Host ("  FAIL   {0,-14} expected {1}, got {2} {3}" -f $id, $expect[$id], $got, $val) -ForegroundColor Red
        Write-Host ("         {0}" -f $why[$id]) -ForegroundColor DarkGray
    }
}

# A table that shrank silently is a regression of the test, not of the code.
# Membership against a set, never -notmatch on an array: that returns the non-matching
# ELEMENTS, so the condition would be true for every id as long as any line differs.
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($line in $results) { $null = $seen.Add((($line -split "`t")[0])) }
$missing = $expect.Keys | Where-Object { -not $seen.Contains($_) }
foreach ($m in $missing) {
    Write-Host ("  MISSING {0}  in the table but never reported by the driver" -f $m) -ForegroundColor Yellow
    $fail++
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host ("  {0}/{0} vectors match" -f $pass) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("  {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor Red
    exit 1
}
