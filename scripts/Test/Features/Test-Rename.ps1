#!/usr/bin/env pwsh
# Open ■
# ┬────┴  Test-Rename
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Features/Test-Rename.ps1

<#
.SYNOPSIS
    Proves the three rename fixes on real hardware: the frame guard, the drive guard and
    the length guard.

.DESCRIPTION
    Two of the three fixes cannot be reached through `oknx mv` at all, because the client
    always builds a well-formed frame. They are only reachable by putting the bytes on the
    bus by hand - which is what this script does: one A_FunctionProperty_Command (APCI
    0x2C7) on object 159, property 2, connectionless, exactly as the client sends it, and
    the answer read out of the FunctionPropertyState_Response (APCI 0x2C9).

    What each case establishes:

      R-1  a well-formed rename still works                        -> 0x00, file moved
      R-2  a frame whose separator is the LAST byte is refused      -> 0x45, nothing moved
           Before the fix the second name started one byte past the payload and strlen()
           walked whatever followed it in the buffer - and THAT path was renamed to.
      R-3  a second name without its own terminator is refused      -> 0x45, nothing moved
      R-4  a rename across drives is refused                        -> 0x45, source intact
           Before the fix it renamed on the SOURCE drive under the stripped name, hitting
           a file the caller never asked for. R-4b proves the legitimate form still works.
      R-5  a new name WITHOUT a drive prefix still means same drive -> 0x00, file moved

    R-4 and R-5 need a second drive on the device (sd/ or efc/) and report NOT APPLICABLE
    without one. Everything else runs against LittleFS.

    The device is left as it was found: every file this script creates is removed again,
    including after a failed case.

.PARAMETER Ip
    IP address of the interface the device is reached through.

.PARAMETER Pa
    Individual address of the device under test, e.g. 1.1.10.

.PARAMETER Drive
    Second drive to use for R-4/R-5: sd or efc. Empty = probe for one, and skip if none.

.PARAMETER OknxPath
    The oknx binary, used only to place the test file. Empty = looked up on PATH and in the
    usual build folder.

.PARAMETER Password
    Password when the device is built with OPENKNX_FTC_SECURITY. Without it a protected
    device refuses every write and the cases report their reason instead of a false FAIL.

.EXAMPLE
    ./Test-Rename.ps1 -Ip 11.11.0.126 -Pa 1.1.10
.EXAMPLE
    ./Test-Rename.ps1 -Ip 11.11.0.126 -Pa 1.1.10 -Drive sd -Password 'Test!99'

.NOTES
    The four session helpers below duplicate what Suites/D-Device.Tests.ps1 keeps local to
    itself. They belong in lib/KnxTest.psm1; they are repeated here so this script cannot
    destabilise the conformance suite before a KNXA run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Ip,
    [Parameter(Mandatory)][string]$Pa,
    [ValidateSet('', 'sd', 'efc')][string]$Drive = '',
    [string]$OknxPath = '',
    [string]$Password = '',
    [int]$Port = 3671
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $here 'lib/KnxTest.psm1') -Force

$K = Get-KnxConstants

# --- the wire vocabulary this test needs, not yet in the module --------------------------
$APCI_FUNC_PROP_CMD  = 0x2C7   # A_FunctionProperty_Command
$APCI_FUNC_PROP_RESP = 0x2C9   # A_FunctionPropertyState_Response
$FTM_OBJECT          = 159     # the file-transfer command object
$FTM_CMD_RENAME      = 2       # FtmCommands::Rename
$FTM_CMD_EXISTS      = 1       # FtmCommands::Exists
$FTM_CMD_DELETE      = 42      # FtmCommands::FileDelete

# ─── minimal session over one tunnel ───────────────────────────────────────────────────

