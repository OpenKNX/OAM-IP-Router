#!/usr/bin/env pwsh
# Open ■
# ┬────┴  New-TestReport
# ■ KNX   2026 OpenKNX - Erkan Çolak
#
# FILEPATH: scripts/Test/Tools/New-TestReport.ps1

<#
.SYNOPSIS
    Builds one filterable HTML report out of the JSON files the test runs leave behind.

.DESCRIPTION
    Every runner writes Reports/<product>_<stamp>.json. Kept by hand, a report drifts from the
    runs it claims to describe; this reads the runs themselves, so what the page says is what
    the devices answered.

    Per product and CASE the newest result wins, not the newest run: a re-run of one suite must
    update its own cases and leave the rest standing. Taking the newest run instead let a 29-case
    suite re-run hide a 121-case conformance run of the same device.

.PARAMETER ReportDir
    Where the run JSON files are. Default: the Reports folder next to the Test root.

.PARAMETER OutFile
    HTML file to write. Default: doc/pruefbericht.html in the product repo.

.PARAMETER Title
    Heading of the page.

.EXAMPLE
    ./Tools/New-TestReport.ps1
    Rebuilds the report from every run currently in Reports/.

.EXAMPLE
    ./Tools/New-TestReport.ps1 -OutFile /tmp/preview.html
    Writes a preview without touching the committed report.
#>

[CmdletBinding()]
param(
    [string]$ReportDir = '',
    [string]$OutFile = '',
    [string]$Title = 'Prüfbericht'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)   # scripts/Test
if (-not $ReportDir) { $ReportDir = Join-Path $here 'Reports' }
# A bundle may keep its companions next to it as "$ReportDir.json" / "$ReportDir.settings.json"; a trailing separator
# (tab completion) would look for "<dir>/.json" and silently drop the stage table and the settings block.
$ReportDir = $ReportDir.TrimEnd('/', '\')
if (-not $OutFile) {
    # Pointed at a run bundle (Reports/<RunId>/), the report belongs INSIDE it as <RunId>.html: one run,
    # one directory, nothing of it lying next to the folder. The name keeps the run id so a single file
    # still identifies itself once it is copied out. Only the flat Reports directory, which is every run
    # at once, still goes to the collected page under doc/.
    $leaf = Split-Path -Leaf $ReportDir
    if ($leaf -match '^[A-Za-z]+_\d{8}-\d{6}$') {
        $OutFile = Join-Path $ReportDir "$leaf.html"
        if (-not $PSBoundParameters.ContainsKey('Title')) { $Title = "Prüfbericht $leaf" }
    }
    else {
        $OutFile = Join-Path (Split-Path -Parent (Split-Path -Parent $here)) 'doc/pruefbericht.html'
    }
}

# The settings of a bundle say what the run was given. Shown in the report, they turn "22 cases were
# not executed" into "this run had no -TestGa" without anybody having to ask the person who ran it.
# Inside the folder first, beside it second: runs written before the move keep their companions as
# siblings, and dropping the fallback would silently strip their stage table and settings block.
function Resolve-Companion {
    param([string]$Dir, [string]$Suffix)
    $leaf = Split-Path -Leaf $Dir
    $inside = Join-Path $Dir ($leaf + $Suffix)
    if (Test-Path $inside) { return $inside }
    $beside = "$Dir$Suffix"
    if (Test-Path $beside) { return $beside }
    return ''
}

$runSettings = $null
$settingsPath = Resolve-Companion -Dir $ReportDir -Suffix '.settings.json'
if ($settingsPath -and (Test-Path $settingsPath)) {
    try { $runSettings = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $runSettings = $null }
}

# The stage table of the run, from the combined file of the bundle. Without it a stage that
# leaves no case behind - Legacy reports only at stage level, a SKIPPED stage not at all - is
# simply absent from the report, and an absent stage reads like a clean one.
$runStages = @()
$runResult = ''
$combinedPath = Resolve-Companion -Dir $ReportDir -Suffix '.json'
if ($combinedPath -and (Test-Path $combinedPath)) {
    try {
        $cj = Get-Content $combinedPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $cj.PSObject.Properties['stages'] -and $null -ne $cj.stages) { $runStages = @($cj.stages) }
        # 'result' is what the runner writes now; 'verdict' is what every run file written before
        # the rename carries. Reading only the new name would blank the run banner on all of them.
        if ($null -ne $cj.PSObject.Properties['result'])  { $runResult = ([string]$cj.result).ToUpper() }
        elseif ($null -ne $cj.PSObject.Properties['verdict']) { $runResult = ([string]$cj.verdict).ToUpper() }
    } catch { $runStages = @() }
}

. (Join-Path $PSScriptRoot '../lib/KnxLogo.ps1')
Write-KnxLogo -Title 'Test report builder'

