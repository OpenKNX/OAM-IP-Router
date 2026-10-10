---
name: busmon-viewer
description: >
  Continue work on BusmonViewer.html — the offline OpenKNX KNX-busmonitor analyzer (Wireshark-style
  cEMI L_Busmon.ind decoder + live SSE mode). Read this before touching the decoder. Carries the
  FAF-visibility finding and the two ready-to-apply decoder improvements (FAF seq little-endian +
  FAF long-frame fragment reassembly).
metadata:
  type: project
  author: Erkan Çolak
  scope: OAM-IP-Interface/scripts/Test
---

<!--
   ____                   _  __ _   ___  __
  / __ \ _ __  ___  _ _  | |/ /| \ | \ \/ /   OpenKNX · IP-Interface
 | |  | | '_ \/ -_)| ' \ | ' < |  \| |>  <    Busmon Viewer — continuation skill
  \____/| .__/\___||_||_||_|\_\|_|\__/_/\_\   (c) 2026 by Erkan Çolak
        |_|
-->

# Skill — BusmonViewer.html (continuation handoff)

**Purpose:** everything the next agent needs to keep improving `BusmonViewer.html` without re-deriving
the investigation. The tool is a **self-contained, offline HTML** KNX busmonitor analyzer in the OpenKNX
phosphor style (black/green, monospace, scanlines). It decodes cEMI `L_Busmon.ind` frames byte-by-byte
like Wireshark, validates against the KNX TP1 spec, shows timeline/charts/stats + an FTC (File Transfer)
analyzer, exports ETS-XML, and has a **live mode** streaming from a local SSE bridge.

Files that belong together (all in `scripts/Test/`):
- `BusmonViewer.html` — THE deliverable (self-contained; opens over `file://`).
- `Start-BusmonBridge.ps1` — pwsh SSE bridge (busmon tunnel → `data:{"hex","ts"}` SSE). Fallback until
  `oknx --api` exists (see `lib/OFM-FileTransferModule/doc/concept/desktop-api.md`).
- `ftc-gui-concept.html` / `ftc-gui-mock.html` — FTC GUI mocks (future front-end for `oknx --api`).

Style tokens & rationale: memory `openknx-phosphor-ui-style`. Desktop-tooling architecture (the decided
`oknx --api` local-server model that will replace the pwsh bridge): memory `ftc-cli-api-architecture` +
`lib/OFM-FileTransferModule/doc/concept/desktop-api.md`.

---

## THE finding — FAF forget visibility (why Siemens sees it and our interface does not)

This is the investigation that motivated the pending decoder work. **Definitively resolved with data.**

A FileUploadFast (FAF, cmd 44) **forget-mode** upload writes the target file correctly (data reaches the
bus), but the busmon capture looked "empty". Comparing the SAME ~40 s window, same 10 KB upload to 5.0.3:

| busmon interface | frames | FAF data chunks | no-PA frames | aiLen |
|---|---|---|---|---|
| **OpenKNX 11.11.0.126** | **31** | **~0** (5 FileUploadFast = open/close/small) | 0 | 3 |
| **Siemens 11.11.0.5** | **311** | all (as fragments) | 237 | 9 (+timestamp TLV) |

### CORRECTED ROOT CAUSE (an earlier "the OpenKNX busmon drops 90 %" guess was WRONG — disproven by data)