function New-RenameTpdu {
    <#
    .SYNOPSIS
        One connectionless A_FunctionProperty_Command TPDU.
    .DESCRIPTION
        Connectionless on purpose: that is what the client does. buildFunctionPropertyCommand
        leaves the transport control field at zero, so the device answers a T_Data_Individual
        without any acknowledge dance - one request, one response.
    #>
    param([Parameter(Mandatory)][int]$Apci, [byte[]]$Data = @())
    $head = [byte[]]@( ((($Apci -shr 8) -band 0x03) -band 0xFF), ($Apci -band 0xFF) )
    if ($null -eq $Data -or $Data.Length -eq 0) { return , $head }
    return , ([byte[]]($head + $Data))
}

function Invoke-FtmCommand {
    <#
    .SYNOPSIS
        Sends one file-transfer command and returns its result byte.
    .DESCRIPTION
        Returns Answered/Result/Payload. Result -1 means the device never answered, which
        for a MALFORMED frame is itself a finding: the guard must refuse it with a code,
        not swallow it silently.
    #>
    param(
        [Parameter(Mandatory)]$Conn,
        [Parameter(Mandatory)][int]$Dst,
        [Parameter(Mandatory)][int]$Command,
        [byte[]]$Payload = @(),
        [int]$TimeoutMs = 4000
    )
    $data = [byte[]]@($FTM_OBJECT, $Command) + $Payload
    $tpdu = New-RenameTpdu -Apci $APCI_FUNC_PROP_CMD -Data $data
    $cemi = New-CemiLData -MessageCode $K.Cemi.L_DATA_REQ -Destination $Dst -Tpdu $tpdu -Priority 0
    $sent = Send-KnxTunnelCemi -Connection $Conn -Cemi $cemi -TimeoutMs $TimeoutMs
    if (-not $sent.Acked) {
        return [pscustomobject]@{ Answered = $false; Result = -1; Payload = @(); Reason = 'the interface did not acknowledge the request' }
    }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $left = [int]([Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds))
        $in = Receive-KnxTunnelCemi -Connection $Conn -TimeoutMs $left
        if ($null -eq $in) { break }
        $ld = Read-CemiLData -Cemi $in.Cemi
        if ($null -eq $ld) { continue }
        if ($ld.MessageCode -ne $K.Cemi.L_DATA_IND) { continue }
        if ($ld.Source -ne $Dst) { continue }
        $t = $ld.Tpdu
        if ($null -eq $t -or $t.Length -lt 5) { continue }
        $apci = ((([int]$t[0] -shl 8) -bor [int]$t[1]) -band 0x3FF)
        if ($apci -ne $APCI_FUNC_PROP_RESP) { continue }
        if ([int]$t[2] -ne $FTM_OBJECT) { continue }
        $rest = @()
        if ($t.Length -gt 5) { $rest = $t[5..($t.Length - 1)] }
        return [pscustomobject]@{ Answered = $true; Result = [int]$t[4]; Payload = $rest; Reason = '' }
    }
    return [pscustomobject]@{ Answered = $false; Result = -1; Payload = @(); Reason = 'no FunctionPropertyState_Response within the window' }
}

function Test-RemoteExists {
    <# .SYNOPSIS True when the device reports the path as present. #>
    param([Parameter(Mandatory)]$Conn, [Parameter(Mandatory)][int]$Dst, [Parameter(Mandatory)][string]$Path)
    $bytes = [byte[]][System.Text.Encoding]::ASCII.GetBytes($Path) + [byte[]]@(0)
    $r = Invoke-FtmCommand -Conn $Conn -Dst $Dst -Command $FTM_CMD_EXISTS -Payload $bytes
    if (-not $r.Answered) { return $false }
    # The server answers TWO octets (FileTransferModule.cpp cmdExists): [0] is the status of the
    # QUERY and is always 0x00, [1] carries the actual yes/no. Reading the status as the answer made
    # this function return $true for every path on earth - including ones that had just been refused,
    # which is where "stray target created" came from. Verified 2026-09-26 on 5.0.8: a listing showed
    # only src.bin while this said /rnbad.bin existed.
    if ($r.Result -ne 0x00) { return $false }
    return ($r.Payload.Count -ge 1 -and $r.Payload[0] -ne 0)
}

