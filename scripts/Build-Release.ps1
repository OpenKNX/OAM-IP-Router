#!/usr/bin/env pwsh
<#
Open ■
┬────┴  Build-Release
■ KNX   2026 OpenKNX - Erkan Çolak

.SYNOPSIS
    Builds the IP-Router firmware for its hardware variants plus the ETS knxprod, via the OGM-Common
    reusable pre/post steps. Standard set = tested hardware; -Full adds the untested/extra variants.

.PARAMETER Mode         Positional shortcut for a switch: Release | Dev | SkipFirmware | SkipHostCli | Clean | Full.
.PARAMETER Release      Build the RELEASE variant. DEFAULT is DEV -- Release is built ONLY with this flag (alias -Rel).
.PARAMETER Dev          Build the Dev variant. This is the default; the flag is optional / explicit.
.PARAMETER Full         Build ALL variants (tested + untested), not just the tested set.
.PARAMETER SkipFirmware Run the pre/post config steps only, skip the firmware compilation.
.PARAMETER SkipHostCli  Skip building the PC tool oknx.
.PARAMETER Clean        Remove generated files (knxprod header + generated knxprods) and exit.
.PARAMETER Help, -h     Show this help.

.EXAMPLE
    ./Build-Release.ps1                  # DEV build (default!), tested hardware
.EXAMPLE
    ./Build-Release.ps1 -Release         # RELEASE build (explicit flag required; -Rel works too)
.EXAMPLE
    ./Build-Release.ps1 -Full            # build ALL variants
.EXAMPLE
    ./Build-Release.ps1 -SkipFirmware    # regenerate configs/knxprod only
.EXAMPLE
    ./Build-Release.ps1 -Clean           # remove generated files and exit

.NOTES
    AUTHOR : Erkan Çolak

.LINK
    https://wiki.openknx.de

.LINK
    https://forum.openknx.de
#>

param(
    [Parameter(Position = 0)]
    [string]$Mode = "",
    [switch]$Dev,
    [Alias("Rel")]
    [switch]$Release,
    [switch]$SkipFirmware,
    [switch]$SkipHostCli,
    [switch]$Clean,
    [switch]$Full,
    [Alias("h")]
    [switch]$Help
)

# OpenKNX logo header
function OpenKNX_ShowLogo($AddCustomText = $null) {
    Write-Host ""
    Write-Host "Open " -NoNewline
    Write-Host "$( [char]::ConvertFromUtf32(0x25A0) )" -ForegroundColor Green
    $bar = "$( [char]::ConvertFromUtf32(0x252C) )$( [char]::ConvertFromUtf32(0x2500) )$( [char]::ConvertFromUtf32(0x2500) )$( [char]::ConvertFromUtf32(0x2500) )$( [char]::ConvertFromUtf32(0x2500) )$( [char]::ConvertFromUtf32(0x2534) ) "
    if ($AddCustomText) { Write-Host "$bar $AddCustomText" -ForegroundColor Green } else { Write-Host "$bar" -ForegroundColor Green }
    Write-Host "$( [char]::ConvertFromUtf32(0x25A0) )" -NoNewline -ForegroundColor Green
    Write-Host " KNX"
    Write-Host ""
}

function Show-Help {
    OpenKNX_ShowLogo "Build-Release (IP-Router)"
    Write-Host "USAGE:" -ForegroundColor Yellow
    Write-Host "  ./Build-Release.ps1 [-Release|-Rel] [-Dev] [-Full] [-SkipFirmware] [-SkipHostCli] [-Clean]"
    Write-Host ""
    Write-Host "OPTIONS:" -ForegroundColor Yellow
    Write-Host "  (default)      Build DEV -- a RELEASE build needs -Release/-Rel" -ForegroundColor Red
    Write-Host "  -Release, -Rel Build the RELEASE variant"
    Write-Host "  -Dev           Build the Dev variant (this is the default anyway)"
    Write-Host "  -Full          Build ALL variants (default: tested only)"
    Write-Host "  -SkipFirmware  Generate configs/knxprod only, skip firmware compilation"
    Write-Host "  -SkipHostCli   Skip building the PC tool oknx"
    Write-Host "  -Clean         Remove generated files and exit"
    Write-Host "  -Help, -h      Show this help"
    Write-Host ""
    Write-Host "EXAMPLES:" -ForegroundColor Yellow
    Write-Host "  ./Build-Release.ps1          " -NoNewline -ForegroundColor White; Write-Host "# DEV build (default!), tested hardware" -ForegroundColor DarkGray
    Write-Host "  ./Build-Release.ps1 -Release " -NoNewline -ForegroundColor White; Write-Host "# RELEASE build" -ForegroundColor DarkGray
    Write-Host "  ./Build-Release.ps1 -Rel -Full" -NoNewline -ForegroundColor White; Write-Host " # release build, all variants" -ForegroundColor DarkGray
    Write-Host ""
}

if ($Help) { Show-Help; exit 0 }

