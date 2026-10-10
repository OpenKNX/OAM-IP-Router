#!/usr/bin/env python3
"""Verify a BCU MARKER capture and emit the complete evidence.

Three things are decided from the data, not assumed:
  1. the marker octets CB 13 sit directly behind the frame check octet
  2. which CRC-16 variant actually matches (four candidates computed, none asserted)
  3. whether a data octet 0xCB is doubled by the chip

0xCB is un-doubled before the length check, because the doubling is transport stuffing
towards the host: FCS and CRC are computed over the frame WITHOUT it. A parser that skips
this breaks on exactly those frames - which is the reason for the test.
"""
import re, sys, collections

def crc16(data, init, poly=0x1021, refin=False, refout=False, xorout=0x0000):
    rev = lambda b, n: int(f'{b:0{n}b}'[::-1], 2)
    crc = init
    for b in data:
        if refin: b = rev(b, 8)
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ poly) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    if refout: crc = rev(crc, 16)
    return crc ^ xorout

VARIANTS = {
    'CCITT-FALSE incl. FCS': lambda f, fcs: crc16(f + [fcs], 0xFFFF),
    'CCITT-FALSE ohne FCS' : lambda f, fcs: crc16(f,         0xFFFF),
    'XMODEM incl. FCS'     : lambda f, fcs: crc16(f + [fcs], 0x0000),
    'KERMIT incl. FCS'     : lambda f, fcs: crc16(f + [fcs], 0x0000, refin=True, refout=True),
}
hexs = lambda b: ' '.join(f'{x:02X}' for x in b)

def fcs_of(body):
    c = 0xFF
    for x in body: c ^= x
    return c

def parse(stream):
    out, i = [], 0
    while i < len(stream) - 4:
        if (stream[i] & 0x80) == 0 or i + 6 >= len(stream):
            i += 1; continue
        lg = stream[i + 5] & 0x0F
        n_body = 7 + lg
        body, raw, j, dbl = [], [], i, []
        while len(body) < n_body and j < len(stream):
            b = stream[j]
            if b == 0xCB and j + 1 < len(stream) and stream[j + 1] == 0xCB:
                body.append(0xCB); raw += [0xCB, 0xCB]; dbl.append(len(body) - 1); j += 2
            else:
                body.append(b); raw.append(b); j += 1
        if len(body) < n_body or j + 4 >= len(stream): break
        fcs = stream[j]
        if fcs != fcs_of(body): i += 1; continue
        mk = stream[j + 1:j + 3]
        if mk != [0xCB, 0x13]: i += 1; continue
        got = (stream[j + 3] << 8) | stream[j + 4]
        hits = [k for k, fn in VARIANTS.items() if fn(body, fcs) == got]
        out.append(dict(body=body, raw=raw, fcs=fcs, marker=mk, crc=got, hits=hits, dbl=dbl))
        i = j + 5
    return out

path = sys.argv[1]
ev = None
if '--evidence' in sys.argv:
    ev = open(sys.argv[sys.argv.index('--evidence') + 1], 'w', encoding='utf-8')
def emit(s=''):
    print(s)
    if ev: ev.write(s + '\n')

raw = open(path, encoding='utf-8', errors='replace').read()
build = re.search(r'# build\s*:\s*(.+)', raw)
dumps = re.findall(r'Bytes are discarded!\s*\(([0-9A-Fa-f ]+)\)', raw)
stream = [int(x, 16) for d in dumps for x in d.split()]

emit('NCN FRAME-END MARKER - Messprotokoll')
emit('=' * 78)
emit(f'Quelle      : {path}')
if build: emit(f'Firmware    : {build.group(1).strip()}')
emit(f'Hexdumps    : {len(dumps)}')
emit(f'Rohbytes    : {len(stream)}')
emit('')
emit('Rohdatenstrom (alle Dumps in Reihenfolge, ungefiltert)')
emit('-' * 78)
for k in range(0, len(stream), 24):
    emit(f'  {k:04X}  {hexs(stream[k:k+24])}')
emit('')

tel = parse(stream)
votes = collections.Counter()
for t in tel:
    for h in t['hits']: votes[h] += 1

emit(f'Telegramme erkannt: {len(tel)}')
emit('-' * 78)
emit('    #  Rumpf (entdoppelt)                        FCS  Marker  CRC   Variante')
for k, t in enumerate(tel, 1):
    v = t['hits'][0] if t['hits'] else '!! keine passt'
    d = '  [CB VERDOPPELT]' if t['dbl'] else ''
    emit(f"  {k:3d}  {hexs(t['body']):41s} {t['fcs']:02X}   {hexs(t['marker'])}   {t['crc']:04X}  {v}{d}")
emit('')

emit('CRC-16-Variante - alle Kandidaten gerechnet, nicht angenommen')
emit('-' * 78)
for name in VARIANTS:
    emit(f'  {name:24s} {votes[name]:3d}/{len(tel)}')
if votes:
    best, cnt = votes.most_common(1)[0]
    emit(f'  => {best}, init 0xFFFF, Polynom 0x1021, High vor Low  ({cnt}/{len(tel)})')
emit('')

emit('0xCB-Verdopplung')
emit('-' * 78)
dbl = [t for t in tel if t['dbl']]
if not dbl:
    emit('  Kein Telegramm mit 0xCB im Rumpf erfasst - UNBEWIESEN')
for t in dbl:
    emit(f"  auf dem Draht : {hexs(t['raw'])} {t['fcs']:02X} {hexs(t['marker'])} {t['crc']>>8:02X} {t['crc']&0xFF:02X}")
    emit(f"  entdoppelt    : {hexs(t['body'])}")
    emit(f"  FCS  berechnet {fcs_of(t['body']):02X} / Draht {t['fcs']:02X}"
         f"   CRC berechnet {crc16(t['body']+[t['fcs']],0xFFFF):04X} / Draht {t['crc']:04X}")
    emit(f"  Rumpf {len(t['raw'])} Byte auf dem Draht, {len(t['body'])} nach Entdoppelung")
    emit('')
if dbl:
    emit(f'  => BESTAETIGT an {len(dbl)} Telegramm(en). FCS und CRC rechnen ueber den')
    emit('     Rumpf OHNE das Duplikat - das Zusatzbyte ist reines Transport-Stuffing.')
if ev: ev.close()
