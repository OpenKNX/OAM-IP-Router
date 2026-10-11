#!/usr/bin/env pwsh
# Open ■
# ┬────┴  KnxBench
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/lib/KnxBench.ps1

<#
.SYNOPSIS
    Reads Test-Bench-Config.json and resolves a test profile against it.

.DESCRIPTION
    The bench configuration describes the test bench once: the KNXnet/IP devices by name, the rig
    around them and the lines a run may address. A profile refers to it instead of repeating the
    addresses: "device" and "traffic" name a device, rig.fromBench takes the bench values.

    Dot-sourced by Run-Tests.ps1 and by the tools that need the bench addresses.

.EXAMPLE
    . (Join-Path $PSScriptRoot 'lib/KnxBench.ps1')
    $bench = Read-KnxBenchConfig -TestRoot $PSScriptRoot
#>

function Test-KnxObjectHas {
    param($Object, [string]$Name)
    return ($null -ne $Object -and $Object -is [pscustomobject] -and $Object.PSObject.Properties.Match($Name).Count -gt 0)
}

function Read-KnxBenchConfig {
    <#
    .SYNOPSIS
        The bench configuration as an object, or $null when the file does not exist.
    #>
    param([Parameter(Mandatory)][string]$TestRoot)
    $file = Join-Path $TestRoot 'Test-Bench-Config.json'
    if (-not (Test-Path $file)) { return $null }
    try { $cfg = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { throw "Test-Bench-Config.json is not readable JSON: $($_.Exception.Message)" }
    $schema = Join-Path $TestRoot 'Test-Bench-Config.schema.json'
    $tj = Get-Command Test-Json -ErrorAction SilentlyContinue
    if ((Test-Path $schema) -and $tj -and $tj.Parameters.ContainsKey('SchemaFile')) {
        $err = $null
        if (-not (Test-Json -Path $file -SchemaFile $schema -ErrorVariable err -ErrorAction SilentlyContinue)) {
            Write-Host '  Test-Bench-Config.json does not match Test-Bench-Config.schema.json:' -ForegroundColor Yellow
            foreach ($e in @($err | Select-Object -First 3)) { Write-Host ("    $($e.Exception.Message)") -ForegroundColor Yellow }
        }
    }
    return $cfg
}

function Test-KnxProfileNeedsBench {
    <#
    .SYNOPSIS
        True when the profile refers to the bench configuration.
    #>
    param($TestProfile)
    if ((Test-KnxObjectHas $TestProfile 'device') -and $TestProfile.device -is [string]) { return $true }
    if (Test-KnxObjectHas $TestProfile 'traffic') { return $true }
    if ((Test-KnxObjectHas $TestProfile 'rig') -and (Test-KnxObjectHas $TestProfile.rig 'fromBench')) { return $true }
    return $false
}

function Resolve-KnxTestProfile {
    <#
    .SYNOPSIS
        Fills a profile from the bench configuration; the result has the device and rig values written out.
    .DESCRIPTION
        A value the profile writes out itself always wins. Throws with a message that names the profile
        and the missing piece, so the caller can show it and leave the profile out.
    #>
    param([Parameter(Mandatory)]$TestProfile, $Bench)
    if (-not (Test-KnxProfileNeedsBench $TestProfile)) { return $TestProfile }
    $name = "$($TestProfile.name)"
    if ($null -eq $Bench) {
        throw "profile '$name' takes its addresses from Test-Bench-Config.json, which does not exist - copy Test-Bench-Config.example.json to that name and enter your bench"
    }
    $findDevice = {
        param([string]$Key, [string]$Field)
        if (-not (Test-KnxObjectHas $Bench 'devices') -or -not (Test-KnxObjectHas $Bench.devices $Key)) {
            $known = @()
            if (Test-KnxObjectHas $Bench 'devices') { $known = @($Bench.devices.PSObject.Properties | ForEach-Object { $_.Name }) }
            throw "profile '$name': $Field names the device '$Key', Test-Bench-Config.json knows: $($known -join ', ')"
        }
        return $Bench.devices.$Key
    }

    if ($TestProfile.device -is [string]) {
        $key = $TestProfile.device
        $src = & $findDevice $key 'device'
        $copy = [pscustomobject]@{}
        foreach ($p in $src.PSObject.Properties) { Add-Member -InputObject $copy -NotePropertyName $p.Name -NotePropertyValue $p.Value }
        $TestProfile.device = $copy
        Add-Member -InputObject $TestProfile -NotePropertyName 'deviceName' -NotePropertyValue $key -Force
    }

    if (-not (Test-KnxObjectHas $TestProfile 'rig')) { Add-Member -InputObject $TestProfile -NotePropertyName 'rig' -NotePropertyValue ([pscustomobject]@{}) }

    if (Test-KnxObjectHas $TestProfile 'traffic') {
        $t = & $findDevice "$($TestProfile.traffic)" 'traffic'
        if (-not (Test-KnxObjectHas $TestProfile.rig 'trafficIp')) {
            Add-Member -InputObject $TestProfile.rig -NotePropertyName 'trafficIp' -NotePropertyValue "$($t.ip)"
        }
    }

    if (Test-KnxObjectHas $TestProfile.rig 'fromBench') {
        $benchRig = [pscustomobject]@{}
        if (Test-KnxObjectHas $Bench 'rig') { $benchRig = $Bench.rig }
        $want = $TestProfile.rig.fromBench
        $names = @($benchRig.PSObject.Properties | ForEach-Object { $_.Name })
        if (-not ($want -is [string] -and $want -eq 'all')) {
            $names = @($want)
            foreach ($n in $names) {
                if (-not (Test-KnxObjectHas $benchRig $n)) { throw "profile '$name': rig.fromBench names '$n', which the rig block of Test-Bench-Config.json does not have" }
            }
        }
        foreach ($n in $names) {
            if (-not (Test-KnxObjectHas $TestProfile.rig $n)) { Add-Member -InputObject $TestProfile.rig -NotePropertyName $n -NotePropertyValue $benchRig.$n }
        }
        $TestProfile.rig.PSObject.Properties.Remove('fromBench')
    }

    if (-not (Test-KnxObjectHas $TestProfile 'safety') -and (Test-KnxObjectHas $Bench 'safety')) {
        Add-Member -InputObject $TestProfile -NotePropertyName 'safety' -NotePropertyValue $Bench.safety
    }
    return $TestProfile
}

function Get-KnxBenchHosts {
    <#
    .SYNOPSIS
        Every IPv4 address the bench configuration names; multicast groups are left out.
    #>
    param($Bench)
    $found = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Bench) { return @() }
    foreach ($m in [regex]::Matches(($Bench | ConvertTo-Json -Depth 8), '\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b')) {
        $ip = $m.Groups[1].Value
        if ([int]($ip.Split('.')[0]) -lt 224 -and -not $found.Contains($ip)) { $found.Add($ip) }
    }
    return @($found | Sort-Object { [version]$_ })
}
