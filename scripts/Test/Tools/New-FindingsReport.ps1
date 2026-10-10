#!/usr/bin/env pwsh
# Open $
# +----+  New-FindingsReport
# $ KNX   2026 OpenKNX - Erkan Colak
#
# FILEPATH: scripts/Test/Tools/New-FindingsReport.ps1

<#
.SYNOPSIS
    Builds the interactive findings report (HTML) from doc/knx-findings-index.md.

.DESCRIPTION
    The register is the source of truth and stays a Markdown table. This generator reads it and renders
    one self-contained page: counters, filter chips, search, and a table per subsystem.

    Three columns are DERIVED from the register text, each by a fixed rule that the page states in its
    footer, so no entry is classified by hand:

      Stand      FIXED without an open follow-up = gefixt; CONFIRMED / NARROWED / PARTLY FIXED / RECORDED /
                 DEFERRED and a FIXED with "follow-up OPEN|UNVERIFIED" = verifiziert, offen; REFUTED = widerlegt;
                 UNPROVEN = nicht auffindbar; OPEN = ungeprueft; DUPLICATE = Dublette; section 0 = Pruefmittel;
                 the Data Secure and RF sections = schlafend.
      Pfad       from the register's Reach column: BUS = TP, LAN = IP, Router / HOSTILE / BUS+LAN = beide,
                 ETS = ETS, BUILD / DORMANT / "hardening only" = nur Build. Datapoint rows name a product class
                 instead of a transport and become "Anwendung, DPT".
      Nachweis   what the status text names: HARDWARE-VERIFIED = measured on the device, a suite case id
                 (D-, H-, P-, X-) = on the device through a suite, a host case id (HB-, HD-, HU-, HS-, HT-) =
                 host stack, a spec citation (03_xx_xx, 08_TSS.., "p. NN") = spec clause.

    The release band above the table reads the newest report of each suite from scripts/Test/Reports, so its
    numbers come from the run artifacts, not from the register.

.PARAMETER Path
    The register. Default: doc/knx-findings-index.md of this repository.

.PARAMETER OutFile
    Where to write the HTML. Default: doc/findings-report.html.

.EXAMPLE
    pwsh Tools/New-FindingsReport.ps1
    Rebuilds doc/findings-report.html from the register.

.NOTES
    PowerShell 5.1 compatible, ASCII source, no modules, no network at runtime.
#>
[CmdletBinding()]
param(
    [string]$Path = '',
    [string]$OutFile = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $here))
if (-not $Path) { $Path = Join-Path $repo 'doc/knx-findings-index.md' }
if (-not $OutFile) { $OutFile = Join-Path $repo 'doc/findings-report.html' }
if (-not (Test-Path $Path)) { throw "register not found: $Path" }

$lines = Get-Content -Path $Path -Encoding UTF8

# ---- parse -------------------------------------------------------------------------------------
$sections = [ordered]@{}   # key -> title
$secNum = @{}              # key -> printed number
$rows = New-Object System.Collections.Generic.List[object]
$secKey = $null
$seenNums = @{}

foreach ($line in $lines) {
    if ($line -match '^##\s+(\d+)\s+[^\w]*\s*(.*)$') {
        $num = $Matches[1]
        $title = $Matches[2].Trim()
        $key = $num
        if ($seenNums.ContainsKey($num)) { $key = $num + 'b' }
        $seenNums[$num] = $true
        $sections[$key] = $title
        $secNum[$key] = $num
        $secKey = $key
        continue
    }
    if (-not $secKey) { continue }
    if ($line -notmatch '^\|') { continue }
    if ($line -match '^\|\s*[-: ]+\|') { continue }               # separator
    $cells = @(($line.Trim() -replace '^\|', '' -replace '\|$', '') -split '(?<!\\)\|' | ForEach-Object { $_.Trim() })
    if ($cells.Count -lt 3) { continue }
    if ($cells[0] -notmatch '^(T\.)?\d+(\.\d+)?$') { continue }   # header row or a summary line
    $reach = if ($cells.Count -ge 5) { $cells[4] } else { '—' }
    $rows.Add([pscustomobject]@{
        sec    = $secKey
        id     = $cells[0]
        desc   = $cells[1]
        anchor = $cells[2]
        status = if ($cells.Count -ge 4) { $cells[3] } else { '' }
        reach  = $reach
    })
}

# ---- classify ----------------------------------------------------------------------------------
function Get-Bucket {
    <#
    .SYNOPSIS
        The status bucket of one row, by the rule the page states.
    #>
    param([string]$Section, [string]$Status)
    if ($Section -eq '0') { return 'tool' }
    $s = ($Status -replace '\*', '')
    if ($s -match '^(FIXED|ALREADY CLOSED|UNDERFLOW FIXED)') {
        if ($Status -match 'follow-up (OPEN|UNVERIFIED)') { return 'pending' }
        return 'fixed'
    }
    if ($s -match '^UNPROVEN' -or $s -match 'could not be relocated') { return 'unproven' }
    if ($s -match '^(REFUTED|NOT A DEFECT)' -or $s -match '^\w+ REFUTED') { return 'refuted' }
    if ($s -match '^(CONFIRMED|NARROWED|PARTLY FIXED|RECORDED|REVERTED)') { return 'pending' }
    if ($s -match '^OPEN') { return 'open' }
    if ($s -match '^DUPLICATE') { return 'duplicate' }
    return 'pending'
}