function Remove-RemoteFile {
    <# .SYNOPSIS Deletes a path, ignoring "was not there". #>
    param([Parameter(Mandatory)]$Conn, [Parameter(Mandatory)][int]$Dst, [Parameter(Mandatory)][string]$Path)
    $bytes = [byte[]][System.Text.Encoding]::ASCII.GetBytes($Path) + [byte[]]@(0)
    [void](Invoke-FtmCommand -Conn $Conn -Dst $Dst -Command $FTM_CMD_DELETE -Payload $bytes)
}

function New-RenamePayload {
    <#
    .SYNOPSIS
        Builds the rename payload in one of four deliberately different shapes.
    .DESCRIPTION
        Shape is the whole point of this test:
          Good      "old\0new\0"  - what the client sends
          SepAtEnd  "old\0"       - the separator IS the last byte; the second name would
                                    start past the payload
          NoEnd     "old\0new"    - a second name without its own terminator
          NoSep     "old"         - no separator at all (already refused before the fix)
    #>
    param([Parameter(Mandatory)][string]$Old, [string]$New = '',
          [ValidateSet('Good', 'SepAtEnd', 'NoEnd', 'NoSep')][string]$Shape = 'Good')
    $enc = [System.Text.Encoding]::ASCII
    $o = [byte[]]$enc.GetBytes($Old)
    $n = [byte[]]$enc.GetBytes($New)
    switch ($Shape) {
        'Good'     { return [byte[]]($o + [byte[]]@(0) + $n + [byte[]]@(0)) }
        'SepAtEnd' { return [byte[]]($o + [byte[]]@(0)) }
        'NoEnd'    { return [byte[]]($o + [byte[]]@(0) + $n) }
        'NoSep'    { return [byte[]]$o }
    }
}

function Find-Oknx {
    <# .SYNOPSIS Locates the oknx binary; empty when there is none. #>
    param([string]$Explicit)
    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return (Resolve-Path -LiteralPath $Explicit).Path }
        return ''
    }
    $cmd = Get-Command 'oknx' -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $exe = 'oknx'
    # $IsWindows does not exist in PowerShell 5.1 - $env:OS is set on every Windows host.
    if ($env:OS -eq 'Windows_NT') { $exe = 'oknx.exe' }
    $guess = Join-Path $here "../../../OFM-FileTransferModule/oknx/.pio/build"
    if (Test-Path -LiteralPath $guess) {
        $hit = Get-ChildItem -LiteralPath $guess -Recurse -Filter $exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return ''
}

# ─── run ───────────────────────────────────────────────────────────────────────────────

$dst = ConvertTo-KnxPa -Address $Pa
$results = New-Object System.Collections.ArrayList

function Add-Case {
    param([string]$Id, [string]$Title, [string]$Result, [string]$Detail)
    [void]$results.Add([pscustomobject]@{ Id = $Id; Title = $Title; Result = $Result; Detail = $Detail })
    $col = 'DarkGray'
    if ($Result -eq 'PASS') { $col = 'Green' }
    if ($Result -eq 'FAIL') { $col = 'Red' }
    Write-Host ("  {0,-6} {1,-5} {2}" -f $Id, $Result, $Title) -ForegroundColor $col
    if ($Detail) { Write-Host ("         {0}" -f $Detail) -ForegroundColor DarkGray }
}

. (Join-Path $PSScriptRoot '../lib/KnxLogo.ps1')
Write-KnxLogo -Title 'Test-Rename'
Write-Host ("  {0} · {1}" -f $Ip, $Pa) -ForegroundColor DarkGray
Write-Host ''

$conn = Open-KnxConnection -Ip $Ip -Port $Port
if (-not $conn.Ok) {
    Write-Host ("  no tunnel: {0}" -f $conn.StatusName) -ForegroundColor Red
    # 3 = the rig is not ready; 2 would read as a failed library self-test in Invoke-AllTests.
    exit 3
}

$base = '/rntest.bin'
$moved = '/rnmoved.bin'
$created = New-Object System.Collections.ArrayList