function Test-Prop {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-Field {
    <#
    .SYNOPSIS
        A property's value as text, or a default when the record does not carry it.
    .DESCRIPTION
        Set-StrictMode makes a missing property a terminating error, so a single older or hand-edited
        run file otherwise aborts the whole report instead of contributing what it does have.
    #>
    param($Object, [string]$Name, [string]$Default = '')
    if (-not (Test-Prop $Object $Name)) { return $Default }
    $v = $Object.$Name
    if ($null -eq $v) { return $Default }
    return [string]$v
}

function Get-CaseResult {
    <#
    .SYNOPSIS
        A case's result, whichever of the two field names the producing runner used.
    .DESCRIPTION
        The conformance and feature suites write "Result", the FTC hardening runner writes "Verdict".
        Reading only "Result" silently turned all 51 hardening cases - 38 of them PASS - into
        "not applicable", which is a report claiming less was judged than actually was.
    #>
    param($Case)
    $v = Get-Field $Case 'Result' ''
    if (-not $v) { $v = Get-Field $Case 'Verdict' '' }
    # A record carrying neither field is unreadable, which is not the same statement as "does not apply
    # to this device". It keeps the N-A tally it always had, but it is shown as '?' and named on the
    # console, so a malformed run file cannot pass as a result about hardware.
    if (-not $v) { return '?' }
    return $v.ToUpper()
}

function Get-Clause {
    <#
    .SYNOPSIS
        The clause a case cites - "Clause" in the KNX suites, "Reference" in the FTC runner.
    #>
    param($Case)
    $c = Get-Field $Case 'Clause' ''
    if (-not $c) { $c = Get-Field $Case 'Reference' '' }
    return $c
}

function Convert-Html {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $t = $Text -replace '&', '&amp;'
    $t = $t -replace '<', '&lt;'
    $t = $t -replace '>', '&gt;'
    $t = $t -replace '"', '&quot;'
    return $t
}

$files = @(Get-ChildItem -Path $ReportDir -Filter '*.json' -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) { Write-Host "  no run data in $ReportDir" -ForegroundColor Red; exit 1 }

# Newest run per product. The product name already separates interface from router and
# conformance from features, which is exactly the granularity a reader compares.
$cases = @{}    # "<run>|<case id>" -> newest result
$meta  = @{}    # run -> newest run header
foreach ($f in $files) {
    try { $d = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    # StrictMode turns a missing property into a terminating error, and older run files carry a
    # different shape - ask the object what it has instead of assuming the current schema.
    if (-not (Test-Prop $d 'product')) { continue }
    if (-not (Test-Prop $d 'results')) { continue }
    if ($null -eq $d.results) { continue }

    # ConvertFrom-Json hands back a [datetime] for an ISO timestamp, and [string] on that renders it in
    # the CURRENT CULTURE ("09/14/2026 21:13:04"). Comparing those as text is month-major, so a PASS from
    # December 2025 sorted above a FAIL from September 2026 and the report published the stale result.
    # Compare the values, never their rendering; the file name is the fallback and is already sortable.
    $started = $null
    if (Test-Prop $d 'started') { try { $started = [datetime]$d.started } catch { $started = $null } }
    if ($null -eq $started) { $started = $f.LastWriteTime }

    # Identity is the DEVICE plus the SUITE, never the product label: that label is derived from the
    # -Role switch, so the same board appears as "IP-Interface-features" or "IP-Router-features"
    # depending on how the run was invoked - and a corrected re-run could then never supersede the
    # botched one, which kept three stale failures of a correct device in the report. Keying on the
    # product alone was just as wrong in the other direction: two boards share one name, and the good
    # one's PASS overwrote the bad one's FAIL.
    $bdut = if (Test-Prop $d 'bdut') { [string]$d.bdut } else { '' }
    # The suite, with the role token removed: "IP-Interface-features" and "IP-Router-features" are the
    # same suite against the same board. The profile field cannot serve here - the device suite runs
    # THROUGH an interface and would otherwise share its identity.
    $suite = [string]$d.product
    if ($suite -match '^(IP-Interface|IP-Router)(-(.+))?$') {
        $suite = if ($Matches[3]) { $Matches[3] } else { 'conformance' }
    }
    # For the device suite the "bdut" is the INTERFACE the run looked through, not the device being
    # judged - that one is named in every case id ("D-2.4 5.0.7"). Keying on the interface made the
    # same TP device appear twice, once per window, and the older window kept publishing its stale
    # failures. The subject decides the identity, not the instrument.
    $ident = if ($suite -eq 'KNX-Device') { $suite }
             elseif ($bdut) { "$bdut|$suite" }
             else { "$([string]$d.product)|$suite" }

    if (-not $meta.ContainsKey($ident) -or $started -gt $meta[$ident]._started) {
        Add-Member -InputObject $d -NotePropertyName '_started' -NotePropertyValue $started -Force
        $lbl = if ($suite -eq 'KNX-Device') { [string]$d.product } elseif ($bdut) { "$([string]$d.product) ($bdut)" } else { [string]$d.product }
        Add-Member -InputObject $d -NotePropertyName '_label' -NotePropertyValue $lbl -Force
        $meta[$ident] = $d
    }
    foreach ($c in $d.results) {
        if (-not (Test-Prop $c 'Id')) { continue }
        $key = $ident + '|' + [string]$c.Id
        if ($cases.ContainsKey($key) -and $cases[$key].Started -ge $started) { continue }
        $cases[$key] = [pscustomobject]@{ Ident = $ident; Started = $started; Case = $c }
    }
}
if ($cases.Count -eq 0) { Write-Host '  no usable run data' -ForegroundColor Red; exit 1 }

$order = @($meta.Keys | Sort-Object { [string]$meta[$_]._label })
$byProduct = @{}
foreach ($k in $order) { $byProduct[$k] = @() }
foreach ($v in $cases.Values) { $byProduct[$v.Ident] += $v }

$tot = 0; $pass = 0; $fail = 0; $skip = 0; $notrun = 0; $na = 0; $noproof = 0
$counts = @{}
foreach ($k in $order) {
    $p = 0; $fl = 0; $sk = 0; $nr = 0; $n = 0; $np = 0
    foreach ($v in $byProduct[$k]) {
        switch (Get-CaseResult $v.Case) {
            'PASS' { $p++ }
            'FAIL' { $fl++ }
            'SKIP' { $sk++ }
            'NOT-RUN' { $nr++ }
            # A case that ran and asserted nothing is its own class: folding it into NA would report
            # "the device does not have it" for something the run simply never tested.
            'NO-PROOF' { $np++ }
            default { $n++ }
        }
    }
    $counts[$k] = [pscustomobject]@{ Total = $byProduct[$k].Count; Pass = $p; Fail = $fl; Skip = $sk; NotRun = $nr; NA = $n; NoProof = $np }
    $tot += $byProduct[$k].Count; $pass += $p; $fail += $fl; $skip += $sk; $notrun += $nr; $na += $n; $noproof += $np
}
# What the report may claim. Everything outside it was not a result about a device.
$judged = $pass + $fail
$judgedPct = if ($tot -gt 0) { [int](100 * $judged / $tot) } else { 0 }
# Suites a runner refused to start. They leave no cases behind, so without this they are invisible.
$droppedAll = @()
foreach ($k in $order) {
    $d = $meta[$k]
    if ((Test-Prop $d 'dropped') -and $null -ne $d.dropped) {
        foreach ($dr in @($d.dropped)) {
            $droppedAll += [pscustomobject]@{ Run = [string]$d._label; Suite = [string]$dr.Suite; Reason = [string]$dr.Reason }
        }
    }
}
# Cases that need an argument the run did not have, grouped by that argument.
$notRunRows = @()
foreach ($k in $order) {
    foreach ($v in $byProduct[$k]) {
        if ((Get-CaseResult $v.Case) -ne 'NOT-RUN') { continue }
        $notRunRows += [pscustomobject]@{
            Run = [string]$meta[$k]._label
            Missing = (Get-Field $v.Case 'Missing' '(not recorded)')
            Id = (Get-Field $v.Case 'Id' '?')
            Reason = (Get-Field $v.Case 'Reason' '')
        }
    }
}

# The dimensions the reader filters by. An individual address is taken from the case id
# ("D-2.4 5.0.8") and, failing that, from the suite name ("D Device 5.0.8"), because that is where
# the device suite records which box answered.
$paSet = New-Object 'System.Collections.Generic.HashSet[string]'
$suiteSet = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($v in $cases.Values) {
    $cid = Get-Field $v.Case 'Id' ''
    $csu = Get-Field $v.Case 'Suite' ''
    if ($csu) { [void]$suiteSet.Add($csu) }
    if ($cid -match '\s(\d+\.\d+\.\d+)\s*$') { [void]$paSet.Add($Matches[1]) }
    elseif ($csu -match '\s(\d+\.\d+\.\d+)\s*$') { [void]$paSet.Add($Matches[1]) }
}

$unreadable = 0   # cases whose run file carries no result field at all
$sb = New-Object System.Text.StringBuilder
function Add-Line { param([string]$s) [void]$sb.AppendLine($s) }

# The page wears the device's own web interface: the stylesheet and the logo are read from
# lib/OFM-Network/web/assets at generation time and inlined, so the report cannot drift away from
# what the interface looks like, and the file stays one self-contained thing to hand over.
$repoRoot = Split-Path -Parent (Split-Path -Parent $here)
$assetDir = Join-Path $repoRoot 'lib/OFM-Network/web/assets'
$baseCss = ''
$logoSvg = ''
$iconHref = ''
$cssPath = Join-Path $assetDir 'base.css'
$svgPath = Join-Path $assetDir 'logo.svg'
$icoPath = Join-Path $assetDir 'favicon.svg'
if (Test-Path $cssPath) {
    $baseCss = Get-Content $cssPath -Raw -Encoding UTF8
    $baseCss = $baseCss -replace '(?i)</style', '<\/style'   # a closing tag in the text would end the element early
}
if (Test-Path $svgPath) { $logoSvg = Get-Content $svgPath -Raw -Encoding UTF8 }
if (Test-Path $icoPath) {
    $icoB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Content $icoPath -Raw -Encoding UTF8)))
    $iconHref = "data:image/svg+xml;base64,$icoB64"
}
if (-not $baseCss) {
    Write-Host "  note: $cssPath not found - the page falls back to a plain stylesheet" -ForegroundColor Yellow
    $baseCss = 'body{font-family:sans-serif;margin:2em;color:#111} nav{display:none} table{border-collapse:collapse;width:100%}'
}
if (-not $logoSvg) { $logoSvg = '<div style="color:#fff;font:600 1.1em sans-serif">Open &#9632; KNX</div>' }