function Get-Path {
    <#
    .SYNOPSIS
        Which side of the device a finding can be reached from, derived from the Reach column.

    .DESCRIPTION
        Datapoint findings name a product class instead of a transport, because a DPT encodes wrong
        wherever it is used - they get their own value rather than a made-up transport.
    #>
    param([string]$Section, [string]$Reach)
    $r = $Reach.ToUpper()
    if ($r -match 'BUILD|DORMANT|HARDENING ONLY') { return 'build' }
    if ($Section -eq '13') { return 'app' }
    if ($r -match 'BUS' -and $r -match 'LAN') { return 'both' }
    if ($r -match 'ROUTER|HOSTILE') { return 'both' }
    if ($r -match 'LAN') { return 'ip' }
    if ($r -match 'BUS') { return 'tp' }
    if ($r -match 'ETS|PRODUCT') { return 'ets' }
    if ($r -match 'OTA') { return 'ip' }
    return 'none'
}

function Get-Evidence {
    <#
    .SYNOPSIS
        What the status text names as the proof: hardware, host stack, suite case, spec clause.
    #>
    param([string]$Status)
    $e = @()
    if ($Status -match 'HARDWARE-VERIFIED|BUSMONITOR-VERIFIED|HW-verified|HW-VERIFIED|hardware') { $e += 'hw' }
    if ($Status -match '\bH[BDUST]-\d') { $e += 'host' }
    if ($Status -match '\b[DHKPX]-\d+(\.\d+)*|\bX-[A-Z]') { $e += 'suite' }
    if ($Status -match '0[38]_\d{2}_\d{2}|TSS[HJKG]|\bp\.\s?\d') { $e += 'spec' }
    if ($e.Count -eq 0) { $e += 'none' }
    # No comma operator here: "return , (...)" wraps a MULTI-element result in a further array, which the
    # @() at the call site then keeps, so a row with two proofs rendered "undefined". Same trap as T.27.
    return ($e | Sort-Object -Unique)
}

function Get-Fingerprint {
    <#
    .SYNOPSIS
        A short fingerprint of an English row, so a translation can be spotted as outdated.
    #>
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA1]::Create()
    $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
    $sha.Dispose()
    return (-join (($hash | Select-Object -First 5) | ForEach-Object { $_.ToString('x2') }))
}

function Get-Todo {
    <#
    .SYNOPSIS
        What a row still needs, taken from what its own status text says is missing.

    .DESCRIPTION
        A finding that is fixed, refuted, a duplicate, a tool defect or dormant needs nothing. For the rest
        the status text decides, in this order: it asks for a decision, it asks for a measurement or a trace,
        it names something still missing in the code, it closes itself (recorded, withdrawn, unreachable,
        no live defect), or - when only a different build reaches it - it rests.
    #>
    param([string]$Bucket, [string]$Status, [string]$PathKind)
    if ($Bucket -eq 'fixed' -or $Bucket -eq 'refuted' -or $Bucket -eq 'duplicate' -or $Bucket -eq 'tool' -or $Bucket -eq 'dormant') { return 'none' }
    if ($Status -match 'decision pending|awaiting decision|needs a decision|not flipped silently') { return 'decision' }
    if ($Status -match 'needs a bus measurement|needs a trace|needs the original trace|needs a diverged|not traced|needs hardware verification|would settle it|needs a capture') { return 'measure' }
    if ($Status -match 'still not counted|no code change made|being unimplemented|still exceeds|needs a dirty flag|needs the hook|Making it conformant needs|reachability depends|blocks raising|Fixing it means') { return 'work' }
    if ($Status -match 'recorded only|RECORDED, no change|decision: no change|deliberately not fixed|withdrawn|unreachable|\bdead\b|refuted|not a defect|no live race|cannot fail|no real client|Guard kept|not touched|no reachable path|Covered by the new conformance case|folds into|documented') { return 'none' }
    if ($PathKind -eq 'build') { return 'rest' }
    return 'work'
}

$data = @()
foreach ($r in $rows) {
    $isDormant = ($r.sec -eq '15') -or ($r.sec -like '16b*')
    $b = Get-Bucket -Section $r.sec -Status $r.status
    if ($isDormant) { $b = 'dormant' }
    $data += [pscustomobject]@{
        sec    = $r.sec
        id     = $r.id
        desc   = $r.desc
        anchor = $r.anchor
        status = $r.status
        reach  = $r.reach
        b      = $b
        p      = (Get-Path -Section $r.sec -Reach $r.reach)
        e      = @(Get-Evidence -Status $r.status)
        t      = 'none'
        en     = $false
        stale  = $false
    }
}

foreach ($d in $data) { $d.t = Get-Todo -Bucket $d.b -Status $d.status -PathKind $d.p }

