// Tunnel status: who is connected right now, and the finished sessions.
// The device already formats every field (IP, PA, start, duration, reason), so this only builds tables.
(function () {
    const $ = function (id) { return document.getElementById(id); };
    const head = $('tn-head');
    if (!head) return;

    const act = $('tn-active'), hist = $('tn-hist');
    let busy = false;

    // Column sets per tab; the device sends the same key names.
    const COLS_ACT = [['t', 'Typ'], ['pa', 'Adresse'], ['ip', 'Client'], ['start', 'Start'], ['dur', 'Dauer']];
    const COLS_HIST = COLS_ACT.concat([['reason', 'Ende'], ['det', 'Code']]);

    function table(rows, cols, empty) {
        if (!rows.length) {
            const p = document.createElement('p');
            p.className = 'meta';
            p.textContent = empty;
            return p;
        }
        const t = document.createElement('table');
        const hr = t.createTHead().insertRow();
        cols.forEach(function (c) {
            const th = document.createElement('th');
            th.textContent = c[1];
            hr.appendChild(th);
        });
        const body = t.createTBody();
        rows.forEach(function (r) {
            const tr = body.insertRow();
            cols.forEach(function (c) { tr.insertCell().textContent = r[c[0]] || ''; });
        });
        return t;
    }

    function render(d) {
        const a = d.active || [], h = d.hist || [];
        head.textContent = a.length + ' / ' + d.max + ' aktiv';
        if (d.busmon) {
            const w = document.createElement('span');
            w.className = 'tn-busmon';
            w.textContent = '  ⚠ HW-Busmonitor aktiv - Bus-TX pausiert, keine neuen Tunnel';
            head.appendChild(w);
        }
        act.textContent = '';
        act.appendChild(table(a, COLS_ACT, 'Zurzeit ist kein Tunnel verbunden.'));
        hist.textContent = '';
        hist.appendChild(table(h, COLS_HIST, 'Noch keine beendeten Verbindungen.'));
        $('tn-tab-h').textContent = 'Historie' + (h.length ? ' (' + h.length + ')' : '');
    }

    async function load() {
        if (busy || document.hidden) return;
        busy = true;
        try {
            const r = await fetch('/tunnels/state', { cache: 'no-store' });
            if (!r.ok) throw 0;
            render(await r.json());
        } catch (e) {
            head.textContent = 'nicht verfügbar';
        } finally { busy = false; }
    }

    const tabs = document.querySelectorAll('.tn-tab');
    tabs.forEach(function (t) {
        t.addEventListener('click', function () {
            tabs.forEach(function (o) {
                const on = (o === t);
                o.classList.toggle('active', on);
                $('tn-p-' + o.dataset.t).hidden = !on;
            });
        });
    });

    load();
    setInterval(load, 3000);
})();