# Positional Mode is an alias for the matching switch
$validModes = @("Release", "Dev", "SkipFirmware", "SkipHostCli", "Clean", "Full", "")
if ($Mode -and $Mode -notin $validModes) {
    Write-Host ""
    Write-Host "ERROR: invalid mode '$Mode'. Valid: Release, Dev, SkipFirmware, SkipHostCli, Clean, Full" -ForegroundColor Red
    Show-Help
    exit 1
}
$isClean        = ($Mode -eq "Clean")        -or $Clean
$isRelease      = ($Mode -eq "Release")      -or $Release
$isDev          = -not $isRelease  # DEFAULT is Dev; a Release build is produced ONLY with an explicit -Release/-Rel flag
$isSkipFirmware = ($Mode -eq "SkipFirmware") -or $SkipFirmware
$isSkipHostCli  = ($Mode -eq "SkipHostCli")  -or $SkipHostCli
$isFull         = ($Mode -eq "Full")         -or $Full

# ---- Clean: remove generated files and exit ------------------------------------------------
if ($isClean) {
    OpenKNX_ShowLogo "Clean"
    # Generated single files: the compiled knxprod header and the packaged release archive.
    foreach ($f in @("include/knxprod.h", "Release.zip")) {
        if (Test-Path $f) { Remove-Item $f -Force; Write-Host "  removed $f" -ForegroundColor Green }
        else { Write-Host "  - $f (already clean)" -ForegroundColor DarkGray }
    }
    # Whole generated release tree (Firmware/, Tools/, ETS-Applikation/, data/, generated knxprods, ...).
    foreach ($d in @("release")) {
        if (Test-Path $d) { Remove-Item $d -Recurse -Force; Write-Host "  removed $d/" -ForegroundColor Green }
        else { Write-Host "  - $d/ (already clean)" -ForegroundColor DarkGray }
    }
    # PlatformIO firmware build targets (all envs). Keeps the resolved libdeps; only the build output goes.
    if (Test-Path ".pio/build") {
        Write-Host "  pio run --target clean ..." -ForegroundColor DarkGray
        pio run --target clean 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host "  cleaned PlatformIO build targets (.pio/build)" -ForegroundColor Green }
        else { Write-Host "  pio clean returned $LASTEXITCODE -- continuing" -ForegroundColor Yellow }
    }
    else { Write-Host "  - .pio/build (already clean)" -ForegroundColor DarkGray }
    # oknx PC-tool build output (.pio = the pio staging, holds the oknx-<os>-<arch> binaries too). The
    # shared zig cache in the PlatformIO core dir is intentionally KEPT (re-downloading zig on every clean is wasteful).
    $oknxPio = "lib/OFM-FileTransferModule/oknx/.pio"
    if (Test-Path $oknxPio) { Remove-Item $oknxPio -Recurse -Force; Write-Host "  removed $oknxPio/" -ForegroundColor Green }
    else { Write-Host "  - $oknxPio/ (already clean)" -ForegroundColor DarkGray }
    Write-Host ""
    Write-Host "Clean done." -ForegroundColor Green
    exit 0
}

# ============================================================================
# BUILD TARGETS -- Env / Name (output firmware) / Ext (featureSet, see Build-Step.ps1)
# ============================================================================

# Standard targets = tested hardware
$standardTargets = @(
    @{ Env = "release_REG1_LAN_TP_BASE";     Name = "firmware-IP-Router-REG1-LAN-TP-Base";     Ext = "esp32-ip"  }
    @{ Env = "release_REG2_PICO_ETH_DD";     Name = "firmware-IP-Router-REG2-Pico-Eth-DD";     Ext = "rp2040-ip" }
)

# Full targets = additional / not yet tested
$fullTargets = @(
    @{ Env = "release_REG1_ETH";             Name = "firmware-IP-Router-REG1-Eth";             Ext = "rp2040-ip" }
    @{ Env = "release_REG2_PICO_W_ETH_DD";   Name = "firmware-IP-Router-REG2-PicoW-Eth-DD";    Ext = "rp2040-ip" }
    @{ Env = "release_REG2_PICO2_ETH_DD";    Name = "firmware-IP-Router-REG2-Pico2-Eth-DD";    Ext = "rp2040-ip" }
    @{ Env = "release_REG2_PICO_ESP_ETH_DD"; Name = "firmware-IP-Router-REG2-Pico-Esp-Eth-DD"; Ext = "esp32-ip"  }
    
)

$buildParam = if ($isDev) { "Dev" } else { "Release" }
$buildStart = Get-Date
OpenKNX_ShowLogo "Build-Release ($buildParam$(if ($isFull) { ', Full' })$(if ($isSkipFirmware) { ', SkipFirmware' }))"

# Loud reminder: the default is a DEV build. A real release must be asked for explicitly.
if ($isDev) {
    Write-Host "DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV " -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  WARNING: no -Release flag -> building DEV (IP-Router-Dev), NOT a release."
    Write-Host "           Use  -Release  (or -Rel)  to build the RELEASE variant."
    Write-Host "           The DEV build is for testing only, not for production use."
    Write-Host ""
    Write-Host "DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV DEV " -ForegroundColor Yellow
    Write-Host ""
}

