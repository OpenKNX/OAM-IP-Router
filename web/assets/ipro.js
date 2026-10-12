// IP-Router status page: everything the console shows with `ipro`, `tun` and `bcu stat`, plus the
// routing decisions the device now records.
// The device sends raw counters; the same humanCount/humanBytes rules as the console are applied here,
// so both speak one language. A value the firmware does not collect is absent from the JSON and is
// rendered as "nicht verfügbar" - never as a zero.
(function () {
    const $ = function (id) { return document.getElementById(id); };
    // The page ships as an empty shell; this is its markup. It lives here because the asset is
    // gzipped - the same bytes cost roughly a third of an uncompressed C string in flash.
    const root = $('ii-root');
    if (!root) return;
    root.innerHTML = "<h1>IP-Router <span id='ii-head' class='gray' style='font-size:.6em;font-weight:normal'>&hellip;</span></h1><div id='ii-bar' class='ii-bar'><span id='ii-bar-items'></span><span id='ii-poll'></span></div><h2>&Uuml;bersicht</h2><div id='ii-ov' class='ii-grid'></div><h2>Tunnel <span id='ii-tn-head' class='gray' style='font-size:.8em;font-weight:normal;text-transform:none;letter-spacing:0'></span></h2><div class='tn-tabs' id='ii-tabs'><a class='tn-tab active' id='ii-tab-a' data-t='a'>Aktiv</a><a class='tn-tab' id='ii-tab-h' data-t='h'>Historie</a><a class='tn-tab' id='ii-tab-s' data-t='s'>Reservierte</a></div><div id='ii-tp-a' class='ii-tblwrap'></div><div id='ii-tp-h' class='ii-tblwrap' hidden></div><div id='ii-tp-s' class='ii-grid ii-tblwrap' hidden></div><h2>Routing</h2><div class='tn-tabs' id='ii-rtabs'><a class='tn-tab active' data-t='rt' id='ii-tab-rt'>Letzte</a><a class='tn-tab' data-t='top' id='ii-tab-top'>H&auml;ufigste</a><a class='tn-tab' data-t='filt' id='ii-tab-filt'>Filtertabelle</a></div><div id='ii-rp-rt' class='ii-tblwrap'></div><div id='ii-rp-top' class='ii-grid' hidden></div><div id='ii-rp-filt' hidden></div><details class='ii-sec' id='ii-sec-bus'><summary>Bus + Diagnose <em id='ii-bus-sum'></em></summary><div id='ii-bus'></div></details>";


    const POLL_MS = 2000;
    let busy = false, busBusy = false, rtBusy = false;

    // --- Formats, ported from OGM-Common/src/OpenKNX/Helper.cpp ---

    function p2(n) { return (n < 10 ? '0' : '') + n; }

    function humanCount(v) {
        v = Math.floor(v);
        if (v < 10000) return '' + v;
        if (v < 100000) return Math.floor(v / 1000) + '.' + Math.floor((v % 1000) / 100) + 'k';
        if (v < 1000000) return Math.floor(v / 1000) + 'k';
        if (v < 10000000) return Math.floor(v / 1e6) + '.' + p2(Math.floor((v % 1e6) / 1e4)) + 'M';
        if (v < 100000000) return Math.floor(v / 1e6) + '.' + Math.floor((v % 1e6) / 1e5) + 'M';
        if (v < 1000000000) return Math.floor(v / 1e6) + 'M';
        if (v < 10000000000) return Math.floor(v / 1e9) + '.' + p2(Math.floor((v % 1e9) / 1e7)) + 'G';
        return Math.floor(v / 1e9) + 'G';
    }

    function humanBytes(v) {
        v = Math.floor(v);
        if (v < 10000) return v + ' B';
        if (v < 100000) return Math.floor(v / 1000) + '.' + Math.floor((v % 1000) / 100) + ' kB';
        if (v < 1000000) return Math.floor(v / 1000) + ' kB';
        if (v < 10000000) return Math.floor(v / 1e6) + '.' + p2(Math.floor((v % 1e6) / 1e4)) + ' MB';
        if (v < 100000000) return Math.floor(v / 1e6) + '.' + Math.floor((v % 1e6) / 1e5) + ' MB';
        if (v < 1000000000) return Math.floor(v / 1e6) + ' MB';
        if (v < 10000000000) return Math.floor(v / 1e9) + '.' + p2(Math.floor((v % 1e9) / 1e7)) + ' GB';
        return Math.floor(v / 1e9) + ' GB';
    }

    function humanCountShort(v) {
        v = Math.floor(v);
        if (v < 1000) return '' + v;
        if (v < 1000000) return Math.floor(v / 1000) + 'k';
        if (v < 1000000000) return Math.floor(v / 1e6) + 'M';
        return Math.floor(v / 1e9) + 'G';
    }

    function pct(permille) { return (permille / 10).toFixed(1).replace('.', ',') + '&nbsp;%'; }

    // --- Building blocks ---

    function na(why) { return '<span class="ii-na" title="' + why + '">nicht verfügbar</span>'; }
    function esc(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;'); }

    // Which explanations are open. The panels are rebuilt on every poll, so this cannot live in the
    // DOM - otherwise every refresh would close what the user just opened.
    const openWhy = new Set();

    // ASCII-only key: the label may carry HTML entities, and the browser decodes them in dataset.
    function whyKey(label) { return label.replace(/&[a-z]+;/g, '').replace(/[^A-Za-z0-9]/g, ''); }

    function wireWhy(el) {
        el.querySelectorAll('details.ii-rowd').forEach(function (d) {
            d.addEventListener('toggle', function () {
                if (d.open) openWhy.add(d.dataset.k); else openWhy.delete(d.dataset.k);
            });
        });
    }

    function row(label, value, why, cls) {
        const v = '<i>' + label + '</i><b class="' + (cls || '') + '">' + value + '</b>';
        if (!why) return '<div class="ii-row">' + v + '</div>';
        const k = whyKey(label);
        return '<details class="ii-rowd" data-k="' + k + '"' + (openWhy.has(k) ? ' open' : '') + '>' +
               '<summary class="ii-row">' + v + '<em title="Erkl\u00e4rung">?</em></summary>' +
               '<p class="ii-p">' + why + '</p></details>';
    }

    function head(t) { return '<div class="ii-sub-h">' + t + '</div>'; }

    function spark(hist) {
        if (!hist || hist.length < 2) return '';
        const w = 120, h = 14, max = Math.max(50, Math.max.apply(null, hist));
        const pts = hist.map(function (v, i) {
            return (i * (w - 2) / (hist.length - 1) + 1).toFixed(1) + ',' + (h - 1 - v * (h - 2) / max).toFixed(1);
        }).join(' ');
        return '<svg class="ii-spark" width="' + w + '" height="' + h + '" viewBox="0 0 ' + w + ' ' + h + '">' +
               '<rect width="' + w + '" height="' + h + '"/><polyline points="' + pts + '"/></svg>';
    }

    // Every slot the device has, split into two columns. The count comes from the device (KNX_TUNNELING
    // is a build define and may be 8 or 32), never from a constant here. A reserved slot is never handed
    // out from the free pool, so one without an address can be reached by nobody -- that is worth seeing
    // per slot, not only as a number. Built from resv (the configuration) and act (who sits where, "s").
    function slotView(resv, act, max, ias) {
        const res = {}, occ = {};
        resv.forEach(function (r) { res[r[0]] = r[1]; });
        act.forEach(function (a) { if (a.s) occ[a.s] = a.pa; });
        function half(from, to) {
            let h = '<table><thead><tr><th>Nr</th><th>Adresse</th><th>Reserviert f&uuml;r</th>' +
                    '<th>Zustand</th></tr></thead><tbody>';
            for (let n = from; n <= to; n++) {
                const r = res[n];
                // ias[] carries the address as the device stores it, with a trailing marker when the
                // slot cannot serve: "*" = the reserved x.y.255, which is what ETS writes for a tunnel it
                // left unassigned and shows as "5.0.-"; "!" = repeats an earlier slot.
                const ia = ias && ias.length >= n ? ias[n - 1] : undefined;
                const mark = ia === undefined ? '' : (ia.slice(-1) === '*' ? '*' : (ia.slice(-1) === '!' ? '!' : ''));
                const adr = ia === undefined ? '&ndash;'
                          // Not coloured: the Zustand pill already carries this, and two amber marks in
                          // one row for one fact read as two problems.
                          : mark ? esc(ia.slice(0, -1)) : esc(ia);
                const fuer = r === undefined ? '&ndash;' : (r === '0.0.0.0' ? 'ohne IP' : esc(r));
                // Pills like the Aktiv tab's Zustand column, so both tabs read the same way, and
                // "frei verfuegbar"/"frei" become "frei"/"reserviert" -- that pair read like synonyms
                // while meaning the opposite of each other.
                // The address warning is deliberately NOT repeated here. It describes the address
                // CONFIGURED for this slot, and a client connecting without a reservation is given the
                // first free address of the whole pool, not this slot's -- on an occupied row the pill
                // would accuse a client whose address may be perfectly fine. It stays where it belongs:
                // on the Adresse cell, which is amber whether or not the slot is occupied.
                // 0.0.0.0 is tested before the warnings: that slot can never serve anyone, a duplicate
                // or missing address still can.
                // "nicht eindeutig", not "keine Adresse": the Adresse cell right next to this one shows
                // the address, so denying it reads as a contradiction. Uniqueness is also the property the
                // stack actually tests -- KNX answers E_NO_MORE_UNIQUE_CONNECTIONS -- and it holds for all
                // three forms (shared, x.y.255 placeholder, empty), so one pill covers them.
                // VS15 (FE0E) keeps the warning sign a TEXT glyph; alone it becomes a colour emoji.
                const warn = mark ? '&#9888;&#65038;&nbsp;Adresse nicht eindeutig' : '';
                const zust = occ[n] ? '<span class="tn-p ok">&#9679;&nbsp;belegt &middot; ' + esc(occ[n]) + '</span>'
                    : r === '0.0.0.0' ? '<span class="tn-p bad">&#8856;&nbsp;nicht erreichbar</span>'
                    : warn ? '<span class="tn-p warn">' + warn + '</span>'
                    : r === undefined ? '<span class="tn-p idle">&#9675;&nbsp;frei</span>'
                    : '<span class="tn-p idle">&#9680;&nbsp;reserviert</span>';
                h += '<tr><td>T' + n + '</td><td>' + adr + '</td><td>' + fuer + '</td><td>' + zust +
                     '</td></tr>';
            }
            return h + '</tbody></table>';
        }
        const left = Math.ceil(max / 2);
        return '<div>' + half(1, left) + '</div>' +
               (max > left ? '<div>' + half(left + 1, max) + '</div>' : '') +
               // Explains only what THIS table shows, in the order the row is actually decided, and
               // claims nothing about connecting: every warning row is by construction a row where
               // nothing is connected. "Ausweichplatz" moved to TUN_WHY, next to the column using it.
               '<p class="meta ii-row-wide" style="margin:8px 0 0">' +
               '<span class="tn-p ok">&#9679;&nbsp;belegt</span> = ein Client ist verbunden &middot; ' +
               '<span class="tn-p bad">&#8856;&nbsp;nicht erreichbar</span> = ohne IP-Adresse reserviert, ' +
               'f&uuml;r niemanden nutzbar &middot; ' +
               '<span class="tn-p warn">&#9888;&#65038;&nbsp;Adresse nicht eindeutig</span> = die KNX-Adresse ' +
               'fehlt oder ist doppelt vergeben; dadurch sind weniger Tunnel gleichzeitig m&ouml;glich &middot; ' +
               '<span class="tn-p idle">&#9675;&nbsp;frei</span> = f&uuml;r jeden Client &middot; ' +
               '<span class="tn-p idle">&#9680;&nbsp;reserviert</span> = nur f&uuml;r die genannte IP-Adresse.</p>';
    }


    // A column is [key, heading] or [key, heading, render(row)] when the cell is more than plain text.
    // With det() the table gets an expander column: det(row) returns the detail markup, or nothing for
    // a row that has no detail (a refused connect never had a session). open is that table's own set of
    // expanded rows; it is pruned here to the rows on screen, so ended sessions do not accumulate.
    function tbl(rows, cols, empty, det, open) {
        if (!rows.length) { if (open) open.clear(); return '<p class="meta">' + empty + '</p>'; }
        const seen = new Set();
        let h = '<table><thead><tr>' + (det ? '<th class="tn-c"></th>' : '');
        cols.forEach(function (c) { h += '<th>' + c[1] + '</th>'; });
        h += '</tr></thead><tbody>';
        rows.forEach(function (r) {
            const d = det ? det(r) : '';
            const k = d ? tunKey(r) : '';
            if (d) seen.add(k);
            const on = d && open && open.has(k);
            h += d ? '<tr class="tn-r' + (on ? ' open' : '') + '" data-k="' + esc(k) + '" tabindex="0">'
                   : '<tr>';
            if (det) h += '<td class="tn-c">' + (d ? '<span class="tn-cv">&#9656;</span>' : '') + '</td>';
            cols.forEach(function (c) {
                h += '<td>' + (c[2] ? c[2](r) : esc(r[c[0]] === undefined ? '' : r[c[0]])) + '</td>';
            });
            h += '</tr>';
            if (d) h += '<tr class="tn-d"' + (on ? '' : ' hidden') + '><td colspan="' + (cols.length + 1) +
                        '">' + d + '</td></tr>';
        });
        if (open) open.forEach(function (k) { if (!seen.has(k)) open.delete(k); });
        return h + '</tbody></table>';
    }

    // Which detail rows are open, per table. Same reason as openWhy: the tables are rebuilt on every
    // poll, so the DOM cannot hold this state. The type is part of the key because a device-management
    // connection and a data tunnel from the same client can carry the same connect millisecond.
    const openA = new Set(), openH = new Set();
    function tunKey(r) { return (r.t || '') + '|' + r.k + '|' + (r.ip || '') + '|' + (r.s || ''); }

    function tunNum(v) { return v === undefined ? '&ndash;' : humanCount(v); }

    // To the client / accepted from the client. NOT "to the bus": a frame addressed to the interface
    // itself or to a tunnel address is answered locally and never leaves for TP.
    // Arrow next to its own number instead of in the header: a busmonitor or history row has no
    // counter-direction, and "2 / -" leaves you guessing WHICH one is missing.
    function tunTraffic(r) {
        if (r.tc === undefined) return '&ndash;';
        return '&rarr;' + tunNum(r.tc) + ' <span class="gray">/</span> &larr;' + tunNum(r.fc);
    }

    // Derived here, not sent by the device. Counts the findings instead of naming the heaviest one:
    // a connection carries several at once, and naming only the worst read as if it were the only one.
    // A full send queue is NOT a finding: depth 3 exists so the device's own burst of
    // connection-oriented answers fits, so peak == depth is the buffer doing its job.
    // One colour for any number of them -- this column says a look is worth it, the expanded row says
    // how bad. "Abbruch" is not among them: it is set for history rows only, where the Ende and Code
    // columns already say it, and it outranked the counters and hid them.
    const TUN_FIND = ['dr', 'gd', 'gp', 'rs'];
    function tunState(r) {
        if (r.tc === undefined) return '<span class="gray">&ndash;</span>';
        let n = 0;
        for (let i = 0; i < TUN_FIND.length; i++) if (r[TUN_FIND[i]]) n++;
        return n ? '<span class="tn-p warn">' + n + ' Hinweis' + (n > 1 ? 'e' : '') + '</span>'
                 : '<span class="tn-p ok">ok</span>';
    }

    // The Ende column names the concrete cause; "ab" only classifies it as one nobody asked for.
    // Marking it here keeps that classification next to the cause instead of in the counter column,
    // where it outranked the counters. tbl() escapes only when a column has no formatter.
    function tunEnde(r) {
        const t = esc(r.reason === undefined ? '' : r.reason);
        return r.ab ? '<span class="ii-warn">' + t + '</span>' : t;
    }

    // One string for every row, so it lands in flash once instead of being assembled per call.
    // Terse on purpose: this is a reference line, not prose.
    // Same shape as the reserved-tunnel legend: one term, one "=", one meaning, separated by a dot --
    // and the Zustand values as the PILLS they really are, so the key looks like the column it explains.
    const TUN_WHY =
        '<b>&rarr;</b> = an den Client gesendet &middot; <b>&larr;</b> = vom Client empfangen &middot; ' +
        '<b>Wiederholungen</b> = ohne Best&auml;tigung erneut gesendet &middot; ' +
        '<b>Puffer max</b> = h&ouml;chster F&uuml;llstand des Sendepuffers, voll ist normal &middot; ' +
        '<b>Verworfen</b> = nicht zugestellt &middot; ' +
        '<b>&Uuml;berlast</b> = Gruppentelegramme, die bei vollem Puffer ausgelassen wurden &middot; ' +
        '<b>Sequenzfehler</b> = Telegramm mit falscher laufender Nummer, verworfen &middot; ' +
        '<b>Letzter Kontakt</b> = Zeit seit der letzten Meldung des Clients' +
        '<br><b>Zustand</b>: <span class="tn-p warn">n Hinweise</span> = so viele der Z&auml;hler Wiederholungen, ' +
        'Verworfen, &Uuml;berlast und Sequenzfehler stehen nicht auf 0 &middot; ' +
        '<span class="gray">&ndash;</span> = nicht messbar &middot; alle Z&auml;hler gelten seit Verbindungsbeginn' +
        '<br><b>Zuteilung</b>: <b>fest</b> = der f&uuml;r diesen Client reservierte Platz &middot; ' +
        '<b>Ausweichplatz</b> = sein reservierter Platz war belegt &middot; ' +
        '<b>frei vergeben</b> = ohne Reservierung';
    const TUN_WHY_BM = '<br><b>Busmonitor</b>: liest nur mit, deshalb ohne &larr; und ohne Puffer';
    // Only the history has an Ende column; explaining it on an active row describes a column that
    // is not on screen. A history row is the one carrying a reason.
    const TUN_WHY_END = '<br><b>Ende</b>: orange = nicht regul&auml;r beendet';

    function tunDetail(r) {
        if (r.tc === undefined) return ''; // refused connect: the Ende column already says why
        const d = function (v) { return v === undefined ? '<span class="gray">&ndash;</span>' : v; };
        // Third element: the severity this entry carries once its counter is not zero. The column
        // above only counts the findings, so this is where "how bad" is said -- Verworfen is the
        // only one of them that is a real loss. Puffer max is not a finding, full is normal.
        const kv = [['Wiederholungen', d(r.rs), r.rs ? ' class="warn"' : ''],
                    ['Puffer max', r.qd === undefined ? d(undefined) : r.qp + '&nbsp;/&nbsp;' + r.qd, ''],
                    ['Verworfen', d(r.dr), r.dr ? ' class="bad"' : ''],
                    ['&Uuml;berlast', d(r.gd), r.gd ? ' class="warn"' : ''],
                    ['Sequenzfehler', d(r.gp), r.gp ? ' class="warn"' : '']];
        if (r.idle !== undefined) kv.push(['Letzter Kontakt', 'vor ' + esc(r.idle), '']);
        let h = '<div class="tn-kv">';
        kv.forEach(function (e) { h += '<dl' + e[2] + '><dt>' + e[0] + '</dt><dd>' + e[1] + '</dd></dl>'; });
        h += '</div>';
        // Live rows only: a history row carries no channel id and must not offer this. Both attribute
        // values are made safe HERE rather than trusting the device: who is reduced to a charset without
        // any quote, and ch is coerced to a number (esc() does not escape quotes, so an unchecked string
        // from the JSON would break out). The title is what tells two buttons apart for a screen reader.
        const who = String((r.t || '') + ' ' + (r.ip || '')).replace(/[^\w .:-]/g, '');
        const btn = !r.ch ? '' : '<div class="tn-act"><button class="ii-btn tn-x" data-ch="' + (+r.ch || 0) +
                    '" data-who="' + who + '" title="' + who + ' trennen">Verbindung trennen</button></div>';
        // Behind the page's own "?", closed by default and keyed per row, so opening one explanation
        // neither unfolds the others nor is lost on the 2 s refresh.
        // Separators kept: stripping them merged an active row into a history row with the
        // same digits. The pipe is remapped because it is the separator tunKey() builds with.
        const k = 'tw' + tunKey(r).replace(/\|/g, '_');
        return '<details class="ii-rowd tn-why" data-k="' + esc(k) + '"' + (openWhy.has(k) ? ' open' : '') +
               '><summary>' + h + '<em>?</em></summary><p class="ii-p">' +
               TUN_WHY + (r.t === 'Busmonitor' ? TUN_WHY_BM : '') +
               (r.reason === undefined ? '' : TUN_WHY_END) + '</p></details>' + btn;
    }

    function toggleTun(tr, open) {
        const d = tr.nextElementSibling;
        const on = !tr.classList.contains('open');
        tr.classList.toggle('open', on);
        if (d && d.classList.contains('tn-d')) d.hidden = !on;
        if (on) open.add(tr.dataset.k); else open.delete(tr.dataset.k);
    }

    // One action at a time, tracked HERE and not on the button: renderState replaces the whole panel on
    // every poll, so a disabled button is detached within one interval and re-enabling it would write to
    // a node nobody sees. Failure has to be loud - the device parks the work and answers before doing it,
    // so the page has no other way to learn that nothing happened.
    let acting = false;
    function postAction(url, ask, failPrefix) {
        if (acting || !window.confirm(ask)) return;
        acting = true;
        fetch(url, { method: 'POST' })
            .then(function (r) {
                // Body first: the device puts its own reason there. Then the status, so an error page
                // that is not JSON at all (404 on an older firmware, a proxy) cannot read as success.
                return r.json().catch(function () { return {}; }).then(function (j) {
                    if (j.e) throw new Error(j.e);
                    if (!r.ok) throw new Error('HTTP ' + r.status);
                });
            })
            .then(function () {
                // The device merely PARKS the wish and performs it in its KNX loop, and load() skips a
                // poll that is already in flight - so ask twice rather than trust one timer to land.
                setTimeout(load, 700);
                setTimeout(load, 1800);
            })
            .catch(function (err) {
                window.alert(failPrefix + (err && err.message ? err.message : 'keine Antwort vom Ger\u00e4t'));
            })
            .finally(function () { acting = false; });
    }

    // Ends a connection from the device side. KNX 03_08_02 lists DISCONNECT_REQUEST in the
    // server->client direction as mandatory (certification table, both directions), so this is the
    // protocol's own way, not a trick. It frees the slot; it does not ban anyone - most clients
    // reconnect by themselves within seconds.
    function closeTun(ch, who) {
        // who starts with the row's type, and a busmonitor has no transfer that could break. No product
        // name here: the client may be ETS, a visualisation, a host tool - the device cannot know.
        const risk = who.lastIndexOf('Busmonitor', 0) === 0 ? 'Die Aufzeichnung endet.'
                                                            : 'Eine laufende \u00dcbertragung bricht ab.';
        postAction('/ipro/close?ch=' + encodeURIComponent(ch),
                   'Verbindung ' + who + ' trennen?\n\n' + risk +
                   ' Die meisten Clients verbinden sich sofort neu.',
                   'Trennen fehlgeschlagen: ');
    }

    // One delegated listener per table area, attached once - the rows themselves are replaced on every poll.
    function wireTun(wrap, open) {
        wrap.addEventListener('click', function (ev) {
            const btn = ev.target.closest && ev.target.closest('button.tn-x');
            if (btn) { closeTun(btn.dataset.ch, btn.dataset.who); return; }
            const tr = ev.target.closest && ev.target.closest('tr.tn-r');
            if (tr) toggleTun(tr, open);
        });
        wrap.addEventListener('keydown', function (ev) {
            if (ev.key !== 'Enter' && ev.key !== ' ') return;
            const tr = ev.target.closest && ev.target.closest('tr.tn-r');
            if (!tr) return;
            ev.preventDefault();
            toggleTun(tr, open);
        });
    }

    // A queue loss is current for this long after its counter last rose, then it turns amber.
    // Same value on the IP-Interface page.
    const LOST_FRESH_S = 300;

    function lostFresh(n, age) { return n > 0 && age >= 0 && age < LOST_FRESH_S; }

    function ago(s) {
        return s < 60 ? s + '&nbsp;s' : s < 3600 ? Math.floor(s / 60) + '&nbsp;min'
             : s < 172800 ? Math.floor(s / 3600) + '&nbsp;h' : Math.floor(s / 86400) + '&nbsp;d';
    }

    // [lost since start or reset, seconds since its last rise (-1 = none)]. An older firmware sends
    // only the raw counter; it is then shown as fresh and without an age (third element).
    function lostOf(d, k) {
        return d[k + 'Since'] === undefined ? [d[k] || 0, 0, true] : [d[k + 'Since'], d[k + 'Age']];
    }

    function lostCell(v) {
        const n = v[0], age = v[1];
        if (!n) return '0';
        return '<span class="' + (lostFresh(n, age) ? 'ii-bad' : 'ii-warn') + '">' + humanCount(n) + '</span>' +
               (age >= 0 && !v[2] ? ' <span class="gray">zuletzt vor ' + ago(age) + '</span>' : '');
    }

    // Written for the person operating the installation: what the value says and when it matters.
    const WHY = {
        byteErr: 'FE = Verbindung zum Bus-Chip gest&ouml;rt &middot; PE = Bitfehler beim Empfang &middot; ' +
                 'BE = Verbindung zum Bus-Chip unterbrochen &middot; OE = Zeichen verpasst, Ger&auml;t zu langsam.',
        rep: 'Ein Telegramm wurde nicht best&auml;tigt und wiederholt. H&auml;ufig bei Leitungsproblemen oder ' +
             'einem &uuml;berlasteten Ger&auml;t.',
        ovf: 'Interne Puffer waren voll (U/S/R/T = Empfang, Suche, Rahmen, Senden). Jeder Wert &uuml;ber 0 ' +
             'bedeutet verlorene Daten.',
        ackDrop: 'Das Ger&auml;t konnte ein Telegramm nicht rechtzeitig best&auml;tigen; der Sender wiederholt es.',
        con: 'Der Bus-Chip hat ein gesendetes Telegramm nicht best&auml;tigt; das Ger&auml;t hat es selbst ' +
             'abgeschlossen. Auff&auml;llig nur bei st&auml;ndigem Anstieg.',
        sc: 'Zwei Teilnehmer haben gleichzeitig gesendet. Einzeln normal; dauerhaft hoch deutet auf ein ' +
            'Adress- oder Leitungsproblem.',
        lost: 'Telegramme, die das Ger&auml;t nicht weitergeben konnte, z.&nbsp;B. bei &Uuml;berlast oder ' +
              'unterbrochener Verbindung. <b>Rot</b> = in den letzten ' + (LOST_FRESH_S / 60) +
              '&nbsp;min, <b>orange</b> = l&auml;nger her.',
        rxDrop: '<b>Empfang</b> = Pakete aus dem Netzwerk, die das Ger&auml;t nicht rechtzeitig annehmen konnte.',
        // All four values, because all four are on the row.
        load: 'Auslastung der KNX-Linie. <b>jetzt</b> = letzte Sekunde &middot; <b>Mittel</b> = Durchschnitt ' +
              'der angezeigten Sekunden &middot; <b>Spitze</b> = h&ouml;chster Wert seit Start oder Zur&uuml;cksetzen ' +
              '&middot; <b>B/s</b> = empfangene Bytes pro Sekunde. Kurzzeitig &uuml;ber 100&nbsp;% m&ouml;glich. ' +
              '&bdquo;Z&auml;hler zur&uuml;cksetzen&ldquo; beginnt neu und setzt auch ' +
              'die verlorenen Telegramme auf 0.',
        addIa: 'Jeder Tunnel braucht eine eigene KNX-Adresse aus dem KNX-Projekt. Fehlt sie oder ist sie doppelt ' +
               'vergeben, k&ouml;nnen weniger Clients gleichzeitig verbinden. Details im Tab ' +
               '&bdquo;Reservierte&ldquo;.',
        toIp: '<b>&rarr;IP</b> = ins Netzwerk gesendete Pakete &middot; <b>&rarr;TP</b> = auf der KNX-Linie ' +
              'zugestellte Telegramme.',
        cfg: 'Das Ger&auml;t hat keine g&uuml;ltige KNX-Konfiguration und keine Filtertabelle: noch nicht ' +
             'programmiert oder nach einem Firmware-Wechsel ung&uuml;ltig. Tunnel funktionieren trotzdem; ' +
             'fehlen Tunnel-Adressen, vergibt das Ger&auml;t vorl&auml;ufige.',
        mc: 'Adresse, &uuml;ber die KNX-IP-Ger&auml;te im Netzwerk Telegramme austauschen. <b>TTL</b> = Reichweite: ' +
            'begrenzt, &uuml;ber wie viele Netzwerk-Router ein Telegramm weitergereicht wird.',
        routed: 'Telegramme, die der Router auf die andere Seite weitergeleitet hat.',
        filt: 'Telegramme, die nicht auf die andere Seite geh&ouml;ren: laut Filtertabelle, Einstellung oder ' +
              'Zieladresse. Gewollt, kein Fehler.',
        hop0: 'Der Routing-Z&auml;hler (Hop-Count) des Telegramms war aufgebraucht, es wurde nicht ' +
              'weitergeleitet. Entweder so gesendet oder Hinweis auf eine Schleife in der Anlage.',
        lostRx: 'Andere KNX-IP-Ger&auml;te im Netzwerk haben gemeldet, dass bei ihnen Telegramme verloren gingen.',
        busyRx: 'Andere KNX-IP-Ger&auml;te im Netzwerk haben &Uuml;berlast gemeldet. Der Router legt dann ' +
                'eine kurze Sendepause ein.'
    };

    // --- Overview + status line ---

    function renderState(d) {
        const l = d.load;
        const loadCls = l.now >= 500 ? 'ii-bad' : l.now >= 200 ? 'ii-warn' : 'ii-ok';
        // Any of the three: each counter holds only telegrams that were dropped.
        const lostTp = lostOf(d, 'lostTp'), lostIp = lostOf(d, 'lostIp'), rxDrop = lostOf(d, 'rxDrop');
        const bad = lostFresh(lostTp[0], lostTp[1]) || lostFresh(lostIp[0], lostIp[1]) ||
                    lostFresh(rxDrop[0], rxDrop[1]);

        $('ii-head').innerHTML = d.tun.n + '&nbsp;/&nbsp;' + d.tun.max + ' Tunnel &middot; Buslast ' + pct(l.now);

        // No usable tunnel address means no client can connect at all -- a blocking fault, so it
        // colours the row and the status bar, not just the tunnel header.
        // Unconfigured is the root state: no loaded application; the address may still be a programmed one. It
        // outranks every other hint on the page, because all of them are consequences of it.
        const unconf = d.cfg === 0;
        const iaBad = !unconf && d.addIa !== undefined && d.addIa.used === 0;
        const iaThin = !unconf && d.addIa !== undefined && d.addIa.used > 0 && d.addIa.used < d.addIa.max;
        // iaThin colours nothing: fewer addresses than slots is a configuration, not a fault. The bar
        // only reacts to states that stop something right now.
        $('ii-bar').className = 'ii-bar' + (bad || iaBad || unconf ? ' bad' : '');
        $('ii-bar-items').innerHTML =
            '<span class="ii-b"><span>PA</span><b>' + esc(d.pa) + '</b></span>' +
            '<span class="ii-b"><span>Rolle</span><b class="' + (d.roleBad ? 'ii-bad' : '') + '">' +
                esc(d.roleShort || d.role) + '</b></span>' +
            (d.mc ? '<span class="ii-b"><span>Multicast</span><b>' + esc(d.mc) + '</b></span>' : '') +
            '<span class="ii-b"><span>Tunnel</span><b>' + d.tun.n + '/' + d.tun.max + '</b></span>' +
            '<span class="ii-b"><span>Buslast</span><b class="' + loadCls + '">' + pct(l.now) + '</b></span>' +
            '<span class="ii-b"><span>Laufzeit</span><b>' + esc(d.up) + '</b></span>';

        $('ii-ov').innerHTML =
            row('Rolle', esc(d.role), null, d.roleBad ? 'ii-bad' : '') +
            row('PA / Maske', esc(d.pa) + ' &middot; Maske ' + esc(d.mask) +
                (unconf ? ' &middot; <span class="ii-bad">nicht konfiguriert</span>' : ''),
                // Only when it is true: on a programmed device every sentence in WHY.cfg is false.
                unconf ? WHY.cfg : null) +
            row('Multicast', d.mc === undefined
                    ? na('Die Multicast-Adresse konnte nicht gelesen werden')
                    : esc(d.mc) + (d.ttl === undefined ? '' : ' &middot; TTL ' + d.ttl), WHY.mc) +
            row('Tunnel', d.tun.n + ' / ' + d.tun.max + ' aktiv') +
            (d.addIa ? row('Tunnel-Adressen', d.addIa.used + ' von ' + d.addIa.max + ' nutzbar',
                           WHY.addIa, iaBad ? 'ii-bad' : '') : '') +
            row('Weitergeleitet', '&rarr;IP ' + humanCount(d.rtIp) + ' &nbsp; &rarr;TP ' + humanCount(d.rtTp), WHY.routed) +
            row('Gefiltert', '&rarr;IP ' + humanCount(d.flIp) + ' &nbsp; &rarr;TP ' + humanCount(d.flTp), WHY.filt) +
            row('Gesendet', '&rarr;IP ' + humanCount(d.toIp) + ' &nbsp; &rarr;TP ' + humanCount(d.toTp), WHY.toIp) +
            // Empfang only where the firmware counts it (RP2040, ESP32).
            row('Verloren', '&rarr;IP ' + lostCell(lostIp) + ' &nbsp; &rarr;TP ' + lostCell(lostTp) +
                (d.rxDrop === undefined ? '' : ' &nbsp; Empfang ' + lostCell(rxDrop)),
                WHY.lost + (d.rxDrop === undefined ? '' : ' ' + WHY.rxDrop)) +
            row('Hop-Count 0', '&rarr;IP ' + humanCount(d.hop0Ip) + ' &nbsp; &rarr;TP ' + humanCount(d.hop0Tp), WHY.hop0) +
            row('Verlustmeldungen', humanCount(d.lostRx) + ' &nbsp; verlorene Telegramme ' + humanCount(d.lostRxN), WHY.lostRx) +
            row('&Uuml;berlastmeldungen', humanCount(d.busyRx), WHY.busyRx) +
            '<details class="ii-rowd ii-row-wide" data-k="Buslast"' + (openWhy.has('Buslast') ? ' open' : '') +
                '><summary class="ii-row wide">' +
                '<i>Buslast</i><b>' + spark(l.hist) +
                '<span class="' + loadCls + '">' + pct(l.now) + '</span> jetzt &middot; ' +
                pct(l.avg) + ' Mittel/' + (l.hist ? l.hist.length : 0) + '&nbsp;s &middot; ' +
                pct(l.peak) + ' Spitze &middot; ' + humanBytes(l.bps) + '/s' +
                ' &nbsp;<button class="ii-btn" id="ii-reset">Z&auml;hler zur&uuml;cksetzen</button></b>' +
                '<em title="Erkl\u00e4rung">?</em></summary>' +
                '<p class="ii-p">' + WHY.load + '</p></details>';
        wireWhy($('ii-ov'));
        $('ii-reset').addEventListener('click', function (e) {
            e.preventDefault();
            fetch('/ipro/reset', { method: 'POST' }).then(function () { load(); loadRoute(); });
        });

        // The assignment column only exists when tunnels are actually reserved in ETS - on a device
        // without reservations nothing changes.
        const resv = d.tun.resv || [];
        // The slot number is what the reserved-tunnel tab calls the row, so naming it here ties the two
        // views together. Only data tunnels have one: device-mgmt and busmon report no slot.
        const tunType = function (r) { return esc(r.t) + (r.s ? ' <span class="gray">(T' + (+r.s || 0) + ')</span>' : ''); };
        const COLS_A = [['t', 'Typ', tunType], ['pa', 'Adresse'], ['ip', 'Client']]
            // Built above from a number, so it passes through unescaped; a history row has no zut.
            .concat(resv.length ? [['zut', 'Zuteilung', function (r) { return r.zut || ''; }]] : [])
            .concat([['start', 'Start'], ['dur', 'Dauer'],
                     ['tg', 'Telegramme', tunTraffic],
                     ['zst', 'Zustand', tunState]]);
        if (resv.length) d.tun.act.forEach(function (a) {
            a.zut = a.z === 1 ? 'fest <span class="gray">(T' + (+a.slot || 0) + ')</span>'
                  : a.z === 2 ? 'Ausweichplatz' : 'frei vergeben';
        });
        const extra = d.tun.act.length - d.tun.n;
        $('ii-tn-head').innerHTML = d.tun.n + ' / ' + d.tun.max + ' Daten-Tunnel' +
            (extra > 0 ? ' &middot; ' + extra + ' weitere Verbindung' + (extra > 1 ? 'en' : '') : '') +
            (unconf ? ' <span class="tn-busmon">&#9888; Ger&auml;t nicht konfiguriert</span>'
                   // "nutzbar" is the property the device actually tests (tunIaHasDevicePart), and it
                   // covers BOTH causes: a x.y.255 placeholder and an empty entry. The banner only sees
                   // the sum, so it must not diagnose which -- the reserved tab says that per slot.
                   : iaBad ? ' <span class="tn-busmon">&#9888; Kein Tunnel hat eine eigene KNX-Adresse. ' +
                     'Bitte im KNX-Projekt zuweisen (Details im Tab &bdquo;Reservierte&ldquo;).</span>'
                   : iaThin ? ' <span class="gray">' + d.addIa.used + ' von ' + d.addIa.max +
                     ' Pl&auml;tzen mit eindeutiger Adresse</span>' : '');
        // Counts the ROWS of this table (every connection, not just the data tunnels of the heading).
        $('ii-tab-a').textContent = 'Aktiv' + (d.tun.act.length ? ' (' + d.tun.act.length + ')' : '');
        $('ii-tp-a').innerHTML = tbl(d.tun.act, COLS_A, 'Zurzeit ist kein Tunnel verbunden.', tunDetail, openA);
        wireWhy($('ii-tp-a')); // the "?" state must survive the 2 s refresh
        // The tab counts the RESERVED slots, not the slots -- the table itself lists them all.
        $('ii-tab-s').textContent = 'Reservierte' + (resv.length ? ' (' + resv.length + ')' : '');
        $('ii-tp-s').innerHTML = slotView(resv, d.tun.act, d.tun.max, d.tun.ia);
        histN = d.tun.histN || 0;
        $('ii-tab-h').textContent = 'Historie' + (histN ? ' (' + histN + ')' : '');
        if (!$('ii-tp-h').hidden && heavyDue('hist', forceHeavy)) loadHist();
        forceHeavy = false; // open tab, but not at the poll rate
    }

    // --- Routing: decisions, per-address counts, filter table ---

    let rtAll = false;


    // --- Filter table: routing mode per direction first, then main group > middle group > ranges ---
    // LCGRPCONFIG (PID 54 IP->line, PID 55 line->IP): bits 0-1 main groups 0-13, bits 2-3 main groups
    // 14-31; 1 pass all, 2 lock, 3 by filter table. The table only matters where a part says 3.
    const FT_AUTO_OPEN = 12;
    const FT_MODE = { 1: 'pass', 2: 'lock', 3: 'route' };
    const FT_MODE_TXT = { pass: 'alle durchlassen', lock: 'alle sperren', route: 'nach Filtertabelle', unk: 'unbekannt' };
    let ftSig = '', ftOpen = null, ftData = null;

    function escA(s) { return esc(s).replace(/'/g, '&#39;').replace(/"/g, '&quot;'); }
    function gaRaw(t) {
        const p = String(t).trim().split('/');
        if (p.length !== 3 || p.some(function (x) { return !/^\d+$/.test(x); })) return -1;
        const a = +p[0], b = +p[1], c = +p[2];
        return a <= 31 && b <= 7 && c <= 255 ? a * 2048 + b * 256 + c : -1;
    }
    function gaText(r) { return (r >> 11) + '/' + ((r >> 8) & 7) + '/' + (r & 255); }
    function rangeText(lo, hi) { return lo === hi ? gaText(lo) : gaText(lo) + '&nbsp;&ndash; ' + gaText(hi); }
    function nWord(n, one, many) { return n + '&nbsp;' + (n === 1 ? one : many); }
    function ftMode(cfg, raw) {
        if (cfg === undefined || cfg === null) return 'unk';
        return FT_MODE[raw < 0x7000 ? (cfg & 3) : ((cfg >> 2) & 3)] || 'unk';
    }
    function ftUsesTable(g) {
        return !!g && ['main', 'sub'].some(function (k) { return ftMode(g[k], 0) === 'route' || ftMode(g[k], 0x7000) === 'route'; });
    }
    function ftRanges(f) {
        return (f.ranges || []).map(function (r) {
            const p = r.split(' - ');
            const lo = gaRaw(p[0]), hi = p.length > 1 ? gaRaw(p[1]) : lo;
            return lo < 0 || hi < lo ? null : [lo, hi];
        }).filter(Boolean);
    }
    function ftComplete(f) { return (f.ranges_total || 0) <= (f.ranges || []).length; }

    function ftHead(f) {
        const g = f.lcgrp;
        if (!g) return '';
        const row = function (label, cfg) {
            const lo = ftMode(cfg, 0), hi = ftMode(cfg, 0x7000);
            return '<div class="ft-dir"><i>' + label + '</i><b class="m-' + lo + '">Hauptgruppen 0&ndash;13: ' + FT_MODE_TXT[lo] +
                '</b><b class="m-' + hi + '">Hauptgruppen 14&ndash;31: ' + FT_MODE_TXT[hi] + '</b></div>';
        };
        return '<div class="ft-head">' + row('IP &rarr; Linie', g.main) + row('Linie &rarr; IP', g.sub) + '</div>';
    }

    // What the router does with one address, per direction - the same decision as isRoutedGroupAddress().
    function ftVerdict(f, raw) {
        const g = f.lcgrp || {}, ranges = ftRanges(f);
        const one = function (label, cfg) {
            const m = ftMode(cfg, raw);
            let res = 'unbekannt', cls = 'unk';
            if (m === 'pass') { res = 'wird weitergeleitet (alle durchlassen)'; cls = 'ok'; }
            else if (m === 'lock') { res = 'wird nicht weitergeleitet (gesperrt)'; cls = 'no'; }
            else if (m === 'route') {
                // an unloaded or unused table answers "not in table" for every address (router_object.cpp)
                if (!f.loaded || f.inUse === false) { res = 'wird nicht weitergeleitet (Tabelle nicht aktiv)'; cls = 'no'; }
                else if (f.building !== undefined) { res = 'Tabelle wird noch gelesen'; }
                else if (ranges.some(function (r) { return raw >= r[0] && raw <= r[1]; })) { res = 'wird weitergeleitet (steht in der Tabelle)'; cls = 'ok'; }
                else if (ftComplete(f)) { res = 'wird nicht weitergeleitet (nicht in der Tabelle)'; cls = 'no'; }
                else res = 'unbekannt - die Liste ist unvollst&auml;ndig';
            }
            return '<span class="ft-v ' + cls + '">' + label + ': ' + res + '</span>';
        };
        return one('IP &rarr; Linie', g.main) + one('Linie &rarr; IP', g.sub);
    }
    function ftCheck() {
        const inp = $('ft-in'), out = $('ft-out');
        if (!inp || !out || !ftData) return;
        const v = inp.value.trim(), raw = gaRaw(v);
        out.innerHTML = !v ? '' : raw < 0 ? '<span class="ft-v unk">keine g&uuml;ltige Gruppenadresse (a/b/c)</span>' : ftVerdict(ftData, raw);
    }

    function ftNotes(f) {
        const used = ftUsesTable(f.lcgrp), known = !!f.lcgrp;
        const none = ' Wo &bdquo;nach Filtertabelle&ldquo; eingestellt ist, wird kein Gruppentelegramm weitergeleitet.</p>';
        if (!f.loaded)
            return used ? '<p class="ft-note err">Die Filtertabelle ist nicht geladen.' + none
                : '<p class="meta">Die Filtertabelle ist nicht geladen' +
                  (known ? ' und wird derzeit auch nicht verwendet.' : '.') + '</p>';
        if (known && used && f.inUse === false)
            return '<p class="ft-note err">Die Filtertabelle ist nicht aktiv.' + none;
        if (known && !used)
            return '<p class="ft-note warn">Die Filtertabelle wird derzeit nicht verwendet: Keine Richtung steht auf ' +
                '&bdquo;nach Filtertabelle&ldquo; (Parameter des Routers).</p>';
        if (used && f.inUse !== false && !f.count && f.building === undefined)
            return '<p class="ft-note err">Die Filtertabelle ist leer.' + none;
        return '';
    }

    function ftStrip(node) {
        const segs = node.segs.map(function (s) {
            return '<rect x="' + (s[0] & 255) + '" y="0" width="' + ((s[1] & 255) - (s[0] & 255) + 1) + '" height="10"/>';
        }).join('');
        const ticks = node.warn.map(function (w) { return '<rect class="w" x="' + (w.raw & 255) + '" y="0" width="1" height="10"/>'; }).join('');
        return '<svg class="ft-strip" viewBox="0 0 256 10" preserveAspectRatio="none" aria-hidden="true">' +
            '<rect class="bg" x="0" y="0" width="256" height="10"/>' + segs + ticks + '</svg>';
    }

    function ftTree(f, topF) {
        const tree = {};
        const put = function (raw) {
            const hg = raw >> 11, mg = (raw >> 8) & 7;
            tree[hg] = tree[hg] || {};
            return (tree[hg][mg] = tree[hg][mg] || { segs: [], warn: [] });
        };
        ftRanges(f).forEach(function (r) {   // split at middle-group borders
            for (let lo = r[0]; lo <= r[1];) {
                const end = Math.min(r[1], lo | 255);
                put(lo).segs.push([lo, end]);
                lo = end + 1;
            }
        });
        (topF || []).forEach(function (e) {
            const raw = gaRaw(e.ga);
            if (raw >= 0) put(raw).warn.push({ raw: raw, ga: e.ga, n: e.n, toIp: e.toIp });
        });
        const hgs = Object.keys(tree).map(Number).sort(function (a, b) { return a - b; });
        let lines = hgs.length;
        hgs.forEach(function (h) { lines += Object.keys(tree[h]).length; });
        if (ftOpen === null) {   // first draw: open it all when it is short, else only the main groups
            ftOpen = {};
            hgs.forEach(function (h) { ftOpen[h] = lines <= FT_AUTO_OPEN; });
        }
        const complete = ftComplete(f);
        const withAddr = hgs.filter(function (h) { return Object.keys(tree[h]).some(function (m) { return tree[h][m].segs.length; }); });
        let h = '<p class="meta ft-sum">' + nWord(f.count || 0, 'Adresse', 'Adressen') + ' in der Tabelle &middot; ' +
            (complete ? '' : 'mindestens ') + nWord(withAddr.length, 'Hauptgruppe', 'Hauptgruppen') + ' &middot; ' +
            nWord(f.ranges_total || 0, 'Bereich', 'Bereiche') + '</p>';
        h += '<div class="ft-tree' + (f.lcgrp && !ftUsesTable(f.lcgrp) ? ' idle' : '') + '">';
        hgs.forEach(function (hg) {
            const mgs = Object.keys(tree[hg]).map(Number).sort(function (a, b) { return a - b; });
            let n = 0, w = 0, used = 0;
            mgs.forEach(function (m) {
                tree[hg][m].segs.forEach(function (s) { n += s[1] - s[0] + 1; });
                if (tree[hg][m].segs.length) used++;
                w += tree[hg][m].warn.length;
            });
            h += '<details data-hg="' + hg + '"' + (ftOpen[hg] ? ' open' : '') + '><summary><b class="hg">' + hg + '</b><span class="cnt">' +
                nWord(n, 'Adresse', 'Adressen') + (used > 1 ? ' in ' + used + ' Mittelgruppen' : '') + '</span>' +
                (w ? '<span class="wtag">&#9888; ' + w + '</span>' : '') + '</summary>';
            mgs.forEach(function (mg) {
                const node = tree[hg][mg];
                let c = 0;
                node.segs.forEach(function (s) { c += s[1] - s[0] + 1; });
                const all = node.segs.map(function (s) { return rangeText(s[0], s[1]); });
                h += '<div class="ft-mg" title="' + escA(all.join(', ').replace(/&nbsp;&ndash;/g, ' -')) + '"><b class="mg">' + hg + '/' + mg +
                    '</b><span class="cnt">' + c + '</span>' + ftStrip(node) + '<span class="rg">' +
                    (!c ? '<span class="gray">keine</span>' : node.segs.length <= 3 ? all.join(', ') : nWord(node.segs.length, 'Bereich', 'Bereiche')) +
                    '</span></div>';
                node.warn.forEach(function (x) {
                    h += '<div class="ft-warn">&#9888; ' + esc(x.ga) + ' wurde ' + humanCount(x.n) + '&times; gefiltert (' +
                        (x.toIp ? 'Linie &rarr; IP' : 'IP &rarr; Linie') + ')</div>';
                });
            });
            h += '</details>';
        });
        h += '</div><p class="meta">' + (complete ? 'Adressen, die hier fehlen, werden bei &bdquo;nach Filtertabelle&ldquo; nicht weitergeleitet.'
            : 'Angezeigt werden nur die ersten ' + (f.ranges || []).length + ' von ' + f.ranges_total +
              ' Bereichen; die Adressenzahl oben ist vollst&auml;ndig.') + '</p>';
        return h;
    }

    function renderFilter(f, topF) {
        const pane = $('ii-rp-filt');
        if (!$('ft-in')) {   // built once: the check field and the open groups survive the polls
            pane.innerHTML = '<div id="ft-head"></div><div id="ft-notes"></div><div class="ft-check"><span class="k">GA pr&uuml;fen</span>' +
                '<input type="text" id="ft-in" placeholder="z.&nbsp;B. 1/4/30" spellcheck="false" autocomplete="off"><span id="ft-out"></span></div>' +
                '<div id="ft-body"></div>';
            $('ft-in').addEventListener('input', ftCheck);
            $('ft-body').addEventListener('toggle', function (e) {
                const hg = e.target.getAttribute && e.target.getAttribute('data-hg');
                if (hg !== null && ftOpen) ftOpen[hg] = e.target.open;
            }, true);
        }
        ftData = f;
        const sig = JSON.stringify([f, (topF || []).map(function (e) { return [e.ga, e.n, e.toIp]; })]);
        if (sig === ftSig) return;
        ftSig = sig;
        $('ft-head').innerHTML = ftHead(f);
        $('ft-notes').innerHTML = ftNotes(f);
        $('ft-body').innerHTML = !f.loaded ? ''
            // The device reads the 8 kB bitfield in slices so it never blocks its loop.
            : f.building !== undefined ? '<p class="meta">Die Filtertabelle wird gelesen &hellip; ' + f.building + '&nbsp;%</p>'
            : ftTree(f, topF);
        ftCheck();
    }

    function renderRoute(d) {
        const tr = d.trace || [];
        const shown = rtAll ? tr : tr.slice(0, 12);
        $('ii-tab-rt').textContent = 'Letzte' + (tr.length ? ' (' + tr.length + (d.size && tr.length >= d.size ? ', voll' : '') + ')' : '');
        $('ii-rp-rt').innerHTML = tr.length
            ? (tr.length > 12
                ? '<p class="meta" style="margin:0 0 6px">' + shown.length + ' von ' + tr.length + ' Zeilen &nbsp;' +
                  '<button class="ii-btn" id="ii-rt-more">' + (rtAll ? 'weniger' : 'alle ' + tr.length) + '</button></p>'
                : '') +
              '<table><thead><tr><th>Zeit</th><th>Richtung</th><th>Hop</th><th>Ziel</th><th>Von</th>' +
              '<th>Entscheidung</th></tr></thead><tbody>' +
              shown.map(function (e) {
                  const cls = e.act === 'weitergeleitet' ? '' : e.act === 'gefiltert' ? 'gray' : 'ii-warn';
                  return '<tr><td>' + esc(e.t) + '</td><td>' + (e.toIp ? '&rarr;IP' : '&rarr;TP') +
                         '</td><td class="' + (e.hop <= 1 ? 'ii-warn' : 'gray') + '">' + e.hop +
                         '</td><td>' + esc(e.dst) + '</td><td>' + esc(e.src) +
                         '</td><td class="' + cls + '">' + esc(e.act) + '</td></tr>';
              }).join('') + '</tbody></table>'
            : '<p class="meta">Noch nichts weitergeleitet.</p>';
        if ($('ii-rt-more'))
            $('ii-rt-more').addEventListener('click', function (e) { e.preventDefault(); rtAll = !rtAll; renderRoute(d); });

        function topList(list, title, cls) {
            const all = list;
            // Percentages are the share of everything this table counted, not of the eight shown.
            const sum = list.reduce(function (a, b) { return a + b.n; }, 0) || 1;
            const rows = list.slice(0, 8).map(function (e) {
                return '<div class="ii-row"><i>' + esc(e.ga) + '</i><b class="' + cls + '" style="flex:0 0 4em">' +
                       (e.toIp ? '&rarr;IP' : '&rarr;TP') + '</b><b>' + humanCount(e.n) +
                       ' <span class="ii-sub">' + Math.round(e.n * 100 / sum) + '&nbsp;%</span></b></div>';
            }).join('');
            return head(title + (all.length > 8 ? ' <span class="gray">(8 von ' + all.length + ')</span>' : '')) +
                   (rows || '<div class="ii-row"><i>-</i><b class="gray">noch nichts</b></div>');
        }
        $('ii-tab-top').textContent = 'H\u00e4ufigste' +
            ((d.topF || []).length + (d.topR || []).length ? ' (' + ((d.topF || []).length + (d.topR || []).length) + ')' : '');
        $('ii-rp-top').innerHTML =
            '<div>' + topList(d.topF || [], 'Gefiltert', 'gray') + '</div>' +
            '<div>' + topList(d.topR || [], 'Weitergeleitet', '') + '</div>' +
            '<p class="meta ii-row-wide" style="margin:8px 0 0">Gez&auml;hlt seit ' + esc(d.since) +
            '. &bdquo;Z&auml;hler zur&uuml;cksetzen&ldquo; in der &Uuml;bersicht beginnt neu.</p>';

        const f = d.filt;
        // only requested while the tab is open
        if (!f) return;
        // The tab counts what the list below shows: ranges. Counting addresses there was misleading -
        // 64 small ranges under a headline of 64.2k, with the big block hidden by the cap.
        $('ii-tab-filt').textContent = 'Filtertabelle' +
            (f.ranges_total !== undefined ? ' (' + f.ranges_total + ')' : '');
        renderFilter(f, d.topF);
    }

    // --- Bus + diagnostics (only fetched while the section is open) ---

    const NOAPI = 'Der Treiber dieser Firmware liefert diesen Wert nicht';

    function renderBus(b) {
        // No TP link (early boot, no driver): the endpoint answers {} - say so instead of throwing.
        if (!b.state) { $('ii-bus').innerHTML = '<p class="meta">Keine TP-Verbindung</p>'; return; }
        const railCls = function (ok) { return ok ? 'ii-ok' : 'ii-bad'; };
        let h = '<div class="ii-grid">' +
            head('Status') +
            row('Zustand', esc(b.state), null,
                b.state === 'Connected' ? 'ii-ok' : b.state === 'Busmonitor' ? 'ii-warn' : 'ii-bad') +
            row('Baudrate', b.baud) +
            row('Chip AutoACK', b.autoack === undefined ? na(NOAPI) : (b.autoack ? 'ON' : 'off')) +
            row('Chip CRC', b.crc === undefined ? na(NOAPI) : (b.crc ? 'CCITT' : 'off')) +
            head('Verkehr') +
            row('TX Rahmen', humanCount(b.tx) +
                (b.state === 'Busmonitor' ? ' <span class="ii-sub">(Busmonitor: kein Senden)</span>' : '')) +
            row('RX Rahmen', humanCount(b.rxF) + ' (' + humanBytes(b.rxB) + ')') +
            row('Verworfen', humanBytes(b.disc)) +
            row('Empfangen', humanBytes(b.recv)) +
            row('Last', humanBytes(b.bps) + '/s') +
            row('Suchpuffer', b.buf) +
            row('Erwartet', b.await) +
            row('Wiederholungen', humanCount(b.rep), WHY.rep, b.rep > 50 ? 'ii-bad' : '') +
            row('&Uuml;berlauf U/S/R/T', b.ovf.map(humanCountShort).join('/'), WHY.ovf,
                b.ovf.some(function (v) { return v > 0; }) ? 'ii-warn' : '') +
            row('ACK verworfen', b.ack === undefined ? na(NOAPI) : humanCount(b.ack), WHY.ackDrop,
                b.ack ? 'ii-warn' : '') +
            row('ByteErr FE/PE/BE/OE', b.be
                ? (b.be[1] > 100 ? '<span class="ii-bad">' + b.be.map(humanCountShort).join('/') + '</span>'
                                 : b.be.map(humanCountShort).join('/'))
                : na('Diese Firmware f&uuml;hrt die Byte-Fehlerz&auml;hler nicht'), WHY.byteErr);

        if (!b.health)
            h += head('Gesundheit') +
                row('Resets, CON-Rettungen, NCN-Fehler',
                    na('Diese Firmware f&uuml;hrt die BCU-Health-Z&auml;hler nicht'));
        if (b.health)
            h += head('Gesundheit') +
                row('Resets', humanCount(b.health.rst), null, b.health.rst ? 'ii-warn' : '') +
                row('Disconnects', humanCount(b.health.dis), null, b.health.dis ? 'ii-warn' : '') +
                row('CON-Rettungen', humanCount(b.health.con), WHY.con, b.health.con ? 'ii-warn' : '') +
                head('NCN-Fehler') +
                row('Slave-Kollisionen', humanCount(b.health.sc), WHY.sc, b.health.sc ? 'ii-warn' : '') +
                row('Empfangsfehler', humanCount(b.health.re), null, b.health.re ? 'ii-bad' : '') +
                row('Sendefehler', humanCount(b.health.te), null, b.health.te ? 'ii-warn' : '') +
                row('Protokollfehler', humanCount(b.health.pe)) +
                row('Temperaturwarnungen', humanCount(b.health.tw));
        h += '</div>';

        // In busmonitor the driver does not poll the chip, so the last reading is not a measurement.
        if (b.rails && !b.rails.seen)
            h += '<div class="ii-grid">' + head('NCN-Schienen') +
                 row('Schienen', na('Noch keine Antwort des Chips gelesen')) + '</div>';
        else if (b.rails && b.rails.stale)
            h += '<div class="ii-stale"><div class="ii-stalehead">&#9888; NCN-Schienen: veraltet, Busmonitor aktiv' +
                 (b.rails.since ? '<em>seit ' + esc(b.rails.since) + ' nicht abgefragt</em>' : '') +
                 '</div><div class="ii-grid">' +
                 row('VBUS', b.rails.vbus ? 'ok' : 'LOW') + row('VFILT', b.rails.vfilt ? 'ok' : 'LOW') +
                 row('V20V', b.rails.v20v ? 'ok' : 'LOW') + row('VDD2', b.rails.vdd2 ? 'ok' : 'LOW') +
                 row('XTAL', b.rails.xtal ? 'ok' : 'FAIL') + row('Modus', esc(b.rails.mode)) +
                 '</div><p class="ii-p" style="padding-left:0">Letzter Stand vor dem Busmonitor, kein aktueller ' +
                 'Befund: LOW und FAIL sind hier die Einschaltwerte.</p></div>';
        else if (b.rails)
            h += '<div class="ii-grid">' + head('NCN-Schienen') +
                 row('VBUS', b.rails.vbus ? 'ok' : 'LOW', null, railCls(b.rails.vbus)) +
                 row('VFILT', b.rails.vfilt ? 'ok' : 'LOW', null, railCls(b.rails.vfilt)) +
                 row('V20V', b.rails.v20v ? 'ok' : 'LOW', null, railCls(b.rails.v20v)) +
                 row('VDD2', b.rails.vdd2 ? 'ok' : 'LOW', null, railCls(b.rails.vdd2)) +
                 row('XTAL', b.rails.xtal ? 'ok' : 'FAIL', null, railCls(b.rails.xtal)) +
                 row('Modus', esc(b.rails.mode), null, b.rails.mode === 'Normal' ? 'ii-ok' : 'ii-warn') +
                 '</div>';
        else
            h += '<div class="ii-grid">' + head('NCN-Schienen') +
                 row('Schienen und Chip', na('Diese Firmware liest die NCN-Register nicht')) + '</div>';

        if (b.chip)
            h += '<div class="ii-grid">' + head('NCN-Chip') +
                 row('Chip', b.chip.name === null
                        ? na('Nicht identifiziert, RevID 0x' + ('0' + Number(b.chip.revId).toString(16)).slice(-2))
                        : esc(b.chip.name) + (b.chip.inferred ? ' <span class="ii-sub">(abgeleitet)</span>' : '')) +
                 row('Silizium-Revision', b.chip.rev === null ? '-' : b.chip.rev) +
                 row('Thermal-Shutdown', b.chip.tsd === null
                        ? na('ASR0 hat nicht geantwortet')
                        : (b.chip.tsd ? '<span class="ii-warn">ja (Historie)</span>' : 'nein')) +
                 '</div>';

        $('ii-bus').innerHTML = h;
        wireWhy($('ii-bus'));
        $('ii-bus-sum').innerHTML = esc(b.state) + ' &middot; ' + b.baud + ' Bd &middot; Wdh. ' + humanCount(b.rep) +
            (b.rails && b.rails.stale ? ' &middot; Schienen veraltet' : '');
    }

    // --- Polling ---

    // The routing document is the largest one this page fetches. It is only worth building while the
    // section is actually on screen - the bus block does the same via its <details>.
    let rtVisible = true, rtAgain = false;
    if (window.IntersectionObserver && $('ii-rtabs')) {
        rtVisible = false;
        new IntersectionObserver(function (es) {
            const now = es[0].isIntersecting;
            if (now && !rtVisible) { rtVisible = true; loadRoute(); } else { rtVisible = now; }
        }, { rootMargin: '120px' }).observe($('ii-rtabs'));
    }
    async function loadRoute() {
        if (!$('ii-rp-rt') || document.hidden || !rtVisible) return;
        // a tab click during a poll must not be swallowed
        if (rtBusy) { rtAgain = true; return; }
        rtBusy = true;
        try {
            // The filter table is an 8 kB scan on the device - only ask for it while its tab is open.
            const wantFilter = !$('ii-rp-filt').hidden;
            const r = await fetch('/ipro/route' + (wantFilter ? '?filt=1' : ''), { cache: 'no-store' });
            if (!r.ok) throw 0;
            renderRoute(await r.json());
        } catch (e) {
            $('ii-rp-rt').innerHTML = '<p class="meta">nicht verfügbar</p>';
        } finally {
            rtBusy = false;
            if (rtAgain) { rtAgain = false; loadRoute(); }
        }
    }

    // The finished connections change only on connect/disconnect and sit behind a tab that is not the
    // default - so they travel on their own endpoint instead of in every 2-second poll.
    let histN = 0, histBusy = false;
    async function loadHist() {
        if (histBusy || document.hidden || $('ii-tp-h').hidden) return;
        histBusy = true;
        try {
            const r = await fetch('/ipro/hist', { cache: 'no-store' });
            if (!r.ok) throw 0;
            const d = await r.json();
            const COLS_A = [['t', 'Typ'], ['pa', 'Adresse'], ['ip', 'Client'], ['start', 'Start'], ['dur', 'Dauer']];
            $('ii-tp-h').innerHTML = tbl(d.hist || [], COLS_A.concat([['reason', 'Ende', tunEnde], ['det', 'Code'],
                    ['tg', 'Telegramme', tunTraffic], ['zst', 'Zustand', tunState]]),
                                         'Noch keine beendeten Verbindungen.', tunDetail, openH);
            wireWhy($('ii-tp-h'));
        } catch (e) {
            $('ii-tp-h').innerHTML = '<p class="meta">nicht verf\u00fcgbar</p>';
        } finally { histBusy = false; }
    }

    // Refresh control at the right end of the status bar. It lives outside the part that is rewritten
    // on every tick, otherwise an open menu would be torn down while it is being used. The chosen
    // interval is not remembered; the arrow reloads at once and is the only way while it is off.
    // 500 ms is below the device's own 1 Hz bus-load sampler: the counters get fresher, the load
    // figure simply repeats. Offered, not default -- it doubles the JSON the device builds.
    const POLL_STEPS = [1000, 2000, 5000, 10000, 30000, 60000, 0];
    let pollMs = POLL_MS, pollTimer = 0;

    // The status endpoint follows the chosen interval; the heavier panels do not -- that throttle is
    // what keeps the device from building three JSON documents per tick at the fastest setting.
    const heavyAt = {};
    function heavyDue(k, force) {
        const t = new Date().getTime();
        if (!force && t - heavyAt[k] < 2000) return false;
        heavyAt[k] = t;
        return true;
    }
    // Consumed by renderState() for the history panel: threading it through load() would mean carrying
    // the intent across an await, where it no longer belongs to this click.
    let forceHeavy = false;
    function pollTick(force) { forceHeavy = !!force; load(); if (heavyDue('bus', force)) { loadBus(); loadRoute(); } }

    function applyPoll(ms) {
        pollMs = ms;
        if (pollTimer) clearInterval(pollTimer);
        // Wrapped: as a raw callback pollTick would receive the host's timer argument as `force`,
        // which switches off the heavyDue throttle on every tick.
        pollTimer = ms ? setInterval(function () { pollTick(); }, ms) : 0;
    }

    function buildPoll() {
        const ms = POLL_MS; // deliberately not remembered: reloading the page starts at the default again
        $('ii-poll').innerHTML =
            '<button class="ii-rf" id="ii-rf" title="Jetzt aktualisieren" aria-label="Jetzt aktualisieren">&#8635;</button>' +
            '<select class="ii-rfs" id="ii-rfs" title="Aktualisierungsintervall">' +
            POLL_STEPS.map(function (v) {
                return '<option value="' + v + '"' + (v === ms ? ' selected' : '') + '>' +
                       (v ? (v < 1000 ? v + '&thinsp;ms' : (v / 1000) + '&thinsp;s') : 'aus') + '</option>';
            }).join('') + '</select>';
        $('ii-rf').addEventListener('click', function () { pollTick(true); });
        $('ii-rfs').addEventListener('change', function () { applyPoll(+this.value); });
        applyPoll(ms);
    }

    async function load() {
        if (busy || document.hidden) return;
        busy = true;
        try {
            const r = await fetch('/ipro/state', { cache: 'no-store' });
            if (!r.ok) throw 0;
            $('ii-ov').classList.remove('gray');
            renderState(await r.json());
        } catch (e) {
            // Do not leave the last good values standing as if they were current.
            $('ii-head').textContent = 'nicht verfügbar';
            $('ii-bar').className = 'ii-bar bad';
            $('ii-ov').classList.add('gray');
        } finally { busy = false; }
    }

    async function loadBus() {
        if (busBusy || document.hidden || !$('ii-sec-bus').open) return;
        busBusy = true;
        try {
            const r = await fetch('/ipro/bus', { cache: 'no-store' });
            if (!r.ok) throw 0;
            renderBus(await r.json());
        } catch (e) {
            $('ii-bus').innerHTML = '<p class="meta">nicht verfügbar</p>';
        } finally { busBusy = false; }
    }

    $('ii-sec-bus').addEventListener('toggle', function () { if (this.open) loadBus(); });

    wireTun($('ii-tp-a'), openA);
    wireTun($('ii-tp-h'), openH);

    // Two independent tab strips on this page; each switches only its own panels.
    function wireTabs(stripId, panePrefix, onSwitch) {
        const strip = $(stripId);
        if (!strip) return;
        const tabs = strip.querySelectorAll('.tn-tab');
        tabs.forEach(function (t) {
            t.addEventListener('click', function () {
                tabs.forEach(function (o) {
                    const on = (o === t);
                    o.classList.toggle('active', on);
                    $(panePrefix + o.dataset.t).hidden = !on;
                });
                if (onSwitch) onSwitch();
            });
        });
    }
    // Stamped with the call: without it the next renderState sees no timestamp, heavyDue() returns true
    // and fetches the same document a second time, back to back.
    wireTabs('ii-tabs', 'ii-tp-', function () { heavyDue('hist'); loadHist(); });
    // opening the filter tab must fetch it at once
    wireTabs('ii-rtabs', 'ii-rp-', loadRoute);

    // A tab restored as open by the browser must fill immediately, not only on the next toggle.
    document.addEventListener('visibilitychange', function () {
        if (!document.hidden) { load(); loadBus(); loadRoute(); }
    });

    load();
    loadBus();
    loadRoute();
    buildPoll();
})();