# ---- German side-car: classification stays on the English source, only the display is swapped ----
$dePath = Join-Path $repo 'doc/knx-findings-index.de.json'
$deMissing = 0
$deStale = 0
if (Test-Path $dePath) {
    $de = Get-Content -Path $dePath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($d in $data) {
        $key = $d.sec + '/' + $d.id
        $tr = $null
        if ($de.rows.PSObject.Properties.Match($key).Count) { $tr = $de.rows.$key }
        if ($tr -and $tr.desc) {
            $fp = Get-Fingerprint ($d.desc + "`n" + $d.status)
            if ($tr.src -and $tr.src -ne $fp) { $d.stale = $true; $deStale++ }
            $d.desc = $tr.desc
            $d.status = $tr.status
        }
        else { $d.en = $true; $deMissing++ }
    }
    foreach ($k in @($sections.Keys)) {
        if ($de.sections.PSObject.Properties.Match($k).Count) { $sections[$k] = $de.sections.$k }
    }
}
else { $deMissing = $data.Count }

$order = @($sections.Keys | Where-Object { $_ -ne '0' }) + @('0')
$counts = @{}
foreach ($k in @('fixed', 'pending', 'refuted', 'unproven', 'open', 'duplicate', 'tool', 'dormant')) {
    $counts[$k] = @($data | Where-Object { $_.b -eq $k }).Count
}
$todo = @{}
foreach ($k in @('none', 'decision', 'measure', 'work', 'rest')) { $todo[$k] = @($data | Where-Object { $_.t -eq $k }).Count }
$green = $todo['none']
$toDoAll = $todo['decision'] + $todo['measure'] + $todo['work']
$onDevice = @($data | Where-Object { ($_.e -contains 'hw') -or ($_.e -contains 'suite') }).Count
$openRelease = @($data | Where-Object { ($_.b -eq 'pending' -or $_.b -eq 'open') -and $_.p -ne 'none' -and $_.p -ne 'build' }).Count
$total = @($data | Where-Object { $_.b -ne 'tool' -and $_.b -ne 'dormant' }).Count

# ---- the proof runs, read from the newest report artifact of each suite ---------------------------
$runs = @()
$repDir = Join-Path $repo 'scripts/Test/Reports'
if (Test-Path $repDir) {
    # Keyed by suite AND device. Keying on the file name alone let a run against one device hide the
    # newest run against another: a feature run aimed at the router without -ExpectRouting judges it
    # against the interface profile and files itself as "IP-Interface-features", where it then shadowed
    # the real interface run and put its two role errors in this table (2026-09-21).
    $read = @()
    foreach ($f in (Get-ChildItem -Path $repDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try { $j = Get-Content -Path $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if (-not $j.PSObject.Properties.Match('summary').Count) { continue }
        $read += [pscustomobject]@{
            suite = ($f.BaseName -replace '_\d{8}-\d{6}$', '')
            # The hardening runs name the device 'target', the others 'bdut'. Reading the missing one
            # threw the whole generator under Set-StrictMode instead of rendering the page.
            bdut  = $(if ($j.PSObject.Properties.Match('bdut').Count) { [string]$j.bdut }
                      elseif ($j.PSObject.Properties.Match('target').Count) { [string]$j.target }
                      else { '' })
            when  = if ($j.finished) { ([datetime]$j.finished) } else { $f.LastWriteTime }
            json  = $j
        }
    }
    foreach ($g in ($read | Group-Object { $_.suite + '|' + $_.bdut })) {
        $newest = $g.Group | Sort-Object when -Descending | Select-Object -First 1
        $j = $newest.json
        $runs += [pscustomobject]@{
            name = $newest.suite; bdut = $newest.bdut; when = $newest.when.ToString('yyyy-MM-dd HH:mm')
            pass = $j.summary.Pass; fail = $j.summary.Fail; total = $j.summary.Total
            skip = $j.summary.Skip; na = $j.summary.NA
            # Older run files predate the class, so read it defensively rather than aborting on them.
            noproof = $(if ($null -ne $j.summary.PSObject.Properties['NoProof']) { $j.summary.NoProof } else { 0 })
        }
    }
    $runs = @($runs | Sort-Object name, bdut)
}

$payload = [pscustomobject]@{
    sections = $sections
    order    = $order
    num      = $secNum
    rows     = $data
} | ConvertTo-Json -Depth 6 -Compress

$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
$share = @{}
foreach ($k in @('fixed', 'pending', 'refuted', 'unproven', 'open', 'duplicate')) {
    $share[$k] = if ($total -gt 0) { [Math]::Round(100.0 * $counts[$k] / $total, 2) } else { 0 }
}

# ---- render ------------------------------------------------------------------------------------
$style = @'
:root{--paper:#F7F8FA;--card:#FFFFFF;--ink:#16191F;--ink-soft:#5A6270;--ink-faint:#8A93A3;--rule:#DDE1E8;--rule-soft:#EBEEF3;
 --accent:#1F5F5B;--accent-soft:#E4EFEE;--ok:#2F7A45;--ok-bg:#E6F2EA;--muted:#7A8496;--muted-bg:#EDEFF3;--warn:#9A6A12;
 --warn-bg:#FBF1DE;--open:#3E4A5C;--open-bg:#EDF0F5;--shadow:0 1px 2px rgba(16,20,30,.05),0 6px 20px -12px rgba(16,20,30,.18)}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){--paper:#0F1218;--card:#161A22;--ink:#E7EAF0;--ink-soft:#A3ACBC;
 --ink-faint:#6F7A8C;--rule:#252B36;--rule-soft:#1C212A;--accent:#5FBDB2;--accent-soft:#16282A;--ok:#6FCB8B;--ok-bg:#13251A;
 --muted:#8892A3;--muted-bg:#1B202A;--warn:#D9A648;--warn-bg:#2A2114;--open:#9AA6BA;--open-bg:#1A1F29;
 --shadow:0 1px 2px rgba(0,0,0,.4),0 8px 24px -14px rgba(0,0,0,.7)}}
:root[data-theme="dark"]{--paper:#0F1218;--card:#161A22;--ink:#E7EAF0;--ink-soft:#A3ACBC;
 --ink-faint:#6F7A8C;--rule:#252B36;--rule-soft:#1C212A;--accent:#5FBDB2;--accent-soft:#16282A;--ok:#6FCB8B;--ok-bg:#13251A;
 --muted:#8892A3;--muted-bg:#1B202A;--warn:#D9A648;--warn-bg:#2A2114;--open:#9AA6BA;--open-bg:#1A1F29;
 --shadow:0 1px 2px rgba(0,0,0,.4),0 8px 24px -14px rgba(0,0,0,.7)}
*{box-sizing:border-box}
body{margin:0;background:var(--paper);color:var(--ink);font:15px/1.5 "IBM Plex Sans",-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased}
.wrap{max-width:1240px;margin:0 auto;padding:clamp(24px,4vw,56px) clamp(16px,3vw,32px) 96px}
h1{font-weight:700;letter-spacing:-.022em;font-size:clamp(26px,4vw,40px);line-height:1.1;margin:0 0 10px}
.lede{color:var(--ink-soft);max-width:70ch;margin:0 0 6px}
.meta{color:var(--ink-faint);font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:12.5px;margin-top:14px}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(124px,1fr));gap:1px;background:var(--rule);border:1px solid var(--rule);
 border-radius:10px;overflow:hidden;margin:30px 0 16px;box-shadow:var(--shadow)}