$generated = (Get-Date).ToString('yyyy-MM-dd HH:mm')
$year = (Get-Date).ToString('yyyy')
$author = 'Erkan ' + [char]0x00C7 + 'olak'
# A stage without a Status is not assumed to have passed - an unreadable status counts as a failure.
$stageFail = @($runStages | Where-Object { @('FAIL', 'ERROR', '?') -contains (Get-Field $_ 'Status' '?').ToUpper() }).Count
$stageSkip = @($runStages | Where-Object { (Get-Field $_ 'Status' '?').ToUpper() -eq 'SKIPPED' }).Count
# The runner's own word on the run. INCOMPLETE means a stage never ran, which the case tally cannot
# show: reading only the case results put a green dot on a run the runner refused to call PASS.
$result = if ($fail -gt 0) { "$fail Fall/Fälle gescheitert" }
           elseif ($stageFail -gt 0) { "$stageFail Stufe(n) gescheitert" }
           elseif ($runResult -eq 'INCOMPLETE' -or $stageSkip -gt 0) { "unvollständig - $stageSkip Stufe(n) übersprungen" }
           else { 'kein Fall gescheitert' }
$dotClass = if ($fail -gt 0 -or $stageFail -gt 0) { 'dot-red' }
            elseif ($runResult -eq 'INCOMPLETE' -or $stageSkip -gt 0) { 'dot-amber' }
            else { 'dot-green' }
$hasGaps = ($droppedAll.Count -gt 0 -or $notRunRows.Count -gt 0)

$runIdText = ''
if (($null -ne $runSettings) -and (Test-Prop $runSettings 'runId')) { $runIdText = [string]$runSettings.runId }

Add-Line '<!DOCTYPE html>'
Add-Line '<html lang="de"><head>'
Add-Line '<meta charset="utf-8">'
Add-Line '<meta name="viewport" content="width=device-width, initial-scale=1">'
Add-Line "<meta name=""author"" content=""$(Convert-Html $author)"">"
Add-Line '<meta name="generator" content="OpenKNX New-TestReport.ps1">'
Add-Line "<title>$(Convert-Html $Title)</title>"
if ($iconHref) { Add-Line "<link rel=""icon"" href=""$iconHref"">" }
Add-Line '<!-- generated by scripts/Test/Tools/New-TestReport.ps1 - do not edit by hand -->'
Add-Line '<style>'
Add-Line '/* --- lib/OFM-Network/web/assets/base.css - the device web interface, inlined verbatim --- */'
Add-Line $baseCss
Add-Line @'
/* --- report layer on top of it --- */
/* The device serves one page at a time and puts its menu in a column; a report is read top to
   bottom, so the same navigation runs across the top and the imprint sits at the foot. */
body { display: block; min-height: 100vh; }
nav { position: sticky; top: 0; width: auto; min-width: 0; height: auto;
      flex-direction: row; align-items: center; flex-wrap: wrap;
      padding: 0 18px; overflow: visible; box-shadow: 0 2px 6px rgba(0, 0, 0, .18); }
