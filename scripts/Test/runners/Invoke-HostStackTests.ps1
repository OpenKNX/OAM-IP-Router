#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Invoke-HostStackTests
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/runners/Invoke-HostStackTests.ps1

<#
.SYNOPSIS
    Builds the real knx + TPUart stack of a TP1 System B device (mask 07B0) for this machine and runs the
    host cases against it, each in its own process, under AddressSanitizer and UndefinedBehaviorSanitizer.

.DESCRIPTION
    What a bus test cannot reach - a memory error without a visible symptom, a restart, a power cut, a
    table load that ETS never sends - is reached here: host/stack links the unmodified stack sources with
    a host platform (flash with the product's sector buffer, a virtual clock) and an NCN5130 emulator on
    the UART, and drives the device with the same services ETS uses.

    Every case runs in its own process, so a sanitizer abort fails exactly that case and the rest still
    run. Sanitizer reports are collected by source location and listed at the end: they are findings in
    their own right, whatever the result of the case that happened to trigger them, and they fail the
    run on their own - a case that triggers undefined behaviour but asserts nothing about it still
    ends PASS, so the exit code must not come from the results alone.

    -KnxRef / -TPUartRef build the stack from a git revision instead of the working tree, which is how a
    case is shown to be red on the code before its fix.

.PARAMETER Filter
    Only cases whose id starts with this text.

.PARAMETER KnxRef
    Build lib/knx from this git revision (git archive), e.g. HEAD. Default: the working tree.

.PARAMETER TPUartRef
    Build lib/TPUart from this git revision. Default: the working tree.
.PARAMETER KnxSrcDir
    Build lib/knx from this src directory instead, e.g. a copy carrying a proposed change. Overrides -KnxRef.
    Objects are reused by file time: after copying with preserved times, add -Rebuild.

.PARAMETER Rebuild
    Compile every source again.

.PARAMETER CaseTimeoutSec
    A case still running after this many seconds is killed and fails. Default 120.

.PARAMETER AllowSanitizer
    Sanitizer reports are printed but do not fail the run. For triage only.

.EXAMPLE
    pwsh runners/Invoke-HostStackTests.ps1
    Builds against the working tree and runs every case.

.EXAMPLE
    pwsh runners/Invoke-HostStackTests.ps1 -KnxRef HEAD -TPUartRef HEAD
    The same cases against the committed stack.

.NOTES
    Needs a C++17 compiler with AddressSanitizer (Apple clang via xcrun, or clang/gcc on Linux).
    The build flags follow the TP products: lib/OGM-Common/platformio.base.ini and platformio.rp2040.ini.
#>

[CmdletBinding()]
param(
    [string] $Filter = '',
    [string] $KnxRef = '',
    [string] $TPUartRef = '',
    [string] $KnxSrcDir = '',
    [switch] $Rebuild,
    [int] $CaseTimeoutSec = 120,
    [switch] $AllowSanitizer
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$testDir = Split-Path -Parent $here
$repo    = Split-Path -Parent (Split-Path -Parent $testDir)
$hostDir = Join-Path $testDir 'host/stack'
$tmp     = [System.IO.Path]::GetTempPath()

function Get-SourceTree {
    <#
    .SYNOPSIS
        The src directory of a library, from the working tree or extracted from a git revision.
    #>
    param([string]$Lib, [string]$Ref)
    $libDir = Join-Path $repo "lib/$Lib"
    if (-not $Ref) { return (Resolve-Path (Join-Path $libDir 'src')).Path }
    $sha = (& git -C $libDir rev-parse --short $Ref).Trim()
    if ($LASTEXITCODE -ne 0) { throw "git revision '$Ref' not found in lib/$Lib" }
    $dest = Join-Path $tmp "openknx-hoststack-src-$Lib-$sha"
    if (-not (Test-Path (Join-Path $dest 'src'))) {
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        $archive = Join-Path $dest 'src.tar'
        & git -C $libDir archive --format=tar -o $archive $sha src
        if ($LASTEXITCODE -ne 0) { throw "git archive failed for lib/$Lib $sha" }
        & tar -xf $archive -C $dest
        Remove-Item $archive
    }
    return (Join-Path $dest 'src')
}

if ($KnxSrcDir) {
    if (-not (Test-Path (Join-Path $KnxSrcDir 'knx'))) { throw "-KnxSrcDir '$KnxSrcDir' has no knx directory" }
    $knxSrc = (Resolve-Path $KnxSrcDir).Path
    $knxLabel = $knxSrc
}
else {
    $knxSrc = Get-SourceTree -Lib 'knx' -Ref $KnxRef
    $knxLabel = if ($KnxRef) { $KnxRef } else { 'working tree' }
}
$tpSrc  = Get-SourceTree -Lib 'TPUart' -Ref $TPUartRef
$label  = "knx=$knxLabel, TPUart=$(if ($TPUartRef) { $TPUartRef } else { 'working tree' })"

# One build directory per source combination, outside the repository.
$key = [BitConverter]::ToString([System.Security.Cryptography.SHA1]::Create().ComputeHash(
           [System.Text.Encoding]::UTF8.GetBytes("$knxSrc|$tpSrc|$hostDir"))).Replace('-', '').Substring(0, 12)
$build = Join-Path $tmp "openknx-hoststack-$key"
$objDir = Join-Path $build 'obj'
New-Item -ItemType Directory -Force -Path $objDir | Out-Null
$bin = Join-Path $build 'host-stack'

# The flags of the TP products (plain 07B0 device, NCN5120 family, flash callbacks).
$defines = @('-DMASK_VERSION=0x07B0', '-DNCN5120', '-DKNX_FLASH_CALLBACK', '-DSMALL_GROUPOBJECT', '-DUSE_BINSEARCH',
             '-DKNX_ACTIVITYCALLBACK', '-DKNX_FLASH_SIZE=0x8000')
$flags = @('-std=c++17', '-g', '-O1', '-fsanitize=address,undefined', '-fno-omit-frame-pointer', '-include', 'arpa/inet.h',
           "-I$hostDir/shim", "-I$hostDir", "-I$knxSrc", "-I$knxSrc/knx", "-I$tpSrc") + $defines

$sources = @()
$sources += Get-ChildItem (Join-Path $knxSrc 'knx') -Filter '*.cpp' |
            Where-Object { @('bau07B0_ip.cpp', 'bau091A.cpp', 'bau2920.cpp', 'bau57B0.cpp') -notcontains $_.Name } |
            ForEach-Object { $_.FullName }
foreach ($f in @('DataLinkLayer', 'Receiver', 'RepetitionFilter', 'RingBuffer', 'SearchBuffer', 'Statistics', 'SystemState', 'Transmitter')) {
    $sources += (Join-Path $tpSrc "TPUart/$f.cpp")
}
$sources += Get-ChildItem $hostDir -Filter '*.cpp' | ForEach-Object { $_.FullName }

$onMac = (Get-Variable -Name IsMacOS -ErrorAction SilentlyContinue) -and $IsMacOS
$compiler = @('c++')
$savedDevDir = $env:DEVELOPER_DIR
try {
    if ($onMac) {
        if (Test-Path '/Applications/Xcode.app/Contents/Developer') { $env:DEVELOPER_DIR = '/Applications/Xcode.app/Contents/Developer' }
        $sdk = & xcrun --show-sdk-path
        if (-not $sdk) { throw 'xcrun found no SDK' }
        $compiler = @('xcrun', 'clang++', '-isysroot', $sdk.Trim())
    }

    # A header change recompiles everything: the stack's headers carry inline code and layouts.
    $newestHeader = (@(Get-ChildItem -Recurse -File -Include '*.h' -Path $hostDir, (Join-Path $knxSrc 'knx'), (Join-Path $tpSrc 'TPUart')) |
                     Measure-Object -Property LastWriteTimeUtc -Maximum).Maximum
    Write-Host "  building host stack ($label) ..." -ForegroundColor DarkGray
    $objects = @()
    foreach ($src in $sources) {
        $hash = [BitConverter]::ToString([System.Security.Cryptography.SHA1]::Create().ComputeHash(
                    [System.Text.Encoding]::UTF8.GetBytes($src))).Replace('-', '').Substring(0, 16)
        $obj = Join-Path $objDir "$hash.o"
        $objects += $obj
        $stale = $Rebuild -or -not (Test-Path $obj)
        if (-not $stale) {
            $t = (Get-Item $obj).LastWriteTimeUtc
            $stale = ((Get-Item $src).LastWriteTimeUtc -gt $t) -or ($newestHeader -gt $t)
        }
        if ($stale) {
            $out = & $compiler[0] @($compiler[1..($compiler.Count - 1)]) @flags '-c' $src '-o' $obj 2>&1
            if ($LASTEXITCODE -ne 0) {
                $out | Where-Object { "$_" -match 'error' } | Select-Object -First 8 | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
                throw "compile failed: $src"
            }
        }
    }
    $out = & $compiler[0] @($compiler[1..($compiler.Count - 1)]) @flags '-o' $bin @objects 2>&1
    if ($LASTEXITCODE -ne 0) {
        $out | Select-Object -Last 10 | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        throw 'link failed'
    }
}
finally { $env:DEVELOPER_DIR = $savedDevDir }

# ---- run: one process per case ----------------------------------------------------------------------

$env:ASAN_OPTIONS = 'detect_leaks=0'
$ids = @(& $bin '--list' | Where-Object { $_ -and $_.StartsWith($Filter) })
$pass = 0; $fail = 0; $skip = 0
$sanitizer = @{}
Write-Host ''
foreach ($id in $ids) {
    # A case that hangs (an endless loop is a finding too) is killed after the timeout and fails.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $bin
    $psi.Arguments = "=$id"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    $timedOut = -not $proc.WaitForExit($CaseTimeoutSec * 1000)
    if ($timedOut) { try { $proc.Kill() } catch { } ; [void]$proc.WaitForExit(5000) }
    $lines = @(($stdout.Result + "`n" + $stderr.Result) -split "`r?`n")
    if ($timedOut) {
        $fail++
        Write-Host ("  FAIL   {0,-10} did not finish within {1} s (killed)" -f $id, $CaseTimeoutSec) -ForegroundColor Red
        continue
    }
    $result = $lines | Where-Object { $_.StartsWith("$id`t") } | Select-Object -First 1
    foreach ($l in $lines) {
        if ($l -match '([\w./-]+\.(?:cpp|h):\d+:\d+): runtime error: (.*)$') {
            $loc = (Split-Path -Leaf ($Matches[1] -replace ':\d+$', '')) + ' ' + $Matches[2]
            if (-not $sanitizer.ContainsKey($loc)) { $sanitizer[$loc] = @() }
            if ($sanitizer[$loc] -notcontains $id) { $sanitizer[$loc] += $id }
        }
        if ($l -match 'ERROR: AddressSanitizer: (\S+)') {
            $kind = $Matches[1] # read before the next -match overwrites $Matches
            $frame = (($lines | Where-Object { $_ -match '^\s+#[01] ' } | Select-Object -First 2) | ForEach-Object { ($_ -replace '^\s+#\d+ 0x[0-9a-f]+ in ', '').Trim() }) -join ' <- '
            $loc = "AddressSanitizer $kind in $frame"
            if (-not $sanitizer.ContainsKey($loc)) { $sanitizer[$loc] = @() }
            if ($sanitizer[$loc] -notcontains $id) { $sanitizer[$loc] += $id }
        }
    }
    if (-not $result) {
        $fail++
        Write-Host ("  FAIL   {0,-10} crashed (exit {1})" -f $id, $proc.ExitCode) -ForegroundColor Red
        continue
    }
    $c = $result -split "`t"
    $caseResult = $c[1]; $title = $c[2]; $detail = if ($c.Count -ge 4) { $c[3] } else { '' }
    switch ($caseResult) {
        'PASS' { $pass++; Write-Host ("  PASS   {0,-10} {1}" -f $id, $title) -ForegroundColor DarkGreen }
        'SKIP' { $skip++; Write-Host ("  SKIP   {0,-10} {1}  -- {2}" -f $id, $title, $detail) -ForegroundColor Yellow }
        default { $fail++; Write-Host ("  FAIL   {0,-10} {1}  -- {2}" -f $id, $title, $detail) -ForegroundColor Red }
    }
}

if ($sanitizer.Count -gt 0) {
    Write-Host ''
    Write-Host '  Sanitizer reports (each one is a finding of its own):' -ForegroundColor Red
    foreach ($k in ($sanitizer.Keys | Sort-Object)) {
        Write-Host ("    {0}`n      in: {1}" -f $k, ($sanitizer[$k] -join ', ')) -ForegroundColor Red
    }
}

# A case that asserts nothing about the defect it triggered still ends PASS, so a sanitizer report
# decides the run on its own. Printing it and exiting 0 reported undefined behaviour as a green run.
$red = $fail -gt 0 -or ($sanitizer.Count -gt 0 -and -not $AllowSanitizer)
Write-Host ''
Write-Host ("  {0}: {1} passed, {2} failed, {3} skipped, {4} sanitizer location(s)" -f $label, $pass, $fail, $skip, $sanitizer.Count) -ForegroundColor $(if ($red) { 'Red' } else { 'Green' })
if ($sanitizer.Count -gt 0 -and $AllowSanitizer) {
    Write-Host '  -AllowSanitizer: the sanitizer reports above do not fail this run' -ForegroundColor Yellow
}
if ($red) { exit 1 } else { exit 0 }