.stat{background:var(--card);padding:15px 17px}
.stat .n{font-weight:700;font-size:29px;line-height:1;font-variant-numeric:tabular-nums;letter-spacing:-.02em}
.stat .k{font-size:11.5px;letter-spacing:.09em;text-transform:uppercase;color:var(--ink-faint);margin-top:7px}
.stat.ok .n{color:var(--ok)}.stat.refuted .n{color:var(--muted)}.stat.pending .n{color:var(--warn)}.stat.open .n{color:var(--open)}
.bar{display:flex;height:9px;border-radius:5px;overflow:hidden;background:var(--rule-soft);margin-bottom:30px}
.bar i{display:block;height:100%}.bar .f{background:var(--ok)}.bar .r{background:var(--muted)}.bar .p{background:var(--warn)}
.bar .o{background:var(--open)}.bar .d{background:var(--rule)}
.rel{background:var(--card);border:1px solid var(--rule);border-radius:10px;padding:18px 20px;margin:0 0 30px;box-shadow:var(--shadow)}
.rel h3{margin:0 0 8px;font-size:15px;letter-spacing:.02em}
.rel p{margin:0;color:var(--ink-soft);font-size:13.5px;line-height:1.65}
.rel strong{color:var(--ink);font-variant-numeric:tabular-nums}
.rel .note{margin-top:10px;font-size:12px;color:var(--ink-faint)}
.runs{overflow-x:auto;margin:14px 0 0}
.runs table{min-width:600px;border:1px solid var(--rule);border-radius:8px}
.runs th,.runs td{padding:7px 11px;font-size:12.5px}
.runs td{font-family:"IBM Plex Mono",ui-monospace,monospace;color:var(--ink-soft)}
.runs td:first-child{color:var(--ink)}
.runs tr.bad td{color:var(--warn)}
.controls{position:sticky;top:0;z-index:5;background:var(--paper);padding:12px 0 12px;border-bottom:1px solid var(--rule);margin-bottom:6px}
.grp{display:flex;flex-wrap:wrap;gap:7px;align-items:center;margin-bottom:7px}
.grp .lbl{font-size:11px;letter-spacing:.09em;text-transform:uppercase;color:var(--ink-faint);margin-right:2px;min-width:74px}
button.chip{font:inherit;font-size:13px;cursor:pointer;border:1px solid var(--rule);background:var(--card);color:var(--ink-soft);
 padding:5px 12px;border-radius:999px;transition:.13s}
