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
               '<p class="meta ii-row-wide" style="margin:8px 0 0">In dieser Reihenfolge entschieden: ' +
               '<span class="tn-p ok">&#9679;&nbsp;belegt</span> = ein Client ist verbunden &middot; ' +
               '<span class="tn-p bad">&#8856;&nbsp;nicht erreichbar</span> = f&uuml;r 0.0.0.0 reserviert, ' +
               'erreicht keinen Client und bleibt f&uuml;r andere gesperrt &middot; ' +
               '<span class="tn-p warn">&#9888;&#65038;&nbsp;Adresse nicht eindeutig</span> = der Platz ' +
               'teilt sich die Adresse mit einem anderen. Gleichzeitig nutzbar ist jede Adresse nur ' +
               'einmal, deshalb sinkt die Zahl der parallel m&ouml;glichen Tunnel &middot; ' +
               '<span class="tn-p idle">&#9675;&nbsp;frei</span> = nicht reserviert &middot; ' +
               '<span class="tn-p idle">&#9680;&nbsp;reserviert</span> = wartet auf genau eine IP.</p>';
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
        '<b>Z&auml;hler:</b> <b>&rarr;</b> = an den Client, <b>&larr;</b> = vom Client &middot; ' +
        '<b>Wiederholungen</b> = ohne Quittung nochmal gesendet &middot; ' +
        '<b>Queue max</b> = Spitze der Sendewarteschlange, voll ist normal &middot; ' +
        '<b>Verworfen</b> = nie gesendet &middot; ' +
        '<b>&Uuml;berlast</b> = Gruppentelegramme bei voller Warteschlange fallengelassen, damit die Verbindung ' +
        'stehen bleibt &middot; <b>Sequenzfehler</b> = falsche Nummer, verworfen &middot; ' +
        '<b>Letzter Kontakt</b> = seit letztem Lebenszeichen' +
        '<br><b>Zustand</b> &mdash; <span class="tn-p ok">ok</span> = nichts aufgelaufen &middot; ' +
        '<span class="tn-p warn">n Hinweise</span> = so viele der Z&auml;hler Wiederholungen, ' +
        'Verworfen, &Uuml;berlast und Sequenzfehler stehen nicht auf 0; welche, zeigt die ' +
        'aufgeklappte Zeile &mdash; <b>Verworfen</b> ist dort als einziger echter Verlust rot. ' +
        'Die Zahlen sind Summen seit Verbindungsbeginn und sinken nie &middot; ' +
        '<span class="gray">&ndash;</span> = nicht messbar' +
        '<br><b>Zuteilung</b>: <b>fest</b> = der f&uuml;r diesen Client reservierte Platz &middot; ' +
        '<b>Ausweichplatz</b> = sein reservierter Platz war belegt, er sitzt auf einem anderen &middot; ' +
        '<b>frei vergeben</b> = keine Reservierung im Spiel';
    const TUN_WHY_BM = ' &middot; Busmonitor: kein Sendepuffer, keine Empfangsrichtung';
    // Only the history has an Ende column; explaining it on an active row describes a column that
    // is not on screen. A history row is the one carrying a reason.
    const TUN_WHY_END = '<br><b>Ende</b> &mdash; orange, wenn niemand die Trennung verlangt hat';

    function tunDetail(r) {
        if (r.tc === undefined) return ''; // refused connect: the Ende column already says why
        const d = function (v) { return v === undefined ? '<span class="gray">&ndash;</span>' : v; };
        // Third element: the severity this entry carries once its counter is not zero. The column
        // above only counts the findings, so this is where "how bad" is said -- Verworfen is the
        // only one of them that is a real loss. Queue max is not a finding, full is normal.
        const kv = [['Wiederholungen', d(r.rs), r.rs ? ' class="warn"' : ''],
                    ['Queue max', r.qd === undefined ? d(undefined) : r.qp + '&nbsp;/&nbsp;' + r.qd, ''],
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

    // An expert number without its meaning is what turned a healthy device into a power-supply hunt.
    const WHY = {
        byteErr: 'FE = Leitung zum Chip (Baudrate, Verkabelung). PE = Bitfehler vom Bus. BE = Break. ' +
                 'OE = der Host war zu langsam.',
        rep: 'Keine Quittung, der Sender hat wiederholt. Steigt bei schlechter Leitung oder &uuml;berlastetem Ger&auml;t.',
        ovf: 'UART, Suchpuffer, Rahmenpuffer, Sendepuffer. Jeder Anstieg hei&szlig;t verworfen - nicht nur wiederholt.',
        ackDrop: 'Die Quittung kam zu sp&auml;t auf den Bus, der Sender wiederholt.',
        con: 'Der Chip blieb eine Sendebest&auml;tigung schuldig, der Treiber hat sie nachgezogen. Dauernd = Chipstress.',
        sc: 'Zwei Teilnehmer haben gleichzeitig gesendet. Einzeln normal, dauerhaft hoch = Adress- oder Leitungsproblem.',
        lost: 'Warteschlange voll - diese Telegramme wurden nie gesendet.',
        // All four values, because all four are on the row. The >100 % note is not a caveat: frames
        // are booked in the second they COMPLETE (BusLoad.h), so a long telegram can overfill one.
        load: 'Anteil der Zeit, in der die TP1-Linie belegt war (9600&nbsp;bit/s). ' +
              '<b>jetzt</b> = letzte Sekunde &middot; <b>Mittel</b> = seit Start/Zur&uuml;cksetzen, max. 60&nbsp;s &middot; ' +
              '<b>Spitze</b> = h&ouml;chster Sekundenwert seit Start oder Zur&uuml;cksetzen &middot; ' +
              '<b>B/s</b> = empfangene Bytes der letzten Sekunde. &Uuml;ber 100&nbsp;% m&ouml;glich: ein ' +
              'Telegramm z&auml;hlt in der Sekunde, in der es endet.',
        toIp: 'Jedes KNXnet/IP-Paket, nicht nur Gruppentelegramme.',
        cfg: 'Das Ger&auml;t hat noch keine Konfiguration erhalten: es tr&auml;gt die Vorgabeadresse ' +
             '15.15.255 und keine Filtertabelle. Damit ein Tunnel &uuml;berhaupt zustande kommt, vergibt es sich ' +
             'die Tunneladressen selbst - vorl&auml;ufig, bis ein Download sie ersetzt.',
        addIa: 'Jeder Tunnel braucht eine eigene KNX-Adresse. Die Zahl sagt, wie viele Pl&auml;tze eine ' +
               '<b>eindeutige</b> haben. Teilen sich mehrere Pl&auml;tze eine Adresse, verbinden sie ' +
               'trotzdem &mdash; jede Adresse ist aber nur einmal gleichzeitig in Benutzung, es k&ouml;nnen ' +
               'also weniger Clients parallel arbeiten. Welcher Platz welche Adresse hat, steht im Tab ' +
               '&bdquo;Reservierte&ldquo;.',
        routed: 'Vom Router weitergegeben.',
        filt: 'Vom Filter absichtlich verworfen - kein Verlust.',
        hop0: 'Kopplerdurchg&auml;nge aufgebraucht, wird nicht weitergereicht. Absicht ' +
              '(Routing Count 0) oder eine Schleife im Netz.'
    };

    // --- Overview + status line ---

    function renderState(d) {
        const l = d.load;
        const loadCls = l.now >= 500 ? 'ii-bad' : l.now >= 200 ? 'ii-warn' : 'ii-ok';
        const bad = d.lostTp > 0;

        $('ii-head').innerHTML = d.tun.n + '&nbsp;/&nbsp;' + d.tun.max + ' Tunnel &middot; Buslast ' + pct(l.now);

        // No usable tunnel address means no client can connect at all -- a blocking fault, so it
        // colours the row and the status bar, not just the tunnel header.
        // Unprogrammed is the root state: no tunnel addresses, no group objects, PA 15.15.255. It
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
                (unconf ? ' &middot; <span class="ii-bad">nicht programmiert</span>' : ''),
                // Only when it is true: on a programmed device every sentence in WHY.cfg is false.
                unconf ? WHY.cfg : null) +
            row('Multicast', d.mc === undefined
                    ? na('Die Multicast-Adresse konnte nicht gelesen werden')
                    : esc(d.mc) + (d.ttl === undefined ? '' : ' &middot; TTL ' + d.ttl)) +
            row('Tunnel', d.tun.n + ' / ' + d.tun.max + ' aktiv') +
            (d.addIa ? row('Zus&auml;tzliche IAs', d.addIa.used + ' von ' + d.addIa.max + ' nutzbar',
                           WHY.addIa, iaBad ? 'ii-bad' : '') : '') +
            row('Weitergeleitet', '&rarr;IP ' + humanCount(d.rtIp) + ' &nbsp; &rarr;TP ' + humanCount(d.rtTp), WHY.routed) +
            row('Gefiltert', '&rarr;IP ' + humanCount(d.flIp) + ' &nbsp; &rarr;TP ' + humanCount(d.flTp), WHY.filt) +
            row('Telegramme', '&rarr;IP ' + humanCount(d.toIp) + ' &nbsp; &rarr;TP ' + humanCount(d.toTp), WHY.toIp) +
            row('Verloren (Queue)', '&rarr;IP ' + humanCount(d.lostIp) + ' &nbsp; &rarr;TP ' +
                (d.lostTp ? '<span class="ii-bad">' + humanCount(d.lostTp) + '</span>' : '0'), WHY.lost) +
            row('Hop-Count 0', '&rarr;IP ' + humanCount(d.hop0Ip) + ' &nbsp; &rarr;TP ' + humanCount(d.hop0Tp), WHY.hop0) +
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
            (unconf ? ' <span class="tn-busmon">&#9888; Ger&auml;t nicht programmiert</span>'
                   // "nutzbar" is the property the device actually tests (tunIaHasDevicePart), and it
                   // covers BOTH causes: a x.y.255 placeholder and an empty entry. The banner only sees
                   // the sum, so it must not diagnose which -- the reserved tab says that per slot.
                   : iaBad ? ' <span class="tn-busmon">&#9888; Kein Platz hat eine eigene Adresse - alle ' +
                     'sind leer oder Platzhalter. Jedem Tunnel eine Adresse zuweisen (Details im Tab ' +
                     '&bdquo;Reservierte&ldquo;).</span>'
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


    // The list is capped, so the addresses in the ranges that are not shown have to be named -- a
    // single hidden range can hold more addresses than all listed ones together.
    function gaRaw(t) {
        const p = t.split('/');
        return (+p[0]) * 2048 + (+p[1]) * 256 + (+p[2]);
    }
    function filterView(f) {
        let shown = 0;
        f.ranges.forEach(function (r) {
            const p = r.split(' - ');
            shown += p.length > 1 ? gaRaw(p[1]) - gaRaw(p[0]) + 1 : 1;
        });
        const hidden = f.count - shown;
        const share = Math.round(f.count * 100 / 65535);
        return '<p class="meta" style="margin:0 0 8px">' + f.ranges_total + '&nbsp;Bereiche &middot; ' +
            f.count + ' von 65535 Adressen (' + share + '&nbsp;%) l&auml;sst der Router durch.</p>' +
            '<div class="ii-grid">' +
            f.ranges.map(function (r) { return '<div class="ii-row"><b>' + esc(r) + '</b></div>'; }).join('') +
            '</div><p class="meta" style="margin:8px 0 0">' +
            (f.ranges_total > f.ranges.length
                ? 'Aufgef&uuml;hrt sind die ersten ' + f.ranges.length + ' Bereiche mit ' + shown +
                  ' Adressen. In den &uuml;brigen ' + (f.ranges_total - f.ranges.length) + ' liegen ' +
                  hidden + ' weitere Adressen.'
                : 'Alles andere verwirft er.') + '</p>';
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
            '<p class="meta ii-row-wide" style="margin:8px 0 0">Dauerz&auml;hler seit ' + esc(d.since) +
            ', nicht die Liste von nebenan. Der Knopf &bdquo;Z&auml;hler zur&uuml;cksetzen&ldquo; in der ' +
            '&Uuml;bersicht und <code>ipro reset</code> l&ouml;schen beides.</p>';

        const f = d.filt;
        // only requested while the tab is open
        if (!f) return;
        // The tab counts what the list below shows: ranges. Counting addresses there was misleading -
        // 64 small ranges under a headline of 64.2k, with the big block hidden by the cap.
        $('ii-tab-filt').textContent = 'Filtertabelle' +
            (f.ranges_total !== undefined ? ' (' + f.ranges_total + ')' : '');
        $('ii-rp-filt').innerHTML = !f.loaded
            ? '<p class="meta">Die Filtertabelle ist nicht geladen - sie wurde noch nicht programmiert.</p>'
            // The device reads the 8 kB bitfield in slices so it never blocks its loop.
            : f.building !== undefined
                ? '<p class="meta">Die Filtertabelle wird gelesen &hellip; ' + f.building + '&nbsp;%</p>'
            : !f.inUse
                ? '<p class="meta">Die Filtertabelle ist abgeschaltet - es wird nichts gefiltert.</p>'
                : !f.count
                    // Loaded, in use and empty: nothing passes. That is exactly what the list next door
                    // shows, so say it here instead of promising addresses that do not exist.
                    ? '<p class="meta">Die Filtertabelle ist leer - kein Gruppentelegramm kommt durch. ' +
                      'Entweder ist nichts eingetragen oder sie wurde nicht programmiert.</p>'
                : filterView(f);
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