try {
    # --- place the test file -----------------------------------------------------------
    $oknx = Find-Oknx -Explicit $OknxPath
    # Without the tool no case can be seeded; running on would report guard results that
    # were never exercised, so stop here and name the reason.
    if (-not $oknx) {
        Write-Host '  oknx not found - it places the test file, so no case can run' -ForegroundColor Red
        Write-Host '  ( -OknxPath <binary>   or put oknx on the PATH )' -ForegroundColor DarkGray
        exit 3
    }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'rntest.bin'
    [System.IO.File]::WriteAllBytes($tmp, [byte[]](1..64))
    # NOT $args - that is an automatic variable; assigning it inside a script is a trap.
    if ($Password) { & $oknx @('--ip', $Ip, $Pa, 'login', $Password) | Out-Null }
    $oknxArgs = @('--ip', $Ip, $Pa, 'send', $tmp, $base, '-q')
    & $oknx @oknxArgs | Out-Null
    [void](Wait-KnxTunnel -Connection $conn -Ms 400)
    $seeded = Test-RemoteExists -Conn $conn -Dst $dst -Path $base
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    if (-not $seeded) {
        Write-Host '  cannot place the test file - is the device write-protected?' -ForegroundColor Yellow
        Write-Host '  ( -Password <pw> )' -ForegroundColor DarkGray
        exit 3
    }
    [void]$created.Add($base)

    # --- R-1  a well-formed rename still works ------------------------------------------
    $r = Invoke-FtmCommand -Conn $conn -Dst $dst -Command $FTM_CMD_RENAME `
                           -Payload (New-RenamePayload -Old $base -New $moved -Shape Good)
    $ok = ($r.Answered -and $r.Result -eq 0x00 -and (Test-RemoteExists -Conn $conn -Dst $dst -Path $moved))
    $v = 'FAIL'; if ($ok) { $v = 'PASS' }
    Add-Case 'R-1' 'a well-formed rename still works' $v ("answer 0x{0:X2} · {1} present: {2}" -f $r.Result, $moved, (Test-RemoteExists -Conn $conn -Dst $dst -Path $moved))
    if ($ok) { [void]$created.Remove($base); [void]$created.Add($moved) }

    $subject = $moved
    if (-not $ok) { $subject = $base }

    # --- R-2  separator is the last byte ------------------------------------------------
    $r = Invoke-FtmCommand -Conn $conn -Dst $dst -Command $FTM_CMD_RENAME `
                           -Payload (New-RenamePayload -Old $subject -Shape SepAtEnd)
    $still = Test-RemoteExists -Conn $conn -Dst $dst -Path $subject
    $ok = ($r.Answered -and $r.Result -eq 0x45 -and $still)
    $v = 'FAIL'; if ($ok) { $v = 'PASS' }
    Add-Case 'R-2' 'a frame ending on the separator is refused' $v ("answer 0x{0:X2} · source still there: {1}" -f $r.Result, $still)

    # --- R-3  second name without a terminator ------------------------------------------
    $r = Invoke-FtmCommand -Conn $conn -Dst $dst -Command $FTM_CMD_RENAME `
                           -Payload (New-RenamePayload -Old $subject -New '/rnbad.bin' -Shape NoEnd)
    $still = Test-RemoteExists -Conn $conn -Dst $dst -Path $subject
    $stray = Test-RemoteExists -Conn $conn -Dst $dst -Path '/rnbad.bin'
    $ok = ($r.Answered -and $r.Result -eq 0x45 -and $still -and -not $stray)
    $v = 'FAIL'; if ($ok) { $v = 'PASS' }
    Add-Case 'R-3' 'a second name without a terminator is refused' $v ("answer 0x{0:X2} · source still there: {1} · stray target created: {2}" -f $r.Result, $still, $stray)
    if ($stray) { [void]$created.Add('/rnbad.bin') }

    # --- R-4 / R-5  need a second drive --------------------------------------------------
    $second = $Drive
    if (-not $second) {
        foreach ($d in @('sd', 'efc')) {
            if (Test-RemoteExists -Conn $conn -Dst $dst -Path "$d/") { $second = $d; break }
        }
    }
    if (-not $second) {
        Add-Case 'R-4' 'a rename across drives is refused' 'N/A' 'the device has no second drive (sd/ or efc/)'
        Add-Case 'R-5' 'a new name without a prefix stays on the drive' 'N/A' 'the device has no second drive (sd/ or efc/)'
    }
    else {
        $other = 'efc'
        if ($second -eq 'efc') { $other = 'sd' }
        $onDrive = "$second/rntest.bin"
        $r = Invoke-FtmCommand -Conn $conn -Dst $dst -Command $FTM_CMD_RENAME `
                               -Payload (New-RenamePayload -Old $subject -New $onDrive -Shape Good)
        $crossed = ($r.Answered -and $r.Result -eq 0x00)
        if ($crossed) {
            Add-Case 'R-4' 'a rename across drives is refused' 'FAIL' `
                ("answer 0x{0:X2} - the device accepted a cross-drive rename; the fix is not on this firmware" -f $r.Result)
            [void]$created.Add($onDrive)
        }
        else {
            $still = Test-RemoteExists -Conn $conn -Dst $dst -Path $subject
            $ok = ($r.Answered -and $r.Result -eq 0x45 -and $still)
            $v = 'FAIL'; if ($ok) { $v = 'PASS' }
            Add-Case 'R-4' 'a rename across drives is refused' $v ("answer 0x{0:X2} · source untouched: {1}" -f $r.Result, $still)
        }

        # R-5: a new name WITHOUT a prefix must still mean the same drive. Needs a file on it.
        $srcOnDrive = "$second/rn5.bin"
        $dstOnDrive = "$second/rn5moved.bin"
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'rn5.bin'
        [System.IO.File]::WriteAllBytes($tmp, [byte[]](1..32))
        & $oknx @('--ip', $Ip, $Pa, 'send', $tmp, $srcOnDrive, '-q') | Out-Null
        [void](Wait-KnxTunnel -Connection $conn -Ms 400)
        $have = Test-RemoteExists -Conn $conn -Dst $dst -Path $srcOnDrive
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
        if (-not $have) {
            Add-Case 'R-5' 'a new name without a prefix stays on the drive' 'N/A' "could not place a file on $second/"
        }
        else {
            [void]$created.Add($srcOnDrive)
            $r = Invoke-FtmCommand -Conn $conn -Dst $dst -Command $FTM_CMD_RENAME `
                                   -Payload (New-RenamePayload -Old $srcOnDrive -New '/rn5moved.bin' -Shape Good)
            $landed = Test-RemoteExists -Conn $conn -Dst $dst -Path $dstOnDrive
            $ok = ($r.Answered -and $r.Result -eq 0x00 -and $landed)
            $v = 'FAIL'; if ($ok) { $v = 'PASS' }
            Add-Case 'R-5' 'a new name without a prefix stays on the drive' $v ("answer 0x{0:X2} · landed on {1}: {2}" -f $r.Result, $second, $landed)
            if ($landed) { [void]$created.Remove($srcOnDrive); [void]$created.Add($dstOnDrive) }
        }
    }
}
finally {
    # Leave the device as it was found - also after a failed case.
    foreach ($p in @($created)) { Remove-RemoteFile -Conn $conn -Dst $dst -Path $p }
    [void](Close-KnxConnection -Connection $conn)
}

$pass = @($results | Where-Object { $_.Result -eq 'PASS' }).Count
$fail = @($results | Where-Object { $_.Result -eq 'FAIL' }).Count
$na = @($results | Where-Object { $_.Result -eq 'N/A' }).Count
Write-Host ''
Write-Host ("  PASS {0}   FAIL {1}   N/A {2}" -f $pass, $fail, $na) -ForegroundColor $(if ($fail -gt 0) { 'Red' } else { 'Green' })
Write-Host ''
if ($fail -gt 0) { exit 1 }
exit 0
