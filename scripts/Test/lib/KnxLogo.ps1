#!/usr/bin/env pwsh
# Open ■
# ┬────┴  KnxLogo
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/lib/KnxLogo.ps1

<#
.SYNOPSIS
    The OpenKNX logo block, in one place for every test script.

.DESCRIPTION
    The colours OGM-Common uses in OpenKNX_ShowLogo
    (scripts/setup/reusable/data/OpenKNX-UI-Generic.ps1): "Open " in the default colour, the squares
    and the bar in green, " KNX" plain. The copyright follows on the same line in grey, so every script
    carries it without each one having to remember.

    Its own file rather than a function in KnxTest.psm1: only 14 of the 23 scripts that print the
    logo import that module, and the other nine would have had to pull in the whole test library to
    draw three lines.

    The glyphs are built from code points. A literal depends on the file still being UTF-8 when it
    is read; every script here carries a BOM today, so nothing is broken right now, but a code point
    cannot be broken by an editor that saves without one.

.PARAMETER Title
    The one line next to the bar, e.g. 'OpenKNX test runner'.

.EXAMPLE
    . (Join-Path $PSScriptRoot 'lib/KnxLogo.ps1')
    Write-KnxLogo -Title 'OpenKNX test runner'
#>

function Write-KnxLogo {
    param([string]$Title = '')
    $sq  = [char]::ConvertFromUtf32(0x25A0)   # black square
    $bar = [char]::ConvertFromUtf32(0x252C) + ([char]::ConvertFromUtf32(0x2500) * 4) + [char]::ConvertFromUtf32(0x2534)
    Write-Host ''
    Write-Host 'Open ' -NoNewline
    Write-Host $sq -ForegroundColor Green
    if ($Title) { Write-Host ("{0}  {1}" -f $bar, $Title) -ForegroundColor Green }
    else        { Write-Host $bar -ForegroundColor Green }
    Write-Host $sq -NoNewline -ForegroundColor Green
    Write-Host ' KNX' -NoNewline
    Write-Host '   2026 OpenKNX - Erkan Çolak' -ForegroundColor DarkGray
    Write-Host ''
}
