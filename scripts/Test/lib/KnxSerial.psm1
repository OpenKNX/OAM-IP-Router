#!/usr/bin/env pwsh
<#
Open ■
┬────┴  KnxSerial
■ KNX   2026 OpenKNX - Erkan Çolak

FILEPATH: scripts/Test/lib/KnxSerial.psm1

.SYNOPSIS
    The serial side of the test suite: find the ports, find out what is on them, and talk
    to a device console without every script reinventing it.

.DESCRIPTION
    Four scripts under scripts/Test opened a serial port by hand before this module
    existed - Test-BcuMarker, Test-Longrun, Test-Soak and the repro tools - and each
    carried its own copy of "open, wait, send, drain, hope". They drifted: different
    baud handling, different settle times, and only one of them worked on Windows.

    The port scan is the one from the OpenKNX firmware uploader
    (OGM-Common scripts/setup/reusable/data/Upload-Firmware-Generic.ps1, ScanPicoPorts and
    ScanEsp32Ports), so a board is found here exactly as the uploader finds it, and the
    device labels come from the same console command with the same field names. What the
    uploader shows you before it flashes, the test suite now shows you before it tests.

    Import it next to KnxTest.psm1; it depends on nothing else:

        Import-Module (Join-Path $here 'lib/KnxSerial.psm1') -Force

    Typical use:

        Get-KnxSerialDevices -Probe            # what is plugged in, and what it is
        $s = Open-KnxSerial -Port /dev/cu.usbmodem84101
        Invoke-KnxSerialCommand -Session $s -Command 'bcu'
        Close-KnxSerial -Session $s

.NOTES
    Opening a port asserts DTR. On a board behind a CP210x or CH34x bridge that can reset
    the microcontroller. Never probe while a measurement is running on the device - the
    reset is silent and the run is lost.
#>

Set-StrictMode -Version Latest

function Get-KnxSerialPlatform {
    <#
    .SYNOPSIS
        Returns 'Windows', 'macOS' or 'Linux', on every PowerShell this suite runs on.
    .DESCRIPTION
        $IsWindows, $IsMacOS and $IsLinux exist from PowerShell 6 on. Windows PowerShell 5.1
        does not define them at all, and under Set-StrictMode reading an undefined variable
        does not yield $false - it throws. A module that branches on them directly therefore
        dies on the one platform this suite is explicitly required to run on.

        So they are looked up rather than read. 5.1 exists only on Windows, which makes the
        fallback correct rather than a guess.
    #>
    $v = Get-Variable -Name 'IsMacOS' -ErrorAction SilentlyContinue
    if ($null -ne $v -and $v.Value) { return 'macOS' }
    $v = Get-Variable -Name 'IsLinux' -ErrorAction SilentlyContinue
    if ($null -ne $v -and $v.Value) { return 'Linux' }
    return 'Windows'
}