button.chip:hover{border-color:var(--accent);color:var(--ink)}
button.chip[aria-pressed="true"]{background:var(--accent);border-color:var(--accent);color:#fff}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]) button.chip[aria-pressed="true"]{color:#0F1218}}
button.chip:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.search{flex:1;min-width:200px;font:inherit;font-size:13.5px;padding:6px 12px;border-radius:999px;border:1px solid var(--rule);background:var(--card);color:var(--ink)}
.count{font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:12px;color:var(--ink-faint);margin-left:auto;white-space:nowrap}
section{margin-top:34px}
h2{font-weight:600;font-size:18px;margin:0 0 3px;display:flex;align-items:baseline;gap:11px}
h2 .sn{font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:12.5px;color:var(--accent);background:var(--accent-soft);padding:2px 7px;border-radius:5px}
h2 .sc{margin-left:auto;font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:12px;color:var(--ink-faint);font-weight:400}
.tw{overflow-x:auto;border:1px solid var(--rule);border-radius:10px;background:var(--card);margin-top:12px;box-shadow:var(--shadow)}
table{border-collapse:collapse;width:100%;min-width:860px}
th{text-align:left;font-size:11px;letter-spacing:.085em;text-transform:uppercase;color:var(--ink-faint);font-weight:500;padding:10px 13px;border-bottom:1px solid var(--rule);white-space:nowrap}
td{padding:11px 13px;border-bottom:1px solid var(--rule-soft);vertical-align:top;font-size:13.5px}
tr:last-child td{border-bottom:none}tr.row:hover td{background:var(--rule-soft)}
td.id{font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:12.5px;color:var(--ink-soft);white-space:nowrap}
td.an{font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:11.5px;color:var(--ink-faint);max-width:210px;word-break:break-word}
td.de{min-width:280px}td.st{max-width:330px;font-size:12.5px;color:var(--ink-soft)}
td.pa,td.ev{white-space:nowrap}
.badge{display:inline-block;font-size:10.5px;letter-spacing:.07em;text-transform:uppercase;font-weight:600;padding:2.5px 8px;border-radius:5px;white-space:nowrap;margin-bottom:5px}
.b-fixed{background:var(--ok-bg);color:var(--ok)}.b-refuted{background:var(--muted-bg);color:var(--muted)}
.b-pending{background:var(--warn-bg);color:var(--warn)}.b-open{background:var(--open-bg);color:var(--open)}
.b-decided{background:var(--ok-bg);color:var(--ok)}
.b-tool{background:var(--warn-bg);color:var(--warn)}.b-duplicate{background:var(--muted-bg);color:var(--muted)}
.b-dormant{background:var(--muted-bg);color:var(--muted)}
.b-en{background:var(--warn-bg);color:var(--warn);margin-left:6px}
.tag{display:inline-block;font-size:10.5px;padding:2px 7px;border-radius:5px;background:var(--rule-soft);color:var(--ink-soft);margin:0 4px 4px 0;white-space:nowrap}
.tag.hw{background:var(--ok-bg);color:var(--ok)}
td.td{white-space:nowrap}
.todo{display:inline-block;font-size:10.5px;letter-spacing:.06em;text-transform:uppercase;font-weight:600;padding:2.5px 8px;border-radius:5px;white-space:nowrap}
.x-none{background:var(--ok-bg);color:var(--ok)}.x-decision{background:var(--warn-bg);color:var(--warn)}
.x-measure{background:var(--warn-bg);color:var(--warn)}.x-work{background:var(--open-bg);color:var(--open)}
.x-rest{background:var(--muted-bg);color:var(--muted)}
.empty{padding:26px 14px;color:var(--ink-faint)}
code{font-family:"IBM Plex Mono",ui-monospace,monospace;font-size:.92em;background:var(--rule-soft);padding:1px 4px;border-radius:3px}
footer{margin-top:56px;padding-top:20px;border-top:1px solid var(--rule);color:var(--ink-faint);font-size:12.5px;max-width:80ch}
footer p{margin:6px 0}
@media (max-width:640px){.count{margin-left:0;width:100%}.grp .lbl{min-width:100%}}
'@

$script = @'
const D=DATA,R=D.rows,S=D.sections;
const LBL={fixed:'gefixt',refuted:'widerlegt',unproven:'nicht auffindbar',pending:'verifiziert, offen',open:'ungeprüft',duplicate:'Dublette',tool:'Prüfmittel',dormant:'schlafend'};
const PATH={ip:'IP',tp:'TP',both:'IP + TP',ets:'ETS',app:'Anwendung, DPT',build:'nur Build',none:'nicht angegeben'};
const EV={hw:'Gerät, gemessen',host:'Host-Stack',suite:'Gerät, Suite',spec:'Spec-Klausel',none:'nicht genannt'};
const TODO={none:'nichts zu tun',decision:'deine Entscheidung',measure:'Messung / Spur',work:'Code-Arbeit',rest:'ruht, nur Build'};
let fb=new Set(),fp=new Set(),fe=new Set(),ft=new Set(),q='';
const esc=s=>String(s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const md=s=>esc(s).replace(/`([^`]+)`/g,'<code>$1</code>').replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>');
function keep(r){
  if(fb.size&&!fb.has(r.b))return false;
  if(fp.size&&!fp.has(r.p))return false;
  if(fe.size&&!r.e.some(x=>fe.has(x)))return false;
  if(ft.size&&!ft.has(r.t))return false;
  if(q&&!((r.id+' '+r.desc+' '+r.anchor+' '+r.status+' '+r.reach+' '+TODO[r.t]+' '+PATH[r.p]).toLowerCase().includes(q)))return false;
  return true;
}
function draw(){
  const out=[];let shown=0;
  D.order.forEach(k=>{
    const rows=R.filter(r=>r.sec===k),vis=rows.filter(keep);
    if(!vis.length)return;
    shown+=vis.length;
    out.push('<section><h2><span class="sn">'+D.num[k]+'</span>'+md(S[k])+'<span class="sc">'+vis.length+' von '+rows.length+'</span></h2>');
    out.push('<div class="tw"><table><thead><tr><th>Nr.</th><th>Befund</th><th>Zu tun</th><th>Pfad</th><th>Nachweis</th><th>Anker</th><th>Stand</th></tr></thead><tbody>');
    vis.forEach(r=>out.push('<tr class="row t-'+r.t+'"><td class="id">'+esc(r.id)+'</td><td class="de">'+md(r.desc)+'</td>'+
      '<td class="td"><span class="todo x-'+r.t+'">'+TODO[r.t]+'</span></td>'+
      '<td class="pa"><span class="tag">'+PATH[r.p]+'</span></td>'+
      '<td class="ev">'+r.e.map(x=>'<span class="tag'+(x==='hw'?' hw':'')+'">'+EV[x]+'</span>').join('')+'</td>'+
      '<td class="an">'+md(r.anchor)+'</td>'+
      // "offen" only where something is genuinely outstanding. A verified row whose Zu-tun column says
      // "nichts zu tun" is decided, and one that only a different build reaches rests - calling either of
      // them open contradicted the column right next to it.
      '<td class="st"><span class="badge b-'+(r.b==='pending'&&(r.t==='none'||r.t==='rest')?'decided':r.b)+'">'+
        (r.b==='pending'&&r.t==='none'?'verifiziert, entschieden':
         r.b==='pending'&&r.t==='rest'?'verifiziert, ruht':LBL[r.b])+'</span>'+
      (r.en?'<span class="badge b-en" title="noch nicht uebersetzt">EN</span>':'')+
      (r.stale?'<span class="badge b-en" title="das englische Original hat sich seit der Uebersetzung geaendert">Übersetzung veraltet</span>':'')+
      '<br>'+md(r.status)+'</td></tr>'));
    out.push('</tbody></table></div></section>');
  });
  document.getElementById('list').innerHTML=out.length?out.join(''):'<div class="empty">Kein Befund passt auf diese Auswahl.</div>';
  document.getElementById('cnt').textContent=shown+' von '+R.length+' angezeigt';
}
document.querySelectorAll('button.chip').forEach(b=>b.addEventListener('click',()=>{
  const set={b:fb,p:fp,e:fe,t:ft}[b.dataset.g],k=b.dataset.k;
  if(set.has(k))set.delete(k);else set.add(k);
  b.setAttribute('aria-pressed',set.has(k));draw();
}));
document.getElementById('q').addEventListener('input',e=>{q=e.target.value.trim().toLowerCase();draw();});
document.getElementById('reset').addEventListener('click',()=>{
  fb.clear();fp.clear();fe.clear();ft.clear();q='';
  document.getElementById('q').value='';
  document.querySelectorAll('button.chip').forEach(b=>b.setAttribute('aria-pressed','false'));
  draw();
});
draw();
'@

function New-Chip {
    param([string]$Group, [string]$Key, [string]$Text)
    return "<button class=""chip"" data-g=""$Group"" data-k=""$Key"" aria-pressed=""false"">$Text</button>"
}

$chipsB = (New-Chip 'b' 'fixed' 'gefixt'), (New-Chip 'b' 'pending' 'verifiziert'), (New-Chip 'b' 'refuted' 'widerlegt'),
          (New-Chip 'b' 'unproven' 'nicht auffindbar'), (New-Chip 'b' 'open' 'ungeprüft'), (New-Chip 'b' 'duplicate' 'Dubletten'),
          (New-Chip 'b' 'dormant' 'schlafend'), (New-Chip 'b' 'tool' 'Prüfmittel')
$chipsP = (New-Chip 'p' 'ip' 'IP'), (New-Chip 'p' 'tp' 'TP'), (New-Chip 'p' 'both' 'IP + TP'), (New-Chip 'p' 'ets' 'ETS'),
          (New-Chip 'p' 'app' 'Anwendung, DPT'), (New-Chip 'p' 'build' 'nur Build'), (New-Chip 'p' 'none' 'nicht angegeben')
$chipsT = (New-Chip 't' 'decision' 'deine Entscheidung'), (New-Chip 't' 'measure' 'Messung / Spur'), (New-Chip 't' 'work' 'Code-Arbeit'),
          (New-Chip 't' 'rest' 'ruht, nur Build'), (New-Chip 't' 'none' 'nichts zu tun')
$chipsE = (New-Chip 'e' 'hw' 'Gerät, gemessen'), (New-Chip 'e' 'suite' 'Gerät, Suite'), (New-Chip 'e' 'host' 'Host-Stack'), (New-Chip 'e' 'spec' 'Spec-Klausel'), (New-Chip 'e' 'none' 'nicht genannt')

$html = @"
<!DOCTYPE html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>knx und TPUart - Befundregister</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500&family=IBM+Plex+Sans:wght@400;500;600;700&display=swap">
<style>$style</style>
</head>
<body>
<div class="wrap">
<h1>knx und TPUart - Befundregister</h1>
<p class="lede">Jede Zeile tr&auml;gt den Stand, den sie nach eigener Nachpr&uuml;fung hat, nicht den, mit dem sie eingereicht wurde.
Die Spalten <strong>Pfad</strong> und <strong>Nachweis</strong> sind aus dem Registertext abgeleitet, nach der Regel am Fu&szlig; der Seite.
Filter lassen sich kombinieren: Stand, Pfad und Nachweis wirken zusammen, die Suche zus&auml;tzlich.</p>
$(if ($deMissing -or $deStale) { '<p class="meta" style="color:var(--warn)">' + $deMissing + ' Zeilen sind noch englisch, ' + $deStale + ' Uebersetzungen sind aelter als ihr Original - beide sind in der Spalte Stand mit EN markiert.</p>' })
<p class="meta">Stand $stamp &middot; $($sections.Count) Teilsysteme &middot; Quelle: <code>doc/knx-findings-index.md</code> &middot; $onDevice Befunde mit einem Beleg am Ger&auml;t</p>

<div class="stats">
  <div class="stat ok"><div class="n">$green</div><div class="k">erledigt</div></div>
  <div class="stat pending"><div class="n">$toDoAll</div><div class="k">zu tun</div></div>
  <div class="stat"><div class="n">$($todo['rest'])</div><div class="k">ruht (nur Build)</div></div>
  <div class="stat ok"><div class="n">$($counts['fixed'])</div><div class="k">davon gefixt</div></div>
  <div class="stat refuted"><div class="n">$($counts['refuted'])</div><div class="k">davon widerlegt</div></div>
  <div class="stat"><div class="n">$($todo['decision'])</div><div class="k">deine Entscheidung</div></div>
  <div class="stat"><div class="n">$($todo['measure'])</div><div class="k">Messung / Spur</div></div>
  <div class="stat"><div class="n">$($todo['work'])</div><div class="k">Code-Arbeit</div></div>
</div>
<div class="bar" role="img" aria-label="Anteile der St&auml;nde">
  <i class="f" style="width:$($share['fixed'])%"></i><i class="p" style="width:$($share['pending'])%"></i><i class="r" style="width:$($share['refuted'])%"></i><i class="o" style="width:$($share['open'])%"></i><i class="d" style="width:$($share['duplicate'])%"></i>
</div>

<div class="rel">
  <h3>Ampel</h3>
  <p><strong>$green von $($data.Count)</strong> Zeilen sind erledigt: gefixt, widerlegt, als Dublette unter einer anderen Nummer gef&uuml;hrt,
  ein Fehler der eigenen Pr&uuml;fmittel, oder mit einer Entscheidung geschlossen, die schon gefallen ist.
  <strong>$toDoAll</strong> sind noch zu tun, und sie teilen sich so auf:
  <strong>$($todo['decision'])</strong> warten auf deine Entscheidung, <strong>$($todo['measure'])</strong> auf eine Messung oder eine Spur am Ger&auml;t,
  <strong>$($todo['work'])</strong> auf Code. <strong>$($todo['rest'])</strong> ruhen, weil sie nur eine andere Build-Konfiguration erreicht.
  Filtere &uuml;ber <em>Zu tun</em>, um genau diese Zeilen zu sehen.</p>
  <p class="note">Von den $($data.Count) Zeilen sind $($counts['fixed']) gefixt, $($counts['refuted']) widerlegt, $($counts['unproven']) im Quelltext nicht auffindbar,
  $($counts['duplicate']) Dubletten, $($counts['dormant']) schlafend (Data Secure und RF sind in keinem Produkt eingeschaltet) und $($counts['tool']) Fehler der Pr&uuml;fmittel.
  Keine als gefixt gef&uuml;hrte Zeile tr&auml;gt einen offenen Nachtrag. $onDevice Zeilen nennen einen Beleg am Ger&auml;t.</p>
  $(if ($runs.Count) {
    '<div class="runs"><table><thead><tr><th>Lauf</th><th>Ger&auml;t</th><th>Stand</th><th>Gesamt</th><th>PASS</th><th>FAIL</th><th>SKIP</th><th>N-A</th><th>NO-PROOF</th></tr></thead><tbody>' +
    (($runs | ForEach-Object {
        $cls = if ([int]$_.fail -gt 0) { ' class="bad"' } else { '' }
        "<tr$cls><td>$($_.name)</td><td>$($_.bdut)</td><td>$($_.when)</td><td>$($_.total)</td><td>$($_.pass)</td><td>$($_.fail)</td><td>$($_.skip)</td><td>$($_.na)</td><td>$($_.noproof)</td></tr>"
    }) -join '') + '</tbody></table></div>' +
    '<p class="note">Der jeweils j&uuml;ngste Bericht aus <code>scripts/Test/Reports</code>. Host-Stack und Build-Matrix hinterlegen dort keinen Bericht und stehen deshalb nicht in dieser Tabelle.</p>'
  })
</div>

<div class="controls">
  <div class="grp"><span class="lbl">Zu tun</span>$($chipsT -join '')</div>
  <div class="grp"><span class="lbl">Stand</span>$($chipsB -join '')</div>
  <div class="grp"><span class="lbl">Pfad</span>$($chipsP -join '')</div>
  <div class="grp"><span class="lbl">Nachweis</span>$($chipsE -join '')</div>
  <div class="grp">
    <input id="q" class="search" type="search" placeholder="Suche in Nummer, Text, Anker, Stand, Reichweite ..." aria-label="Befunde durchsuchen">
    <button class="chip" id="reset" type="button">zur&uuml;cksetzen</button>
    <span class="count" id="cnt"></span>
  </div>
</div>

<div id="list"></div>

<footer>
<p><strong>Stand</strong> - <em>gefixt</em>: FIXED ohne offenen Nachtrag. <em>verifiziert, entschieden</em>: der Befund wurde
nachgeprueft und bewusst so belassen - die Spalte <em>Zu tun</em> steht dann auf "nichts zu tun". <em>verifiziert, offen</em>: dieselbe
Klasse, aber es steht noch etwas aus. Beide umfassen CONFIRMED, NARROWED, PARTLY FIXED,
RECORDED, vertagt, oder ein FIXED mit offenem Nachtrag - der Befund stimmt, die Korrektur fehlt oder ist unbelegt.
<em>widerlegt</em>: REFUTED, am Code nicht nachvollziehbar oder kein lebender Defekt. <em>nicht auffindbar</em>: UNPROVEN, die gemeldete Stelle
gibt es so nicht - ohne die urspr&uuml;ngliche Spur wird daran nichts ge&auml;ndert.
<em>ungepr&uuml;ft</em>: OPEN, noch kein Pr&uuml;fer darauf angesetzt. <em>schlafend</em>: Data Secure und RF, in keinem Produkt eingeschaltet.
<em>Pr&uuml;fmittel</em>: Fehler in den eigenen Testwerkzeugen, keine Ger&auml;tebefunde.</p>
<p><strong>Pfad</strong> - abgeleitet aus der Reichweite des Registers: BUS = TP, LAN = IP, Router, HOSTILE oder BUS+LAN = beide Pfade,
ETS = &uuml;ber den Download, BUILD, DORMANT und "hardening only" = <em>nur Build</em>, also zur Laufzeit gar nicht erreichbar.
Die Datenpunkt-Befunde nennen statt eines Transports eine Produktklasse - ein DPT kodiert falsch, wo immer er benutzt wird - und stehen deshalb
als <em>Anwendung, DPT</em>. <em>nicht angegeben</em> hei&szlig;t, das Register f&uuml;hrt f&uuml;r die Zeile keine Reichweite.</p>
<p><strong>Nachweis</strong> - was der Standtext selbst nennt: HARDWARE-VERIFIED oder BUSMONITOR-VERIFIED = am Ger&auml;t gemessen, eine Suite-Fallnummer (D-, H-, K-, P-, X-)
= am Ger&auml;t &uuml;ber die Ger&auml;te-, Konformit&auml;ts- oder Feature-Suite, eine Host-Fallnummer (HB-, HD-, HU-, HS-, HT-) = Host-Stack unter ASAN,
eine Klausel (03_xx_xx, 08_TSS.., "p. NN") = Spec. Mehrere Nachweise pro Befund sind m&ouml;glich.
<em>nicht genannt</em> hei&szlig;t genau das: der Registertext nennt keinen Beleg - nicht, dass nichts gepr&uuml;ft wurde. Die Suiten, der Host-Stack und die
Build-Matrix laufen &uuml;ber den ganzen Stand, nicht pro Zeile; deren Zahlen stehen oben im Release-Blick.</p>
<p><strong>Sprache</strong> - das Register <code>doc/knx-findings-index.md</code> bleibt englisch, weil Anker, Spec-Zitate und Fallnummern daran h&auml;ngen.
Diese Seite zeigt die deutsche Fassung aus <code>doc/knx-findings-index.de.json</code>. Eingestuft wird weiterhin am englischen Original:
Stand, Zu tun, Pfad und Nachweis entstehen aus dem englischen Text, damit eine &Uuml;bersetzung die Einstufung nicht verschieben kann.
&Auml;ndert sich das Original, markiert die Seite die betroffene Zeile.</p>
<p>Erzeugt von <code>scripts/Test/Tools/New-FindingsReport.ps1</code> aus dem Register. Die Seite ist in sich geschlossen und braucht kein Netz - nur die Schriftart wird geladen.</p>
</footer>
</div>
<script>const DATA=$payload;
$script
</script>
</body>
</html>
"@

[System.IO.File]::WriteAllText($OutFile, $html, (New-Object System.Text.UTF8Encoding $false))
Write-Host ("  {0} Befunde aus {1} Teilsystemen -> {2}" -f $data.Count, $sections.Count, $OutFile) -ForegroundColor Green
Write-Host ("  gefixt {0} | verifiziert offen {1} | widerlegt {2} | nicht auffindbar {3} | ungeprueft {4} | Dubletten {5} | schlafend {6} | Pruefmittel {7}" -f `
            $counts['fixed'], $counts['pending'], $counts['refuted'], $counts['unproven'], $counts['open'], $counts['duplicate'], $counts['dormant'], $counts['tool']) -ForegroundColor DarkGray
Write-Host ("  ERLEDIGT {0} | ZU TUN {1} (Entscheidung {2}, Messung {3}, Code {4}) | ruht {5}" -f `
            $green, $toDoAll, $todo['decision'], $todo['measure'], $todo['work'], $todo['rest']) -ForegroundColor Cyan
Write-Host ("  Beleg am Geraet {0} | offen mit Geraetepfad {1} | Pruflaeufe eingelesen {2}" -f $onDevice, $openRelease, $runs.Count) -ForegroundColor DarkGray