The **decisive evidence** is the busmon status **sequence number** (3-bit counter in the status TLV,
`F.seq = raw[4] & 0x07`). Across BOTH captures it runs perfectly continuous (0,1,…,7,0,…) with **zero
jumps and zero error flags** → **neither monitor dropped a single frame.** The busmon reports EXACTLY what
is on the wire. Verify with `busmon-seq lost` (see the test harness below):
```
Siemens .5    | aiLen 9 | 311 frames | busmon-seq lost: 0 | errflags: 0 | FAF data chunks: 42 (seq 1..42)
OpenKNX .126  | aiLen 3 |  43 frames | busmon-seq lost: 0 | errflags: 0 | FAF data chunks:  1 (seq 42)
```
So the forget data chunks are **not on the TP bus at all** in the OpenKNX run — nothing for the monitor to
miss. The loss is on the **SENDING side (the oknx client's interface, .210)**, before TP:

- **open & close are ANSWERED** (T_Data_Connected, wait for a response → flow-controlled) → reliably hit TP.
- **FAF data chunks are SILENT** (fire-and-forget, no L7 response → no back-pressure). Forget fires
  **4 chunks × ~245 B @ 25 ms** (`FTC_FORGET_BURST=4`, `FTC_FORGET_PACE_MS=25`) into the sender's tunnel-RX
  buffer, but **TP1 only carries ~650 B/s**. The buffer overruns; the un-flow-controlled chunks get
  overwritten; only the **last** one (#42) survives to TP. Same root as memory `reboot-under-tunnel-flood`
  (RP2040 under unpaced incrementing-seq tunnel flood). In the Siemens run the timing happened to let all
  42 through — **forget is silently lossy / non-deterministic on this interface.**

**Bottom lines:**
- **Nothing to fix in the viewer/busmon** — it is correct; it shows exactly what is on the wire.
- **Forget silently loses data here:** the file gets its SIZE (open/close/seek succeed) but with HOLES.
  "File written" ≠ "all data arrived". Use `fast`/`safe` for reliable transfers; forget only when the
  sender's tunnel→TP can keep up.
- The real lever is the **sending interface's tunnel→TP buffering/pacing for silent FAF**
  (`data_link_layer` / `ip_tunnel_server`) — a **shared-lib firmware** change → discuss with the user first,
  never edit lib/* unilaterally.
- **Definitive confirming test:** capture ONE forget upload with the Siemens AND the OpenKNX interface
  simultaneously — both should then show the same (small) chunk count, proving the sender drops, not the monitor.

### Secondary: long-frame representation differs by chip (a display nuance, not the cause)

For the chunks that ARE on the bus: a FAF chunk is a **~245-byte extended frame**; no busmon fits it in one
`L_Busmon.ind`. **Siemens fragments** it (header piece decodes as `FTC FileUploadFast`, continuation pieces
are header-less binary data → reassembled by `fafStep`, see DONE 2). **OpenKNX truncates** it (declared
length > bytes present → `F.truncated`, FCS n/a). Neither is data loss — just representation.

Related memory: `reboot-under-tunnel-flood`, `busmon-one-per-subnet`, `simulate-every-change`.

---

## Decoder architecture (`decodeFrame(rawHex)` in BusmonViewer.html)

Single function, ~line 476–644. Field pushes build `F.fields[]`; spec checks build `F.checks[]`. Key
branches, in order:

- **cEMI header** — `mc=raw[0]` (0x2B = `L_Busmon.ind`; 0x29/0x2E/0x11 = L_Data ind/con/req). `aiLen=raw[1]`.
- **Busmon status TLV** (`isBusmon && raw[2]==0x03 && raw[3]==0x01`): `F.seq = raw[4] & 0x07`, error flags.
  Siemens adds a timestamp TLV → **aiLen 9**; OpenKNX **aiLen 3**.
- **`hasFcs = isBusmon`** — only TP1 busmon frames carry the wire FCS; cEMI L_Data does not.
- **L2 ACK/short** (`isBusmon && lpduLen<6`): ACK 0xCC / NAK 0x0C / BUSY 0xC0 → `F.isAck`, no PA, no FCS.
- **`ctlValid`** gate (`~line 524`): a real TP1 L_Data control byte is std(10xx)/ext(00xx) **AND** bit4=1
  **AND** bits1-0=00. Console TEXT bytes (Siemens during a console session) fail this → decoded as
  `text`/`non-LPDU`, **no invented PA**. THIS gate is what killed the bogus-PA problem (e.g. 6.13.97).
- **Address decode** — standard (single ctrl byte, NPCI packs DAF/hop/len) vs extended/cEMI (two ctrl bytes).
- **TPCI/APCI** — `apci = ((t0&0x03)<<8) | data[1]`; `apciName()` from the ApduType table (mirror of
  `knx/src/knx/knx_types.h`).
- **FTC detection** (`~line 578`): `apci ∈ {0x2C7,0x2C8,0x2C9}` (FunctionProperty Command/State/StateResponse)
  **AND** `data[2] ∈ {159 files, 160 console}`. `F.ftcCmd = FTM_CMD[pid]`; `F.ftcPayload = data.slice(4)`
  (bytes after objIndex+propId). Console (obj 160) payload = console text via `bytesToText`.
- **FCS** — computed only when `hasFcs && !truncated`; `truncated = (dataStart+dlen+1) > raw.length` (a
  chopped long frame has no valid trailing FCS, so no false FCS-fail).
- **Post-check reclassify** (`~line 629`): a busmon frame that FAILS FCS **and** whose body is mostly
  printable (`textLike/n>0.8`) **or** has an unknown APCI → dropped to `text`/`fragment` (no PA, FCS n/a).
  Genuine corrupt telegrams (FCS bad but KNOWN APCI + binary body) stay flagged.

Helpers: `bytesToText(arr)` (UTF-8 via `TextDecoder`, keeps printable + `\n`), `apciName`, `FTM_CMD`
(PID→name), `fcsField`, `ftcDecode(F)` (human-readable FTC lines, ~line 448).

**To extract the decoder for offline testing** (used throughout this investigation):
```bash
cd OAM-IP-Interface
node -e 'const fs=require("fs");const j=fs.readFileSync("scripts/Test/BusmonViewer.html","utf8").match(/<script>([\s\S]*?)<\/script>/)[1];
 const s=j.indexOf("const PRIO"),e=j.indexOf("function startLive");fs.writeFileSync("/tmp/decW.js",j.slice(s,e)+"\n");'
# then: const {decodeFrame}=new Function(fs.readFileSync("/tmp/decW.js","utf8")+"; return {decodeFrame};")();
```
Test corpus: the user's `~/Downloads/busmon-export-*.xml` (RawData="..." attributes). Extract with
`[...txt.matchAll(/RawData="([0-9A-F]+)"/g)]`.

---

## DONE — two decoder improvements (both implemented in BusmonViewer.html + HW-data verified)

Both landed. Do NOT redo them; they are described here so you know the current shape and can extend/polish.

### DONE 1 — FAF data-chunk seq little-endian (in `decodeFrame`, the FTC block ~line 585)

The FAF (cmd 44) write/read path reads the sequence little-endian:
`OFM-FileTransferModule/src/FileTransferModule.cpp:820` → `uint16_t sequence = data[1] << 8 | data[0];`
(the classic cmd 40 uses `pushWord` = big-endian, but the busmon sees the cmd-44 REQUEST → LE). Implemented:
```js
// FileUploadFast (cmd 44) data chunk: seq is LITTLE-endian; open=0x0000, close=0xFFFF, else a data chunk
if(obj===159 && pid===44 && apci===0x2C7 && F.ftcPayload.length>=2){
  const seqLE=(F.ftcPayload[1]<<8)|F.ftcPayload[0]; F.fafSeq=seqLE;
  if(seqLE===0x0000) F.fafPhase="open"; else if(seqLE===0xFFFF) F.fafPhase="close";
  else { F.fafPhase="data"; F.fafLen=F.ftcPayload[2]; F.fafData=F.ftcPayload.slice(3); }
  F.ftcHint="FAF "+F.fafPhase+(F.fafPhase==="data"?" #"+seqLE:"");
}
```
Payload layout: `payload[0]=seq LSB, [1]=seq MSB, [2]=chunk len n, [3..]=data`. Sets `F.fafSeq / F.fafPhase
(open|data|close) / F.fafLen / F.fafData`. **Verified:** the Siemens 10 KB capture now decodes seq
`1,2,3,…,42` (was garbage 0,256,512 when read big-endian).

### DONE 2 — FAF long-frame fragment reassembly (`fafStep`/`fafReassemble`, defined just before `boot`)

A Siemens busmon splits a ~245-byte FAF chunk into a header piece + header-less binary continuation pieces
(previously shown as `?->?`/text). `fafStep(F, open)` links each continuation to the open chunk, tags it
`service="FAF data (cont.)"`, and accumulates `open.fafBytes`. Wired at **both** ingest points:
- batch: `fafReassemble(FRAMES)` in `boot()` (right after `FRAMES=parsed.frames`).
- live: `FAF_OPEN=fafStep(F,FAF_OPEN)` in `addFrame()`; `FAF_OPEN` reset to null in `startLive()`.

Heuristic (no wire marker): a continuation = `isBusmon && nonLpdu && fafBinaryBody(F)` (body ≥ 8 B,
printable-ratio < 0.7 — chunk data is a byte pattern, not ASCII) while a FAF `data` chunk is open. Any real
telegram / ACK / printable text closes the window. Conservative by design (a telegram with a PA is never
swallowed). **Verified:** Siemens capture → open + 42 data chunks (seq 1–42) + close, chunk #1 reassembled
to the full 245 B, 60 continuation pieces linked. OpenKNX capture → open + only chunk **#42** + close (it
dropped #1–#41 under the forget burst) — the on-screen proof of the ~90 % drop finding above.

### Remaining polish (optional, not blocking)

- **~105 continuation pieces in the Siemens capture stay bare `?->?`** — they fall outside an open-FAF
  window (a GroupValue_Write between bursts closes it) or missed the binary-ratio gate. Acceptable: the 42
  clean headers already prove full capture. If you want them too, relax the window (don't close on a lone
  GroupValue between chunks) — but keep it conservative (never swallow a real telegram).
- **Render chips** — the service column already shows `FAF data (cont.)` and the FTC chip shows
  `FAF data #N`; consider a dedicated FAF chip color + a "chunk #N · NNN B reassembled" badge on the header
  row (`F.fafBytes`) for a cleaner forget-session view. Row render is ~line 990 (`ftcChip`).
- **OpenKNX truncation** — those long frames are chopped (declared length > bytes present → `F.truncated`),
  so there are no continuation pieces to reassemble; the display is "truncated (busmon dropped/chopped)".

### Test harness (how the above was verified — reuse it)
```bash
cd OAM-IP-Interface
node -e 'const fs=require("fs");const j=fs.readFileSync("scripts/Test/BusmonViewer.html","utf8").match(/<script>([\s\S]*?)<\/script>/)[1];
 const dec=j.slice(j.indexOf("const PRIO"),j.indexOf("function startLive"));
 const faf=j.slice(j.indexOf("let FAF_OPEN"),j.indexOf("function boot(parsed)"));
 fs.writeFileSync("/tmp/decW.js",dec+"\n"+faf+"\n");'
# then: const {decodeFrame,fafStep}=new Function(fs.readFileSync("/tmp/decW.js","utf8")+"; return {decodeFrame,fafStep};")();
#       decode all RawData, run: let open=null; for(const f of F) open=fafStep(f,open);
```

---

## Standing constraints (the user's VORGABEN — non-negotiable)

- **All code comments AND commit messages in ENGLISH** (chat is German).
- **Discuss design / shared-lib / trade-off decisions BEFORE implementing** ("rede mit mir") — options +
  a recommendation, then wait. Do not jump to code on anything non-trivial.
- **Never edit `lib/*` shared libs** (symlinks → hit every OpenKNX product) without explicit user go. The
  "make the OpenKNX busmon keep up under forget bursts" fix lives in `TpUartDataLinkLayer` = lib/* = discuss first.
- **Commits:** show the message + get explicit go first, never commit unseen. No `Co-Authored-By` trailer.
  Single-line body bullets. NEVER push unless told.
- **Scripts = PowerShell** (`.ps1`) with the OpenKNX logo header + author `Erkan Çolak` + comment-based help.
  A Python script is rejected outright. (The offline analyzer is HTML/JS — that is fine; only *scripts* must be pwsh.)
- **Non-blocking always**; **memory-safety first** (RP2040/ESP32). Do NOT touch `OAM-IP-Router`.

## Uncommitted state / next steps

- `BusmonViewer.html`, `Start-BusmonBridge.ps1`, `ftc-gui-*.html`, `lib/OFM-FileTransferModule/doc/concept/desktop-api.md`,
  `poc/ftc-gui/` are **uncommitted**. When the user says go: separate, cherry-pickable commits, messages
  shown first (see the commit rules above).
- The decided next architecture is **`oknx --api`** (local HTTP/SSE server in oknx) which retires this
  pwsh bridge and serves both the BusmonViewer and a real FTC GUI. Concept is written
  (`lib/OFM-FileTransferModule/doc/concept/desktop-api.md`); building it is **not yet greenlit** — wait for the user.

© 2026 by Erkan Çolak · OpenKNX