function Get-KnxSerialCandidates {
    <#
    .SYNOPSIS
        Lists the serial ports that could carry a device, per operating system.
    .DESCRIPTION
        Same scan as the OpenKNX firmware uploader (OGM-Common
        scripts/setup/reusable/data/Upload-Firmware-Generic.ps1, ScanPicoPorts and
        ScanEsp32Ports) so both tools see the same machine the same way. Enumerating
        /dev/cu.* works on macOS and nowhere else; on Windows the ports are COM1..COMn and
        the USB vendor id is what separates a board from a Bluetooth modem.

        Ports that are never a device - the Bluetooth serial profile, the Apple debug
        console - are dropped, because offering them makes the user pick from noise.
    #>
    $ports = @()
    $platform = Get-KnxSerialPlatform
    if ($platform -eq 'macOS') {
        $ports = @(Get-ChildItem /dev/cu.usbmodem*, /dev/cu.wchusbserial*, /dev/cu.usbserial-*, /dev/cu.SLAB_USBtoUART* `
                    -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    elseif ($platform -eq 'Linux') {
        $ports = @(Get-ChildItem /dev/ttyACM*, /dev/ttyUSB* -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    else {
        try {
            # 2E8A = Raspberry Pi (RP2040/RP2350), 303A = Espressif native USB,
            # 1A86 = CH34x, 10C4 = CP210x, 0403 = FTDI - the bridges these boards use.
            foreach ($dev in (Get-PnpDevice -Class Ports -ErrorAction Stop)) {
                if (-not $dev.Present) { continue }
                $isBoard = $dev.InstanceId -match 'USB\\VID_(2E8A|303A|1A86|10C4|0403)'
                if ($isBoard -and $dev.Name -match 'COM\d{1,3}') { $ports += $Matches[0] }
            }
        }
        catch {
            # Get-PnpDevice is absent on older Windows - no vendor filter, take them all.
            $ports = @([System.IO.Ports.SerialPort]::GetPortNames())
        }
    }
    if ($ports.Count -eq 0) { try { $ports = @([System.IO.Ports.SerialPort]::GetPortNames()) } catch { } }
    # No ", $ports" here. The comma idiom wraps the array in ANOTHER array, and a caller
    # writing @(Get-KnxSerialCandidates) then collects exactly one element - the whole array -
    # which printed a picker offering "[1] System.Object[]". Emitting the elements is what
    # every @() call site already expects.
    return @($ports | Where-Object { $_ -notmatch 'Bluetooth|debug-console' } | Sort-Object -Unique)
}

function Read-KnxSerialIdentity {
    <#
    .SYNOPSIS
        Asks one serial port who it is, using the device console's own info command.
    .DESCRIPTION
        Opens the port, sends "i" and parses the OpenKNX information block - the same
        exchange and the same field names the firmware uploader uses, so a device is
        labelled identically in both tools.

        Returns $null when the port does not answer, which is not an error: a port can be
        a foreign device, or busy, or the firmware may not have a console.

        NOTE: opening a port asserts DTR. On a board behind a CP210x or CH34x that can
        reset the MCU. Do not probe while something is running on the device.
    #>
    param([Parameter(Mandatory)][string]$Port, [int]$TimeoutMs = 2500, [int]$Attempts = 2)
    # A console that is busy - finishing a command, printing a log burst - misses the first
    # "i" and looks dead. Measured on this rig: a port reported silent by one probe answered
    # cleanly seconds later, and the port was the device under test. One retry costs a second
    # and removes a false "no answer" that sends the user to the wrong port.
    for ($try = 1; $try -lt $Attempts; $try++) {
        $r = Read-KnxSerialIdentityOnce -Port $Port -TimeoutMs $TimeoutMs
        if ($null -ne $r) { return $r }
        Start-Sleep -Milliseconds 300
    }
    return (Read-KnxSerialIdentityOnce -Port $Port -TimeoutMs $TimeoutMs)
}

function Read-KnxSerialIdentityOnce {
    <#
    .SYNOPSIS
        One attempt at asking a port who it is. Use Read-KnxSerialIdentity, which retries.
    #>
    param([Parameter(Mandatory)][string]$Port, [int]$TimeoutMs = 2500)
    $sp = $null
    try {
        $sp = New-Object System.IO.Ports.SerialPort $Port, 115200, 'None', 8, 1
        $sp.WriteTimeout = 1500
        $sp.DtrEnable = $true
        $sp.Encoding = [System.Text.Encoding]::UTF8
        $sp.Open()
        Start-Sleep -Milliseconds 400
        $sp.Write("`r`n")
        Start-Sleep -Milliseconds 400
        $sp.DiscardInBuffer()
        $sp.WriteLine('i')
        $text = ''
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        while ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 150
            if ($sp.BytesToRead -gt 0) { $text += $sp.ReadExisting() }
            elseif ($text.Length -gt 20) { Start-Sleep -Milliseconds 250; $text += $sp.ReadExisting(); break }
        }
        $sp.Close()
        if (-not $text) { return $null }

        # The console prints "0d 01:23:13: Device|" style lines: strip the timestamp prefix
        # and the trailing pipe before looking for "Key: value".
        $text = $text -replace '\x1B\[[0-9;]*[A-Za-z]', ''
        $fields = @{}
        foreach ($raw in ([regex]::Replace($text, "`r`n|`r|`n", "`n") -split "`n")) {
            $line = $raw
            $i = $line.IndexOf(': ')
            if ($i -ge 0) { $line = $line.Substring($i + 2) }
            $pipe = $line.IndexOf('|')
            if ($pipe -ge 0) { $line = $line.Substring(0, $pipe) }
            $line = $line.Trim()
            $kv = $line.IndexOf(':')
            if ($kv -le 0) { continue }
            $k = $line.Substring(0, $kv).Trim()
            $v = $line.Substring($kv + 1).Trim()
            if ($v -and -not $fields.ContainsKey($k)) { $fields[$k] = $v }
        }
        $name = if ($fields.ContainsKey('Name')) { $fields['Name'] } else { '' }
        $serial = if ($fields.ContainsKey('Serial number')) { $fields['Serial number'] } else { '' }
        $version = if ($fields.ContainsKey('Version')) { $fields['Version'] } else { '' }
        if (-not $name -and -not $serial) { return $null }
        return [pscustomobject]@{ Name = $name; Serial = $serial; Version = $version }
    }
    catch { return $null }
    finally {
        if ($null -ne $sp) { try { if ($sp.IsOpen) { $sp.Close() } ; $sp.Dispose() } catch { } }
    }
}

function Get-KnxSerialDevices {
    <#
    .SYNOPSIS
        Lists the serial ports with, where it can be read, the device behind each one.
    .PARAMETER Probe
        Ask each port who it is. Without this only the port names are returned - useful
        when something is running on a device and a DTR toggle must be avoided.
    #>
    param([switch]$Probe, [int]$TimeoutMs = 2500, [switch]$ShowProgress)
    $out = @()
    $ports = @(Get-KnxSerialCandidates)
    # Probing is one port after another and each one waits for an answer, so a quiet machine
    # takes ten seconds or more. Without a word on screen that reads as a hang, and the
    # natural reaction is to press a key or kill it - both of which lose the run.
    if ($ShowProgress) {
        if ($ports.Count -eq 0) { Write-Host '    no serial port found on this machine' -ForegroundColor Yellow }
        elseif ($Probe) { Write-Host ("    {0} port(s) found - asking each one who it is, about {1:N0} s each:" -f $ports.Count, ($TimeoutMs / 1000)) -ForegroundColor DarkGray }
        else { Write-Host ("    {0} port(s) found:" -f $ports.Count) -ForegroundColor DarkGray }
    }
    foreach ($port in $ports) {
        if ($ShowProgress -and $Probe) { Write-Host ("      {0,-28} " -f $port) -NoNewline -ForegroundColor DarkGray }
        $id = $null
        if ($Probe) { $id = Read-KnxSerialIdentity -Port $port -TimeoutMs $TimeoutMs }
        $label = ''
        if ($null -ne $id) {
            $parts = @()
            if ($id.Name) { $parts += """$($id.Name)""" }
            if ($id.Version) { $parts += "v$($id.Version)" }
            if ($id.Serial) { $parts += "SN $($id.Serial)" }
            $label = ($parts -join '  ')
        }
        if ($ShowProgress -and $Probe) {
            if ($label) { Write-Host $label -ForegroundColor Green }
            else { Write-Host 'no answer' -ForegroundColor DarkGray }
        }
        $out += [pscustomobject]@{ Port = $port; Label = $label; Identity = $id }
    }
    return $out
}

function Test-KnxSerialNeedsDtr {
    <#
    .SYNOPSIS
        True when a port needs DTR asserted before the device will talk to it.
    .DESCRIPTION
        Two kinds of port look the same from the outside and want the opposite treatment.

        A board with NATIVE USB (RP2040, RP2350, ESP32-S3) presents a USB-CDC endpoint, and
        DTR is how the host says "a terminal is attached". Plenty of firmware sends nothing
        at all until it sees that. Without DTR such a device is silent and looks broken -
        which is exactly what a console check then reports.

        A board behind a USB-to-serial BRIDGE (CH340, CP210x, FTDI) has DTR and RTS wired to
        reset and boot pins, so asserting them can restart the device under test.

        The port name tells them apart on macOS and Linux; on Windows the vendor id does,
        and the caller can override when it knows better.
    #>
    param([Parameter(Mandatory)][string]$Port)
    # Bridges first - these must NOT get DTR.
    if ($Port -match '(?i)wchusbserial|usbserial|SLAB_USBtoUART|ttyUSB') { return $false }
    # Native USB CDC.
    if ($Port -match '(?i)usbmodem|ttyACM') { return $true }
    if ($Port -match '(?i)^COM\d+$') {
        # No name to go by on Windows: ask the device list for the vendor behind the port.
        try {
            foreach ($dev in (Get-PnpDevice -Class Ports -ErrorAction Stop)) {
                if ($dev.Present -and $dev.Name -match [regex]::Escape($Port)) {
                    return ($dev.InstanceId -match 'USB\\VID_(2E8A|303A)')
                }
            }
        }
        catch { }
    }
    return $true
}

# ─── Talking to a device console ────────────────────────────────────────────────

function Open-KnxSerial {
    <#
    .SYNOPSIS
        Opens a device console and returns a session, or $null with the reason on stderr.
    .DESCRIPTION
        One place that knows the settings a device console wants: 115200 8N1, DTR asserted
        so a USB-CDC firmware starts talking, and a settle pause before the first command.
        Scripts that skipped the settle read half a banner and matched nothing.
    #>
    param(
        [Parameter(Mandatory)][string]$Port,
        [int]$Baud = 115200,
        [int]$SettleMs = 500,
        [int]$ReadTimeoutMs = 1500
    )
    try {
        $sp = New-Object System.IO.Ports.SerialPort $Port, $Baud, 'None', 8, 1
        $sp.ReadTimeout = $ReadTimeoutMs
        $sp.WriteTimeout = 2000
        $sp.DtrEnable = $true
        $sp.Encoding = [System.Text.Encoding]::UTF8
        $sp.NewLine = "`r`n"
        $sp.Open()
        Start-Sleep -Milliseconds $SettleMs
        $sp.DiscardInBuffer()
        return [pscustomobject]@{ Port = $sp; Path = $Port; Baud = $Baud }
    }
    catch {
        Write-Host "  cannot open $Port : $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Close-KnxSerial {
    <#
    .SYNOPSIS
        Closes a session and releases the operating system handle.
    .DESCRIPTION
        Disposing matters: a port left open by a crashed run stays locked, and the next
        run reports "cannot open" for a device that is perfectly fine.
    #>
    param($Session)
    if ($null -eq $Session -or $null -eq $Session.Port) { return }
    try { if ($Session.Port.IsOpen) { $Session.Port.Close() } } catch { }
    try { $Session.Port.Dispose() } catch { }
}

function Read-KnxSerialDrain {
    <#
    .SYNOPSIS
        Reads everything the device has queued and returns it.
    .PARAMETER QuietMs
        Stop once nothing more arrives for this long. Default 400 ms.
    #>
    param([Parameter(Mandatory)]$Session, [int]$QuietMs = 400, [int]$MaxMs = 8000)
    $text = ''
    $deadline = [DateTime]::UtcNow.AddMilliseconds($MaxMs)
    $lastData = [DateTime]::UtcNow
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
        try {
            if ($Session.Port.BytesToRead -gt 0) {
                $text += $Session.Port.ReadExisting()
                $lastData = [DateTime]::UtcNow
            }
            elseif (([DateTime]::UtcNow - $lastData).TotalMilliseconds -ge $QuietMs) { break }
        }
        catch { break }
    }
    return $text
}

function Invoke-KnxSerialCommand {
    <#
    .SYNOPSIS
        Sends one console line and returns everything the device answered.
    .DESCRIPTION
        Discards whatever was pending first, so the answer cannot be confused with the
        tail of the previous command - the mistake that made a stale "bcu" output look
        like a fresh counter reading.
    .PARAMETER QuietMs
        The answer is complete when the device has been silent this long. A device that
        prints slowly needs a larger value than one that answers in a burst.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Command,
        [int]$QuietMs = 600,
        [int]$MaxMs = 10000
    )
    try { $Session.Port.DiscardInBuffer() } catch { }
    try { $Session.Port.WriteLine($Command) } catch { return '' }
    return (Read-KnxSerialDrain -Session $Session -QuietMs $QuietMs -MaxMs $MaxMs)
}

function Select-KnxSerialDevice {
    <#
    .SYNOPSIS
        Shows the serial devices and lets the user pick one. Returns the port, or ''.
    .DESCRIPTION
        A bare list of /dev/cu.usbmodem84101 and /dev/cu.usbmodem84201 asks the user to
        guess. With -Probe each entry carries the device name, firmware version and serial
        number the device reports itself, which is what the firmware uploader shows too.
    .PARAMETER Probe
        Ask every port who it is before showing the list. Costs a couple of seconds per
        port and asserts DTR - see the note at the top of this module.
    #>
    param([switch]$Probe, [string]$Default = '', [switch]$Optional)
    $devices = @(Get-KnxSerialDevices -Probe:$Probe -ShowProgress)
    if ($devices.Count -eq 0) { return '' }
    Write-Host ''
    for ($i = 0; $i -lt $devices.Count; $i++) {
        $d = $devices[$i]
        $mark = if ($d.Port -eq $Default) { '*' } else { ' ' }
        if ($d.Label) { Write-Host ("   {0}[{1}] {2,-28} {3}" -f $mark, ($i + 1), $d.Port, $d.Label) }
        else { Write-Host ("   {0}[{1}] {2,-28} {3}" -f $mark, ($i + 1), $d.Port, '(did not answer)') -ForegroundColor DarkGray }
    }
    if ($Optional) { Write-Host '    [0] none - skip everything that needs the console' -ForegroundColor DarkGray }

    # If exactly one port answered, that is the device - offer it rather than the first
    # entry in the list. Handing back a port we had just printed as silent is how the
    # hardening stage came to abort on a console that was never there.
    $answered = @($devices | Where-Object { $_.Label })
    if (-not $Default -and $answered.Count -eq 1 -and $Probe) { $Default = $answered[0].Port }

    while ($true) {
        $shown = if ($Default) { " [$Default]" } else { '' }
        $raw = Read-Host "  >$shown"
        $a = if ($null -eq $raw) { '' } else { $raw.Trim() }
        if (-not $a -and $Default) { return $Default }
        if ($a -eq '0' -and $Optional) { return '' }

        $pick = ''
        if ($a -match '^\d+$' -and [int]$a -ge 1 -and [int]$a -le $devices.Count) { $pick = $devices[[int]$a - 1].Port }
        elseif ($a) { $pick = $a }   # a pasted path is legitimate - not every port is listed
        if (-not $pick) {
            Write-Host '    Pick a number from the list, or paste a port.' -ForegroundColor Yellow
            continue
        }

        # Choosing a port that did not answer is allowed - the firmware may have no console,
        # or it may have been busy - but it is not allowed to be silent. Everything that
        # needs the console will abort on it, minutes later, looking like a device fault.
        if ($Probe) {
            $chosen = @($devices | Where-Object { $_.Port -eq $pick })
            if ($chosen.Count -eq 1 -and -not $chosen[0].Label) {
                Write-Host "    $pick did not answer when asked who it is." -ForegroundColor Yellow
                Write-Host '    Stages that need the console will abort on it. Use it anyway? [y/N]' -ForegroundColor Yellow
                $c = Read-Host '  >'
                if ("$c".Trim() -notmatch '^(y|yes|j|ja)$') { continue }
            }
        }
        return $pick
    }
}

# ─── Self-test ──────────────────────────────────────────────────────────────────

function Invoke-KnxSerialSelfTest {
    <#
    .SYNOPSIS
        Checks the shapes and the platform branch offline. No port is opened.
    .DESCRIPTION
        Both bugs this module shipped with were invisible to reading and obvious to running:
        a "return , $array" wrapped the list in another list, so @(...) collected one element
        and the picker offered "[1] System.Object[]"; and branching on $IsMacOS threw under
        Windows PowerShell 5.1, where the variable does not exist and strict mode refuses to
        read it. Neither needs hardware to catch - so they are caught here, on every run.
    #>
    param([switch]$Quiet)
    $cases = New-Object System.Collections.ArrayList
    function Add-Check([string]$name, [bool]$ok, [string]$detail = '') {
        [void]$cases.Add([pscustomobject]@{ Name = $name; Ok = $ok; Detail = $detail })
    }

    $platform = Get-KnxSerialPlatform
    Add-Check 'platform resolves without reading an undefined variable' `
              ($platform -in @('Windows', 'macOS', 'Linux')) "reported '$platform'"

    # The shape checks. A single port must come back as a one-element list, not as a bare
    # string, and no result may hide a whole array inside one element.
    $ports = @(Get-KnxSerialCandidates)
    $flat = $true
    foreach ($p in $ports) { if ($p -isnot [string]) { $flat = $false } }
    Add-Check 'Get-KnxSerialCandidates yields plain strings, one per port' $flat "$($ports.Count) port(s)"

    $devices = @(Get-KnxSerialDevices)
    $shaped = $true
    foreach ($d in $devices) {
        if ($null -eq $d.PSObject.Properties['Port'] -or $d.Port -isnot [string]) { $shaped = $false }
    }
    Add-Check 'Get-KnxSerialDevices yields one object per port with a string Port' $shaped "$($devices.Count) device(s)"
    Add-Check 'both scans agree on how many ports exist' ($ports.Count -eq $devices.Count) `
              "candidates $($ports.Count), devices $($devices.Count)"

    # Negative control: prove the shape check can actually fail, so a green line means
    # something. A wrapped array is exactly what the picker choked on.
    $wrapped = @(, @('a', 'b'))
    Add-Check 'negative control - a wrapped array is recognised as wrong' `
              ($wrapped.Count -eq 1 -and $wrapped[0] -isnot [string]) 'detected'

    $failed = @($cases | Where-Object { -not $_.Ok })
    if (-not $Quiet) {
        Write-Host ''
        Write-Host '  Self-test - serial helpers (no port is opened)' -ForegroundColor Cyan
        foreach ($c in $cases) {
            $col = if ($c.Ok) { 'Green' } else { 'Red' }
            $tag = if ($c.Ok) { 'PASS' } else { 'FAIL' }
            Write-Host ("    {0}  {1}" -f $tag, $c.Name) -ForegroundColor $col
            if ($c.Detail) { Write-Host ("          " + $c.Detail) -ForegroundColor DarkGray }
        }
        Write-Host ''
    }
    return [pscustomobject]@{ Total = $cases.Count; Failed = $failed.Count; Ok = ($failed.Count -eq 0); Cases = @($cases) }
}

Export-ModuleMember -Function *-* -Variable @()