.logo { width: 118px; padding: 0; margin: 9px 22px 9px 0; }
.logo svg { width: 100%; height: auto; display: block; }
.menu-container { flex-direction: row; flex-wrap: wrap; width: auto; margin: 0; }
nav a.menu { width: auto; padding: 15px 14px; border-left: 0; border-bottom: 3px solid transparent; }
nav a.menu:hover { border-left-color: transparent; border-bottom-color: #449841; }
a.menu.active { border-left-color: transparent; border-bottom-color: #449841; }
.nav-status { margin-left: auto; display: flex; align-items: center; gap: 14px; padding: 8px 0; }
.nav-status .nav-firm { color: #aaa; }
.dot-amber { background: #e6a700; }

footer { background: #000; color: #777; margin-top: 3.5em; padding: 22px 2em calc(22px + env(safe-area-inset-bottom));
         font-size: .78em; line-height: 1.6; display: flex; flex-wrap: wrap; gap: 6px 36px; }
footer b { color: #bbb; font-weight: 600; }
footer .col { min-width: 210px; }
footer a { color: #449841; text-decoration: none; }

main { padding: 1.8em 2em 2em; }
/* The report uses the window it is given: a 300-case table is the whole point of the page. */
.container { max-width: none; width: 100%; }
h1 { margin-bottom: .35em; }
.meta { margin-bottom: 1.6em; }
.meta b { color: #444; font-weight: 600; }

/* Summary tiles. Each one is a filter: the judged tile clears, the others select a result. */
.tiles { display: grid; grid-template-columns: repeat(auto-fit, minmax(118px, 1fr)); gap: 10px; margin-bottom: .6em; }
.tile { border: 1px solid #e3e3e3; border-top: 3px solid #ccc; padding: 12px 14px; background: #fff;
        text-align: left; font: inherit; cursor: pointer; transition: box-shadow .12s, transform .12s; }
.tile:hover { box-shadow: 0 2px 8px rgba(0,0,0,.10); transform: translateY(-1px); }
.tile[aria-pressed="true"] { border-color: #449841; box-shadow: inset 0 0 0 1px #449841; }
.tile .n { font-size: 1.85em; font-weight: 600; line-height: 1; font-variant-numeric: tabular-nums; color: #111; }
.tile .l { color: #888; font-size: .72em; margin-top: 5px; text-transform: uppercase; letter-spacing: .07em; }
.tile.judged { grid-column: span 2; border-top-color: #449841; }
.tile.judged .n { color: #449841; }
.tile.ok { border-top-color: #449841; } .tile.ok .n { color: #2f7a2c; }
.tile.bad { border-top-color: #c62828; } .tile.bad .n { color: #c62828; }
.tile.notrun { border-top-color: #e6a700; } .tile.notrun .n { color: #8a6a1f; }
.tile.skip { border-top-color: #bbb; } .tile.skip .n { color: #777; }
.tile.na { border-top-color: #e0e0e0; } .tile.na .n { color: #999; }
.tile.noproof { border-top-color: #b06a00; } .tile.noproof .n { color: #b06a00; }
.meter { height: 6px; background: #eee; margin: 0 0 2em; }
.meter i { display: block; height: 100%; background: #449841; }

/* Results. The nav palette is kept; on white the red and the amber are darkened, because
   #ff5555 on #fff is too pale to read in a printed report. */
.v { font-weight: 600; font-size: .82em; letter-spacing: .04em; white-space: nowrap; }
.v::before { display: inline-block; width: 1.1em; font-weight: 700; }
.v.PASS { color: #2f7a2c; } .v.PASS::before { content: "\2713"; }
.v.FAIL { color: #c62828; } .v.FAIL::before { content: "\2717"; }
.v.NOTRUN { color: #8a6a1f; } .v.NOTRUN::before { content: "\25CF"; }
.v.SKIP { color: #777; } .v.SKIP::before { content: "\2013"; }
.v.NA { color: #aaa; } .v.NA::before { content: "\00B7"; }
.v.NOPROOF { color: #b06a00; } .v.NOPROOF::before { content: "\003F"; }

/* Callouts */
.warn, .note { border-left: 3px solid #e6a700; background: #fdf8e8; padding: 11px 15px; margin: 0 0 1.2em; font-size: .86em; color: #5d4c14; }
.note { border-left-color: #449841; background: #f2f8f1; color: #2f5c2d; }

/* Anything that filters the table looks and behaves the same, wherever it sits. */
.chip { display: inline-flex; align-items: center; gap: 5px; font: inherit; font-size: .74em; font-weight: 600;
        padding: 3px 9px; border: 1px solid #ddd; background: #fafafa; color: #555; cursor: pointer;
        border-radius: 2px; white-space: nowrap; transition: background .12s, border-color .12s; }
.chip:hover { border-color: #449841; color: #2f7a2c; background: #f2f8f1; }
.chip[aria-pressed="true"] { background: #449841; border-color: #449841; color: #fff; }
.chip.ok { color: #2f7a2c; border-color: #bcdcba; background: #f2f8f1; }
.chip.bad { color: #c62828; border-color: #efbfbf; background: #fdf3f3; }
.chip.notrun { color: #8a6a1f; border-color: #e8d9a5; background: #fdf8e8; }
.chip.skip, .chip.na { color: #777; border-color: #ddd; background: #fafafa; }
.chip.noproof { color: #b06a00; border-color: #e2c08a; background: #fffaf0; }
.chip.ok[aria-pressed="true"] { background: #2f7a2c; border-color: #2f7a2c; color: #fff; }
.chip.bad[aria-pressed="true"] { background: #c62828; border-color: #c62828; color: #fff; }
.chip.notrun[aria-pressed="true"] { background: #8a6a1f; border-color: #8a6a1f; color: #fff; }
.chip.skip[aria-pressed="true"], .chip.na[aria-pressed="true"] { background: #777; border-color: #777; color: #fff; }
.chip.noproof[aria-pressed="true"] { background: #b06a00; border-color: #b06a00; color: #fff; }
.chip.pa { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-weight: 500; }

/* Cards for the test benches */
.benches { display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 12px; margin-bottom: 1em; }
.bench { border: 1px solid #e3e3e3; padding: 14px 16px; background: #fff; }
.bench h3 { font-size: .92em; font-weight: 600; margin: 0 0 .7em; }
.bench h3 .chip { font-size: .86em; }
.bench table { font-size: .82em; margin: 0; }
.bench td { padding: 3px 0; border: 0; }
.bench tr:last-child td { border: 0; }
.bench td:first-child { color: #888; width: 45%; }
.tags { margin-top: 10px; display: flex; flex-wrap: wrap; gap: 5px; }

/* Filter bar: what is active right now, and how to drop it. */
.filter { background: #fafafa; border: 1px solid #e6e6e6; padding: 10px 14px; margin-bottom: .5em;
          position: sticky; top: 56px; z-index: 3; }   /* clears the top bar */
.filter .row { display: flex; flex-wrap: wrap; gap: 8px 16px; align-items: center; }
.filter .row + .row { margin-top: 9px; padding-top: 9px; border-top: 1px dashed #e0e0e0; }
.filter label { display: inline-flex; align-items: center; gap: 6px; font-size: .84em; cursor: pointer; user-select: none; }
.filter input[type=checkbox] { accent-color: #449841; width: 15px; height: 15px; padding: 0; margin: 0; cursor: pointer; }
.filter .cnt { margin-left: auto; color: #888; font-size: .8em; font-variant-numeric: tabular-nums; }
#q { flex: 1; min-width: 190px; border: 1px solid #ccc; background: #fff; padding: 5px 10px; font-size: .86em; }
.active-label { color: #888; font-size: .78em; text-transform: uppercase; letter-spacing: .06em; }
.chip.drop::after { content: "\00D7"; font-weight: 700; opacity: .8; }
.chip.clear { border-color: #c9c9c9; }

/* Case table */
#tb td { vertical-align: top; }
.id { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .82em; white-space: nowrap; }
.ti { font-weight: 600; }
.de { color: #888; font-size: .88em; margin-top: 2px; }
.cl, .run { color: #888; font-size: .82em; }
.cl { max-width: 24em; }
.empty { color: #888; font-size: .88em; padding: 1.5em 0; }
.tw { overflow-x: auto; -webkit-overflow-scrolling: touch; }
tr.stage-row td:first-child { cursor: default; }

@media (max-width: 640px) {
  main { padding: 1.2em 1em; }
  body { padding-bottom: 0; }
  nav { position: static; padding: 0 12px; }
  .nav-status { margin-left: 0; width: 100%; padding-bottom: 10px; }
  .filter { top: 0; }
  footer { padding: 18px 1em; }
  .tiles { grid-template-columns: repeat(auto-fit, minmax(96px, 1fr)); }
  .tile { padding: 10px 11px; }
  .tile .l { font-size: .66em; letter-spacing: .02em; }
  .benches { grid-template-columns: 1fr; }
  .filter { position: static; }
  .attribute-table td:first-child { width: auto; white-space: normal; }
}
@media print {
  nav, .filter { display: none; }
  footer { background: none; color: #555; padding: 12px 0; }
  footer b { color: #111; }
  main { padding: 0; }
  .tile, .bench, table { break-inside: avoid; }
  a[href^="#"] { text-decoration: none; color: inherit; }
}
'@
Add-Line '</style>'
Add-Line '</head><body>'

# --- sidebar: the device's own navigation, with the sections of this report in it ---
Add-Line '<nav>'
Add-Line "<div class=""logo"">$logoSvg</div>"
Add-Line '<div class="menu-container">'
Add-Line '<a class="menu" href="#ueberblick">Überblick</a>'
if ($runStages.Count -gt 0) { Add-Line '<a class="menu" href="#stufen">Stufen</a>' }
if ($null -ne $runSettings) { Add-Line '<a class="menu" href="#lauf">Womit gelaufen</a>' }
if ($hasGaps) { Add-Line '<a class="menu" href="#luecken">Nicht beurteilt</a>' }
Add-Line '<a class="menu" href="#pruefstaende">Prüfstände</a>'
Add-Line '<a class="menu" href="#faelle">Alle Fälle</a>'
Add-Line '</div>'
Add-Line '<div class="nav-status">'
Add-Line "<span class=""nav-firm"">$(Convert-Html $author)</span>"
Add-Line "<span class=""prog-status""><span class=""prog-dot $dotClass""></span>$(Convert-Html $result)</span>"
Add-Line '</div>'
Add-Line '</nav>'

Add-Line '<main><div class="container">'
Add-Line "<h1 id=""ueberblick"">$(Convert-Html $Title)</h1>"
Add-Line ("<div class=""meta"">OpenKNX &middot; <b>{0}</b> &middot; erzeugt {1} &middot; jede Zahl und jede Blase unten filtert die Fallliste.</div>" -f `
          (Convert-Html $author), $generated)

# Every tile is a filter button. "beurteilt" clears the selection, the rest select their result.
Add-Line '<div class="tiles">'
Add-Line "<button type=""button"" class=""tile judged"" data-clear=""1""><div class=""n"">$judged / $tot</div><div class=""l"">beurteilt ($judgedPct %) &middot; alles zeigen</div></button>"
Add-Line "<button type=""button"" class=""tile ok"" data-v=""PASS"" aria-pressed=""false""><div class=""n"">$pass</div><div class=""l"">bestandene Fälle</div></button>"
Add-Line "<button type=""button"" class=""tile bad"" data-v=""FAIL"" aria-pressed=""false""><div class=""n"">$fail</div><div class=""l"">gescheiterte Fälle</div></button>"
Add-Line "<button type=""button"" class=""tile notrun"" data-v=""NOTRUN"" aria-pressed=""false""><div class=""n"">$notrun</div><div class=""l"">nicht ausgeführt</div></button>"
Add-Line "<button type=""button"" class=""tile skip"" data-v=""SKIP"" aria-pressed=""false""><div class=""n"">$skip</div><div class=""l"">übersprungen</div></button>"
Add-Line "<button type=""button"" class=""tile na"" data-v=""NA"" aria-pressed=""false""><div class=""n"">$na</div><div class=""l"">nicht zutreffend</div></button>"
Add-Line "<button type=""button"" class=""tile noproof"" data-v=""NOPROOF"" aria-pressed=""false""><div class=""n"">$noproof</div><div class=""l"">nichts bewiesen</div></button>"
Add-Line '</div>'
Add-Line "<div class=""meter""><i style=""width:$judgedPct%""></i></div>"

# A failed stage that produced no cases is invisible in the tiles above - and "0 gescheiterte Fälle"
# next to a red stage reads as "nothing is wrong", which is the opposite of what the run found.
$badStages = @($runStages | Where-Object { @('FAIL', 'ERROR', '?') -contains (Get-Field $_ 'Status' '?').ToUpper() })
if ($badStages.Count -gt 0) {
    $lines = @()
    foreach ($bs in $badStages) {
        $bn = Get-Field $bs 'Name' '?'
        $br = Get-Field $bs 'Reason' ''
        $hasCases = $false
        if ((Test-Prop $bs 'Counts') -and ($null -ne $bs.Counts)) { $hasCases = ([int](Get-Field $bs.Counts 'Fail' '0') -gt 0) }
        $note = if ($hasCases) { 'die Fälle stehen unten in der Liste' } else { 'urteilt nur auf Stufenebene - dazu gibt es keine Einzelfälle unten' }
        $lines += ("<b>{0}</b>: {1} &ndash; {2}" -f (Convert-Html $bn), (Convert-Html $br), $note)
    }
    Add-Line ("<div class=""warn"" style=""border-left-color:#c62828;background:#fdf3f3;color:#7a2020""><b>{0} Stufe(n) gescheitert.</b> Die Kacheln oben zählen <b>Fälle</b>; eine Stufe ohne Einzelfälle taucht dort nicht auf.<br>{1}<br><a href=""#stufen"">zur Stufentabelle</a></div>" -f `
              $badStages.Count, ($lines -join '<br>'))
}

if ($runStages.Count -gt 0) {
    Add-Line '<h2 id="stufen">Stufen dieses Laufs</h2>'
    Add-Line '<div class="tw"><table><thead><tr><th>Stufe</th><th>Status</th><th>Fälle</th><th>davon</th><th>Dauer</th><th>Anmerkung</th></tr></thead><tbody>'
    foreach ($st in $runStages) {
        $sname = Get-Field $st 'Name' '?'
        $sstat = (Get-Field $st 'Status' '?').ToUpper()
        $scls = switch ($sstat) { 'PASS' { 'PASS' } 'FAIL' { 'FAIL' } 'SKIPPED' { 'SKIP' } default { 'NA' } }
        # The stage summary is projected by Invoke-AllTests, which long carried no NotRun field, so the
        # four printed buckets added up to less than the stage's own Total and nothing said so. Total is
        # now shown, and the remainder is attributed rather than dropped.
        $stot = '-'; $scnt = '-'
        if ((Test-Prop $st 'Counts') -and ($null -ne $st.Counts)) {
            $cnP = [int](Get-Field $st.Counts 'Pass' '0'); $cnF = [int](Get-Field $st.Counts 'Fail' '0')
            $cnS = [int](Get-Field $st.Counts 'Skip' '0'); $cnA = [int](Get-Field $st.Counts 'NA' '0')
            $cnT = [int](Get-Field $st.Counts 'Total' '0')
            $cnR = [int](Get-Field $st.Counts 'NotRun' '0')
            if ($cnR -eq 0 -and $cnT -gt ($cnP + $cnF + $cnS + $cnA)) { $cnR = $cnT - ($cnP + $cnF + $cnS + $cnA) }
            $stot = "$cnT"
            $nb = [char]0x00A0   # a count and its word must not be split across lines
            $parts = @("$cnP${nb}bestanden")
            if ($cnF -gt 0) { $parts += "$cnF${nb}gescheitert" }
            if ($cnR -gt 0) { $parts += "$cnR${nb}nicht${nb}ausgeführt" }
            if ($cnS -gt 0) { $parts += "$cnS${nb}übersprungen" }
            if ($cnA -gt 0) { $parts += "$cnA${nb}n-a" }
            $scnt = $parts -join ' &middot; '
        }
        $ssec = if (Test-Prop $st 'Seconds') { "$([int][double](Get-Field $st 'Seconds' '0')) s" } else { '-' }
        Add-Line ("<tr class=""stage-row""><td><b>{0}</b></td><td><span class=""v {1}"">{2}</span></td><td class=""id"">{3}</td><td class=""de"">{4}</td><td class=""cl"">{5}</td><td class=""de"">{6}</td></tr>" -f `
                  (Convert-Html $sname), $scls, (Convert-Html $sstat), (Convert-Html $stot), $scnt, (Convert-Html $ssec), (Convert-Html (Get-Field $st 'Reason' '')))
    }
    Add-Line '</tbody></table></div>'
    Add-Line '<div class="meta">Eine Stufe ohne Fallzahlen urteilt nur auf Stufenebene - Legacy etwa meldet PASS oder FAIL, aber keine einzelnen Fälle.</div>'
}

if ($null -ne $runSettings) {
    Add-Line '<h2 id="lauf">Womit gelaufen</h2>'
    Add-Line '<div class="tw"><table class="attribute-table"><tbody>'
    $rowsCfg = [ordered]@{}
    if (Test-Prop $runSettings 'runId')   { $rowsCfg['Lauf'] = [string]$runSettings.runId }
    if (Test-Prop $runSettings 'profile') { $rowsCfg['Profil'] = $(if ([string]$runSettings.profile) { [string]$runSettings.profile } else { '(keins - Werte einzeln erfragt)' }) }
    if ((Test-Prop $runSettings 'device') -and ($null -ne $runSettings.device)) {
        foreach ($pr in $runSettings.device.PSObject.Properties) { if ("$($pr.Value)") { $rowsCfg["Gerät: $($pr.Name)"] = [string]$pr.Value } }
    }
    if ((Test-Prop $runSettings 'rig') -and ($null -ne $runSettings.rig)) {
        foreach ($pr in $runSettings.rig.PSObject.Properties) { if ("$($pr.Value)") { $rowsCfg["Aufbau: $($pr.Name)"] = [string]$pr.Value } }
    }
    if ((Test-Prop $runSettings 'flags') -and ($null -ne $runSettings.flags)) {
        foreach ($pr in $runSettings.flags.PSObject.Properties) { $rowsCfg["Schalter: $($pr.Name)"] = [string]$pr.Value }
    }
    if ((Test-Prop $runSettings 'repo') -and ($null -ne $runSettings.repo)) {
        $rowsCfg['Stand'] = ("{0} ({1})" -f (Get-Field $runSettings.repo 'commit' '?'), (Get-Field $runSettings.repo 'branch' '?'))
    }
    foreach ($k in $rowsCfg.Keys) {
        $val = [string]$rowsCfg[$k]
        # An individual address in a settings value is a filter: the reader wants "show me 5.0.8".
        $cells = @()
        foreach ($tok in ($val -split '[,;]+')) {
            $t = $tok.Trim()
            if (-not $t) { continue }
            if ($t -match '^\d+\.\d+\.\d+$' -and $paSet.Contains($t)) {
                $cells += ("<button type=""button"" class=""chip pa"" data-pa=""{0}"" aria-pressed=""false"">{0}</button>" -f (Convert-Html $t))
            }
            else { $cells += (Convert-Html $t) }
        }
        Add-Line ("<tr><td>{0}</td><td>{1}</td></tr>" -f (Convert-Html $k), ($cells -join ' '))
    }
    Add-Line '</tbody></table></div>'
}

if ($hasGaps) {
    Add-Line '<h2 id="luecken">Was nicht beurteilt wurde</h2>'
    Add-Line '<div class="warn"><b>Lücken dieses Laufs, nicht des Geräts.</b> Ein Fall hier sagt nichts über das Gerät aus - er sagt, dass dieser Lauf ihn nicht beurteilen konnte.</div>'
    if ($droppedAll.Count -gt 0) {
        Add-Line '<div class="tw"><table><thead><tr><th>Suite</th><th>Lauf</th><th>Warum sie nicht startete</th></tr></thead><tbody>'
        foreach ($dr in $droppedAll) {
            Add-Line ("<tr><td><b>{0}</b></td><td>{1}</td><td>{2}</td></tr>" -f (Convert-Html $dr.Suite), (Convert-Html $dr.Run), (Convert-Html $dr.Reason))
        }
        Add-Line '</tbody></table></div>'
    }
    if ($notRunRows.Count -gt 0) {
        Add-Line '<div class="tw"><table><thead><tr><th>Fehlendes Argument</th><th>Fälle</th><th>Was sie beurteilt hätten</th></tr></thead><tbody>'
        foreach ($g in ($notRunRows | Group-Object -Property Missing | Sort-Object Name)) {
            $ids = (@($g.Group | ForEach-Object { $_.Id }) -join ', ')
            Add-Line ("<tr><td><code>{0}</code></td><td>{1} &middot; <span class=""id"">{2}</span></td><td>{3}</td></tr>" -f `
                      (Convert-Html $g.Name), $g.Count, (Convert-Html $ids), (Convert-Html $g.Group[0].Reason))
        }
        Add-Line '</tbody></table></div>'
    }
}

Add-Line '<h2 id="pruefstaende">Prüfstände</h2>'
Add-Line "<div class=""meta"">$($order.Count) &middot; je Fall zählt das jüngste Urteil, nicht der jüngste Lauf. Name und Zahlen sind anklickbar.</div>"
Add-Line '<div class="benches">'
foreach ($k in $order) {
    $d = $meta[$k]; $s = $counts[$k]
    $lbl = [string]$d._label
    Add-Line '<div class="bench">'
    Add-Line ("<h3><button type=""button"" class=""chip"" data-bench=""{0}"" aria-pressed=""false"">{1}</button></h3>" -f (Convert-Html $lbl), (Convert-Html $lbl))
    Add-Line '<table><tbody>'
    Add-Line "<tr><td>letzter Lauf</td><td>$(Convert-Html ($d._started.ToString('yyyy-MM-dd HH:mm')))</td></tr>"
    $bdut = if (Test-Prop $d 'bdut') { [string]$d.bdut } else { '-' }
    Add-Line "<tr><td>Gerät</td><td>$(Convert-Html $bdut)</td></tr>"
    if ((Test-Prop $d 'environment') -and ($null -ne $d.environment)) {
      foreach ($p in $d.environment.PSObject.Properties) {
        Add-Line "<tr><td>$(Convert-Html $p.Name)</td><td>$(Convert-Html ([string]$p.Value))</td></tr>"
      }
    }
    Add-Line '</tbody></table>'
    # Each badge selects this bench AND that result - "KNX-Device, 92 bestanden" in one click.
    Add-Line '<div class="tags">'
    foreach ($pair in @(@('ok','PASS',$s.Pass,'bestanden'), @('bad','FAIL',$s.Fail,'gescheitert'),
                        @('notrun','NOTRUN',$s.NotRun,'nicht ausgeführt'), @('skip','SKIP',$s.Skip,'übersprungen'),
                        @('na','NA',$s.NA,'n/a'), @('noproof','NOPROOF',$s.NoProof,'nichts bewiesen'))) {
        $cls = $pair[0]; $vv = $pair[1]; $nn = [int]$pair[2]; $word = $pair[3]
        if ($nn -le 0 -and $vv -ne 'PASS') { continue }
        Add-Line ("<button type=""button"" class=""chip {0}"" data-bench=""{1}"" data-v=""{2}"" aria-pressed=""false"">{3} {4}</button>" -f `
                  $cls, (Convert-Html $lbl), $vv, $nn, $word)
    }
    Add-Line '</div></div>'
}
Add-Line '</div>'

Add-Line '<h2 id="faelle">Alle Fälle</h2>'
Add-Line '<div class="filter">'
Add-Line '<div class="row" id="active"><span class="active-label">Filter</span><span id="activeChips"></span><span class="cnt" id="cnt"></span></div>'
Add-Line '<div class="row">'
Add-Line '<label><input type="checkbox" class="fb" data-f="PASS" checked> bestanden</label>'
Add-Line '<label><input type="checkbox" class="fb" data-f="FAIL" checked> gescheitert</label>'
Add-Line '<label><input type="checkbox" class="fb" data-f="NOTRUN" checked> nicht ausgeführt</label>'
Add-Line '<label><input type="checkbox" class="fb" data-f="SKIP" checked> übersprungen</label>'
Add-Line '<label><input type="checkbox" class="fb" data-f="NA" checked> n/a</label>'
# Without its own box, resultOn() has no key for this class, apply() reads undefined and every
# NO-PROOF row stays hidden whatever the tiles say.
Add-Line '<label><input type="checkbox" class="fb" data-f="NOPROOF" checked> nichts bewiesen</label>'
Add-Line '<input id="q" type="search" placeholder="suchen - Id, Titel, Klausel, Grund, Lauf">'
Add-Line '</div>'
if ($paSet.Count -gt 0) {
    Add-Line '<div class="row"><span class="active-label">Gerät</span>'
    foreach ($pa in ($paSet | Sort-Object)) {
        Add-Line ("<button type=""button"" class=""chip pa"" data-pa=""{0}"" aria-pressed=""false"">{0}</button>" -f (Convert-Html $pa))
    }
    Add-Line '</div>'
}
if ($suiteSet.Count -gt 0 -and $suiteSet.Count -le 24) {
    Add-Line '<div class="row"><span class="active-label">Suite</span>'
    foreach ($su in ($suiteSet | Sort-Object)) {
        Add-Line ("<button type=""button"" class=""chip"" data-suite=""{0}"" aria-pressed=""false"">{1}</button>" -f (Convert-Html $su), (Convert-Html $su))
    }
    Add-Line '</div>'
}
Add-Line '</div>'
Add-Line '<div class="tw"><table><thead><tr><th>Id</th><th>Fall</th><th>Suite</th><th>Klausel</th><th>Prüfstand</th><th>Ergebnis</th></tr></thead><tbody id="tb">'

foreach ($k in $order) {
    foreach ($v in ($byProduct[$k] | Sort-Object { [string]$_.Case.Id })) {
        $c = $v.Case
        # Only the known results reach a class name or a filter attribute; anything else a run file
        # carries becomes NA rather than being pasted into the markup unescaped.
        $res = Get-CaseResult $c
        # The class name and the filter attribute cannot carry a hyphen, the label the reader sees can.
        # Taking $shown after the NOT-RUN conversion printed "NOTRUN" while NO-PROOF kept its hyphen.
        $shown = $res
        if ($res -eq 'NOT-RUN') { $res = 'NOTRUN' }
        if ($res -eq 'NO-PROOF') { $res = 'NOPROOF' }
        if (@('PASS', 'FAIL', 'SKIP', 'NOTRUN', 'NOPROOF') -notcontains $res) { $res = 'NA'; if ($shown -ne 'N-A') { $shown = '?'; $unreadable++ } }
        $notes = ''
        if ((Test-Prop $c 'Notes') -and ($null -ne $c.Notes)) { $notes = (@($c.Notes) -join ' | ') }
        $detail = @((Get-Field $c 'Reason'), $notes) | Where-Object { $_ }
        $de = ($detail -join ' -- ')
        $id = Get-Field $c 'Id'
        $title = Get-Field $c 'Title'
        $clause = Get-Clause $c
        $suite = Get-Field $c 'Suite'
        $stamp = $v.Started.ToString('yyyy-MM-dd HH:mm')
        $label = [string]$meta[$k]._label
        $pa = ''
        if ($id -match '\s(\d+\.\d+\.\d+)\s*$') { $pa = $Matches[1] }
        elseif ($suite -match '\s(\d+\.\d+\.\d+)\s*$') { $pa = $Matches[1] }
        $q = (@($id, $title, $clause, $de, $label, $suite, $stamp) -join ' ').ToLower()
        Add-Line ("<tr data-r=""{0}"" data-bench=""{1}"" data-pa=""{2}"" data-suite=""{3}"" data-q=""{4}"">" -f `
                  $res, (Convert-Html $label), (Convert-Html $pa), (Convert-Html $suite), (Convert-Html $q))
        Add-Line "<td class=""id"">$(Convert-Html $id)</td>"
        $deHtml = ''
        if ($de) { $deHtml = '<div class="de">' + (Convert-Html $de) + '</div>' }
        Add-Line ("<td><div class=""ti"">" + (Convert-Html $title) + "</div>" + $deHtml + "</td>")
        Add-Line "<td class=""cl"">$(Convert-Html $suite)</td>"
        Add-Line "<td class=""cl"">$(Convert-Html $clause)</td>"
        Add-Line "<td class=""run"">$(Convert-Html $label)<div class=""de"">$(Convert-Html $stamp)</div></td>"
        Add-Line "<td><span class=""v $res"">$(Convert-Html $shown)</span></td></tr>"
    }
}

Add-Line '</tbody></table></div>'
Add-Line '<div class="empty" id="none" style="display:none">Kein Fall passt zu dieser Auswahl.</div>'
Add-Line '</div></main>'

Add-Line '<footer>'
Add-Line ("<div class=""col"">&copy; {0} OpenKNX<br><b>{1}</b></div>" -f $year, (Convert-Html $author))
$f2 = @()
if ($runIdText) { $f2 += ("Lauf <b>{0}</b>" -f (Convert-Html $runIdText)) }
$f2 += ("erzeugt {0}" -f $generated)
$f2 += ("{0} Prüfstände &middot; {1} Fälle &middot; {2} beurteilt" -f $order.Count, $tot, $judged)
Add-Line ("<div class=""col"">{0}</div>" -f ($f2 -join '<br>'))
$f3 = @("Ergebnis: <b>$(Convert-Html $result)</b>")
if ($runStages.Count -gt 0) { $f3 += ("{0} Stufen &middot; {1} übersprungen" -f $runStages.Count, $stageSkip) }
if (($null -ne $runSettings) -and (Test-Prop $runSettings 'repo') -and ($null -ne $runSettings.repo)) {
    $f3 += ("Stand {0} ({1})" -f (Get-Field $runSettings.repo 'commit' '?'), (Get-Field $runSettings.repo 'branch' '?'))
}
Add-Line ("<div class=""col"">{0}</div>" -f ($f3 -join '<br>'))
Add-Line '<div class="col">erzeugt von scripts/Test/Tools/New-TestReport.ps1<br>Stil und Logo aus lib/OFM-Network/web/assets<br>Jede Zeile ist die Antwort eines Gerätes, kein Redaktionsstand.</div>'
Add-Line '</footer>'

Add-Line @'
<script>
(function(){
  var rows=[].slice.call(document.querySelectorAll('#tb tr'));
  var boxes=[].slice.call(document.querySelectorAll('.fb'));
  var q=document.getElementById('q'), cnt=document.getElementById('cnt'), none=document.getElementById('none');
  var activeChips=document.getElementById('activeChips');
  // One selection, many places to set it: the tiles, the bench badges, the device and suite chips
  // and the checkboxes all write into this and then everything re-renders from it.
  var sel={bench:null, pa:null, suite:null};

  function resultOn(){
    var on={}; boxes.forEach(function(b){on[b.getAttribute('data-f')]=b.checked;}); return on;
  }
  function apply(){
    var on=resultOn(), t=(q.value||'').toLowerCase().trim(), n=0;
    rows.forEach(function(r){
      var show = on[r.getAttribute('data-r')]
        && (!sel.bench || r.getAttribute('data-bench')===sel.bench)
        && (!sel.pa    || r.getAttribute('data-pa')===sel.pa)
        && (!sel.suite || r.getAttribute('data-suite')===sel.suite)
        && (!t || r.getAttribute('data-q').indexOf(t)>=0);
      r.style.display=show?'':'none'; if(show)n++;
    });
    cnt.textContent=n+' von '+rows.length;
    none.style.display=n?'none':'';
    paint(n);
  }
  function paint(n){
    // Pressed state everywhere, and the active selection as chips one can drop again.
    document.querySelectorAll('[data-bench]').forEach(function(el){
      if(el.tagName!=='BUTTON') return;
      var v=el.getAttribute('data-v');
      var hit = sel.bench===el.getAttribute('data-bench') && (!v || onlyResult()===v);
      el.setAttribute('aria-pressed', String(!!hit));
    });
    document.querySelectorAll('button[data-pa]').forEach(function(el){
      el.setAttribute('aria-pressed', String(sel.pa===el.getAttribute('data-pa')));
    });
    document.querySelectorAll('button[data-suite]').forEach(function(el){
      el.setAttribute('aria-pressed', String(sel.suite===el.getAttribute('data-suite')));
    });
    document.querySelectorAll('.tile[data-v]').forEach(function(el){
      el.setAttribute('aria-pressed', String(onlyResult()===el.getAttribute('data-v')));
    });
    var html='';
    if(sel.bench) html+='<button type="button" class="chip drop" data-drop="bench">'+esc(sel.bench)+' </button> ';
    if(sel.pa)    html+='<button type="button" class="chip drop pa" data-drop="pa">'+esc(sel.pa)+' </button> ';
    if(sel.suite) html+='<button type="button" class="chip drop" data-drop="suite">'+esc(sel.suite)+' </button> ';
    var ov=onlyResult();
    if(ov) html+='<button type="button" class="chip drop" data-drop="v">'+esc(ov)+' </button> ';
    if(!html) html='<span class="de" style="margin:0">keiner - alle '+rows.length+' Fälle</span>';
    else html+='<button type="button" class="chip clear" data-drop="all">alles zurücksetzen</button>';
    activeChips.innerHTML=html;
  }
  function onlyResult(){
    var on=boxes.filter(function(b){return b.checked;});
    return on.length===1 ? on[0].getAttribute('data-f') : null;
  }
  function setResult(v){ boxes.forEach(function(b){ b.checked = !v || b.getAttribute('data-f')===v; }); }
  function esc(s){ return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); }
  function toggle(key,val){ sel[key] = (sel[key]===val) ? null : val; }

  document.addEventListener('click', function(ev){
    var el=ev.target.closest('button'); if(!el) return;
    if(el.hasAttribute('data-clear')){ sel={bench:null,pa:null,suite:null}; setResult(null); q.value=''; apply(); jump(); return; }
    var drop=el.getAttribute('data-drop');
    if(drop){
      if(drop==='all'){ sel={bench:null,pa:null,suite:null}; setResult(null); q.value=''; }
      else if(drop==='v'){ setResult(null); }
      else { sel[drop]=null; }
      apply(); return;
    }
    var bench=el.getAttribute('data-bench'), pa=el.getAttribute('data-pa'),
        suite=el.getAttribute('data-suite'), v=el.getAttribute('data-v');
    if(bench===null && pa===null && suite===null && v===null) return;
    ev.preventDefault();
    if(bench!==null){
      // A badge carries a result too: pressing it again clears both.
      var already = sel.bench===bench && (!v || onlyResult()===v);
      if(already){ sel.bench=null; setResult(null); }
      else { sel.bench=bench; setResult(v); }
    }
    else if(pa!==null){ toggle('pa',pa); }
    else if(suite!==null){ toggle('suite',suite); }
    else if(v!==null){ setResult(onlyResult()===v ? null : v); }
    apply(); jump();
  });

  function jump(){
    var h=document.getElementById('faelle');
    if(h && h.getBoundingClientRect().top<0) h.scrollIntoView({behavior:'smooth', block:'start'});
  }

  boxes.forEach(function(b){b.addEventListener('change',apply);});
  q.addEventListener('input',apply);
  apply();

  // Mark the section the reader is in, the way the device web interface marks the open page.
  var links=[].slice.call(document.querySelectorAll('nav a.menu'));
  var targets=links.map(function(a){return document.querySelector(a.getAttribute('href'));});
  function spy(){
    var best=0;
    targets.forEach(function(el,i){ if(el && el.getBoundingClientRect().top<=90) best=i; });
    links.forEach(function(a,i){ a.classList.toggle('active', i===best); });
  }
  window.addEventListener('scroll',spy,{passive:true}); spy();
})();
</script>
</body></html>
'@

$outDir = Split-Path -Parent $OutFile
if ($outDir -and -not (Test-Path $outDir)) { [void](New-Item -ItemType Directory -Path $outDir -Force) }
Set-Content -Path $OutFile -Value $sb.ToString() -Encoding UTF8

if ($unreadable -gt 0) { Write-Host "  $unreadable Fall/Fälle ohne Ergebnisfeld - im Bericht als '?' ausgewiesen" -ForegroundColor Yellow }
Write-Host "  $($order.Count) Läufe, $tot Fälle -> $OutFile"
Write-Host "  beurteilt $judged/$tot  bestanden $pass  gescheitert $fail  nicht ausgeführt $notrun  übersprungen $skip  n/a $na  nichts bewiesen $noproof"
Write-Host ''