# ---- PC tool oknx -- built FIRST ------------------------------------------------------------
# Build the whole PC-tool OS/arch matrix (Windows x86/x64/arm64, macOS x64/arm64, Linux x64/arm64/armhf) with
# a single `pio run`: the oknx platformio.ini defines one env per target and a pre-build hook that pulls a
# project-local zig for the cross targets, so pio itself cross-builds everything into oknx/.pio/build/. Done
# up front so a tool build failure aborts BEFORE the firmware build. Skip with -SkipHostCli.
# The release layout Tools/oknx/<OS>/<arch>/oknx[.exe] is assembled centrally by OGM-Common's
# Build-Release-Postprocess.ps1 -- nothing to copy here.
$oknxDir = "lib/OFM-FileTransferModule/oknx"
# Also skipped by -SkipFirmware: that mode regenerates configs only, and the PC tool is a compile step.
if (-not $isSkipHostCli -and -not $isSkipFirmware) {
    if (Test-Path (Join-Path $oknxDir "platformio.ini")) {
        Write-Host "Building the oknx PC tool matrix (pio run -> oknx, all OS/arch)..." -ForegroundColor Cyan
        pio run -d $oknxDir
        if (!$?) { Write-Host "oknx build failed" -ForegroundColor Red; exit 1 }
    } else {
        Write-Host "oknx project not found ($oknxDir) -- the release would ship without the PC tool" -ForegroundColor Red
        Write-Host "  check out the OFM-FileTransferModule submodule, or pass -SkipHostCli to leave it out on purpose" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "Skipping PC tool build (SkipHostCli)" -ForegroundColor Yellow
}

# ---- generic pre-build steps ---------------------------------------------------------------
lib/OGM-Common/scripts/setup/reusable/Build-Release-Preprocess.ps1 $buildParam
if (!$?) { exit 1 }

# ---- firmware builds -----------------------------------------------------------------------
if (-not $isSkipFirmware) {
    Write-Host "Building standard targets (tested hardware)..." -ForegroundColor Cyan
    foreach ($t in $standardTargets) {
        lib/OGM-Common/scripts/setup/reusable/Build-Step.ps1 $t.Env $t.Name $t.Ext
        if (!$?) { exit 1 }
    }
    if ($isFull) {
        Write-Host "Building full targets (untested / extra hardware)..." -ForegroundColor Cyan
        foreach ($t in $fullTargets) {
            lib/OGM-Common/scripts/setup/reusable/Build-Step.ps1 $t.Env $t.Name $t.Ext
            if (!$?) { exit 1 }
        }
    } else {
        Write-Host "Skipping full targets (use -Full to build all)" -ForegroundColor Yellow
    }
} else {
    Write-Host "Skipping firmware builds (SkipFirmware mode)" -ForegroundColor Yellow
}

# ---- assemble the release: docs into the release root ---------------------------------------
# Runs AFTER preprocess (which wipes release/) and BEFORE postprocess (which zips release/*), so the
# copied files land inside the final Release.zip.
$testGuide = "doc/FTC-Testanleitung.md"
if (Test-Path $testGuide) {
    Copy-Item -Force $testGuide "release/"
    Write-Host "  -> release/FTC-Testanleitung.md" -ForegroundColor Green
}

# ---- generic post-build steps --------------------------------------------------------------
lib/OGM-Common/scripts/setup/reusable/Build-Release-Postprocess.ps1 $buildParam
if (!$?) { exit 1 }

# ---- closing note: a new build is untested -------------------------------------------------
# Shown only for a package written by this run, so a failed packaging step is not reported as finished.
$package = Get-ChildItem -Path "release" -Filter "OpenKNX-*.zip" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $buildStart } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($null -ne $package) {
    $variants = if ($isSkipFirmware) { 0 } elseif ($isFull) { $standardTargets.Count + $fullTargets.Count } else { $standardTargets.Count }
    $content  = if ($variants -gt 0) { "$buildParam, $variants firmware variants" } else { "$buildParam, no firmware built" }
    Write-Host ""
    Write-Host "Build finished: " -NoNewline -ForegroundColor Green
    Write-Host "release/$($package.Name)" -NoNewline
    Write-Host "  ($content)" -ForegroundColor DarkGray
    if ($variants -gt 0) {
        Write-Host ""
        Write-Host "  This build is new and nothing in it has been tested yet."
        Write-Host "  Before it is handed on, run it through the test suite:"
        Write-Host ""
        Write-Host "    1. Flash the firmware to the test device. If the application version changed, download it with ETS." -ForegroundColor DarkGray
        Write-Host "    2. " -NoNewline -ForegroundColor DarkGray
        Write-Host "pwsh scripts/Test/Run-Tests.ps1 -TestProfile router-all" -ForegroundColor Cyan
        Write-Host "       (pwsh scripts/Test/Run-Tests.ps1 -ListProfiles shows the shorter runs)" -ForegroundColor DarkGray
        Write-Host "    3. Read the report in scripts/Test/Reports/." -ForegroundColor DarkGray
        if (Test-Path "release/FTC-Testanleitung.md") {
            Write-Host ""
            Write-Host "  Test guide: release/FTC-Testanleitung.md" -ForegroundColor DarkGray
        }
    }
    Write-Host ""
}
