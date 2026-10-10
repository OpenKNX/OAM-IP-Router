#!/usr/bin/env pwsh
# Open $
# +----+  New-ReportPage
# $ KNX   2026 OpenKNX - Erkan Colak
#
# FILEPATH: scripts/Test/Tools/New-ReportPage.ps1

<#
.SYNOPSIS
    Renders a Markdown report from doc/ into a self-contained HTML page.

.DESCRIPTION
    The generator of the old findings page was lost with the scratch directory of the session that wrote
    it, so the HTML could not be rebuilt from its Markdown source. This one lives in the repository.

    It covers what the report pages use: headings, tables, paragraphs, lists, rules, and inline bold and
    code. Everything else is passed through escaped. The page carries its own stylesheet and follows the
    system colour scheme, so it needs no network and no files beside it.

.PARAMETER Path
    The Markdown file to render.

.PARAMETER OutFile
    Where to write the HTML. Default: the input path with the extension replaced.

.PARAMETER Title
    Page title. Default: the first heading of the document.

.EXAMPLE
    pwsh Tools/New-ReportPage.ps1 -Path ../../doc/Stand-und-Freigabe-2026-09-20.md
    Writes doc/Stand-und-Freigabe-2026-09-20.html beside the source.

.NOTES
    Pure PowerShell 5.1 compatible, ASCII source, no modules.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [string]$OutFile = '',
    [string]$Title = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not (Test-Path $Path)) { throw "not found: $Path" }
$src = Get-Content -Path $Path -Raw -Encoding UTF8
if (-not $OutFile) { $OutFile = [System.IO.Path]::ChangeExtension((Resolve-Path $Path).Path, 'html') }

function ConvertTo-HtmlText {
    <#
    .SYNOPSIS
        Escapes a Markdown fragment and applies inline bold and code.
    #>
    param([string]$Text)
    $t = $Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
    $t = [regex]::Replace($t, '`([^`]+)`', '<code>$1</code>')
    $t = [regex]::Replace($t, '\*\*([^*]+)\*\*', '<strong>$1</strong>')
    return $t
}

$lines = $src -split "`r?`n"
$html = New-Object System.Text.StringBuilder
$inTable = $false
$inList = $false
$rowIndex = 0

function Close-Blocks {
    <#
    .SYNOPSIS
        Ends a table or list that a non-matching line interrupts.
    #>
    if ($script:inTable) { [void]$html.AppendLine('</tbody></table>'); $script:inTable = $false }
    if ($script:inList) { [void]$html.AppendLine('</ul>'); $script:inList = $false }
}

foreach ($line in $lines) {
    $l = $line.TrimEnd()

    if ($l -match '^\s*$') { Close-Blocks; continue }

    # A table separator row belongs to the header that came before it.
    if ($l -match '^\|[\s:\-\|]+\|$' -and $script:inTable -and $rowIndex -eq 1) { continue }

    if ($l -match '^\|(.*)\|$') {
        $cells = ($Matches[1] -split '(?<!\\)\|') | ForEach-Object { ConvertTo-HtmlText ($_.Trim()) }
        if (-not $script:inTable) {
            [void]$html.AppendLine('<table><thead><tr>')
            foreach ($c in $cells) { [void]$html.AppendLine("<th>$c</th>") }
            [void]$html.AppendLine('</tr></thead><tbody>')
            $script:inTable = $true
            $rowIndex = 1
        }
        else {
            [void]$html.AppendLine('<tr>')
            foreach ($c in $cells) { [void]$html.AppendLine("<td>$c</td>") }
            [void]$html.AppendLine('</tr>')
            $rowIndex++
        }
        continue
    }
    Close-Blocks

    if ($l -match '^---+$') { [void]$html.AppendLine('<hr>'); continue }

    if ($l -match '^(#{1,6})\s+(.*)$') {
        $level = $Matches[1].Length
        $text = ConvertTo-HtmlText $Matches[2]
        $id = ($Matches[2] -replace '[^\w\.]+', '-').Trim('-').ToLower()
        [void]$html.AppendLine("<h$level id=""$id"">$text</h$level>")
        continue
    }

    if ($l -match '^\s*[-*]\s+(.*)$') {
        if (-not $script:inList) { [void]$html.AppendLine('<ul>'); $script:inList = $true }
        [void]$html.AppendLine('<li>' + (ConvertTo-HtmlText $Matches[1]) + '</li>')
        continue
    }

    [void]$html.AppendLine('<p>' + (ConvertTo-HtmlText $l) + '</p>')
}
Close-Blocks

if (-not $Title) {
    $first = $lines | Where-Object { $_ -match '^#\s+' } | Select-Object -First 1
    $Title = if ($first) { ($first -replace '^#\s+', '').Trim() } else { [System.IO.Path]::GetFileNameWithoutExtension($Path) }
}
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'

$style = @'
:root{--paper:#F7F8FA;--card:#FFFFFF;--ink:#16191F;--ink-soft:#5A6270;--rule:#DDE1E8;--accent:#1F5F5B;--accent-soft:#E4EFEE;--warn-bg:#FBF1DE;}
@media (prefers-color-scheme: dark){:root{--paper:#0F1218;--card:#161A22;--ink:#E7EAF0;--ink-soft:#A3ACBC;--rule:#252B36;--accent:#5FB8B0;--accent-soft:#17312F;--warn-bg:#2A2214;}}
*{box-sizing:border-box}
body{margin:0;background:var(--paper);color:var(--ink);font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
main{max-width:1100px;margin:0 auto;padding:32px 16px 96px}
h1{font-size:28px;line-height:1.25;margin:8px 0 4px}
h2{font-size:21px;margin:40px 0 8px;padding-top:16px;border-top:1px solid var(--rule)}
h3{font-size:17px;margin:24px 0 6px;color:var(--accent)}
p{margin:10px 0}
hr{border:0;border-top:1px solid var(--rule);margin:24px 0}
code{font:13px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--accent-soft);padding:1px 5px;border-radius:4px}
table{width:100%;border-collapse:collapse;margin:12px 0 20px;background:var(--card);border:1px solid var(--rule);border-radius:8px;overflow:hidden}
th{text-align:left;font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:var(--ink-soft);background:var(--paper);padding:10px 12px;border-bottom:1px solid var(--rule)}
td{padding:10px 12px;border-bottom:1px solid var(--rule);vertical-align:top}
tr:last-child td{border-bottom:0}
td:first-child{white-space:nowrap;font-weight:600}
ul{margin:8px 0 16px 20px;padding:0}
li{margin:4px 0}
strong{font-weight:650}
.stamp{color:var(--ink-soft);font-size:13px;margin-bottom:24px}
@media (max-width:720px){td:first-child{white-space:normal}main{padding:20px 16px 64px}}
'@

$doc = @"
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$Title</title>
<style>$style</style>
</head>
<body>
<main>
<p class="stamp">erzeugt $stamp aus $([System.IO.Path]::GetFileName($Path))</p>
$($html.ToString())
</main>
</body>
</html>
"@

[System.IO.File]::WriteAllText($OutFile, $doc, (New-Object System.Text.UTF8Encoding $false))
Write-Host "  wrote $OutFile" -ForegroundColor Green
