# OpenKNX — KNXnet/IP Testsuite

Prüfstand für **IP-Interface** und **IP-Router**, ausgerichtet an den KNX System Test
Specifications (Volume 8, `08_TSSH`). Ein Einstieg, ein Report, ein Exit-Code.

---

## Schnellstart

**Ich will einfach testen:**

```
pwsh ./Run-Tests.ps1
```

Fragt alles ab, erklärt jede Eingabe, merkt sich die Antworten für den nächsten Lauf.

**Ich kenne meine Werte:**

```
pwsh ./Run-Tests.ps1 -What All -Ip 11.11.0.210 -BdutPa 5.0.10 -TrafficIp 11.11.0.126 -P2pTarget 5.0.3
```

**Ich will nur schnell wissen, ob das Gerät lebt und sich richtig meldet** (~30 s):

```
pwsh ./Run-Tests.ps1 -What Features -Ip 11.11.0.210
```

**Ich will nur den Busmonitor prüfen** (~4 min):

```
pwsh ./Run-Tests.ps1 -What Busmonitor -Ip 11.11.0.210 -TrafficIp 11.11.0.126
```

**Ohne Gerät, nur die Bibliothek prüfen** (1 s):

```
pwsh runners/Invoke-Conformance.ps1 -SelfTest
```

**Welche Geräte hängen im Netz?**

```
pwsh Tools/Find-KnxDevices.ps1
```

Die vier Werte, die fast alles steuern:

| | |
|---|---|
| `-Ip` | das Gerät, das beurteilt wird |
| `-BdutPa` | dessen physikalische Adresse, z. B. `5.0.10` |
| `-TrafficIp` | **zweite** Schnittstelle, erzeugt Bustelegramme — muss auf **derselben TP-Linie** sitzen |
| `-P2pTarget` | ein Gerät auf der Linie, das auf Punkt-zu-Punkt antwortet, z. B. `5.0.3` |

Läuft unter **PowerShell 7** (macOS/Linux/Windows) und **Windows PowerShell 5.1**.

---

## 1. Testaufbau

### Interface

```
   ┌──────────────────────── Ethernet  11.11.0.x ────────────────────────┐
   │                     │                     │                        │
┌──┴───────────┐   ┌─────┴────────┐   ┌────────┴─────┐                   │
│ Prüfling     │   │ Verkehrs-    │   │ Referenz     │                   │
│ IP-Interface │   │ quelle       │   │ Siemens/MDT  │                   │
│ 11.11.0.210  │   │ 11.11.0.126  │   │ 11.11.0.5    │                   │
│ PA 5.0.10    │   │ 2. Interface │   │ optional     │                   │
└──┬───────────┘   └─────┬────────┘   └────────┬─────┘                   │
   │                     │                     │                        │
═══╪═════════════════════╪═════════════════════╪════════════════  TP1  Linie 5.0
   │                                           │
┌──┴───────────┐                      ┌────────┴─────┐
│ P2P-Ziel     │  antwortet auf       │ Lastschalter │  optional
│ 5.0.3        │  Punkt-zu-Punkt      │ Aktor        │  (Busspannung)
└──────────────┘  (z. B. KNeoPix)     └──────────────┘
```

**Die eine Regel, an der die meisten Fehlläufe hingen:** Prüfling und Verkehrsquelle müssen
auf **derselben TP-Linie** sitzen. Ein Interface auf Linie 1.0 kann kein Telegramm zu einem
Prüfling auf Linie 5.0 bringen — dann scheitern alle „from KNX"-Fälle aus einem Rig-Grund und
sehen wie Gerätefehler aus. `Run-Tests.ps1` liest die PA der Verkehrsquelle und **bricht ab**,
wenn die Linie nicht passt.

Der **Produktiv-Router `11.11.0.3` (Linie 1.0) gehört nie in einen Testlauf.**

### Router

Gleicher Aufbau, drei Unterschiede:

| | Interface | Router |
|---|---|---|
| Maske | `07B0` | `091A` |
| ROUTING-Familie | darf **nicht** beworben werden | **muss** beworben werden |
| HW-Busmonitor | vorhanden | nicht vorhanden |
| Multicast | — | eigene Gruppe nötig |

Die Routing-Suite braucht `-Multicast`. **Sie wird automatisch verworfen, wenn `224.0.23.12`
gesetzt ist** — auf der Produktivgruppe wird nicht getestet. Für Routing-Fälle eine eigene
Gruppe verwenden, z. B. `-Multicast 224.0.23.99`.

Die Busmonitor-Stufe erkennt am Gerät, ob ein Busmonitor vorhanden ist, und läuft beim Router
folgerichtig leer — kein Schalter nötig.

---

## 2. Die Stufen

| Stufe | Umfang | Dauer |
|---|---|---|
| **Selbsttest** | 54 Vektoren, offline — läuft vor jedem Urteil | 1 s |
| **Conformance** | TSSH §3–§8, 117 Fälle | ~4 min |
| **Features** | Produktverhalten ohne Spezifikationsvorlage (`X-*`) | ~30 s |
| **Busmonitor** | 14 Randfälle inkl. Angriffsfälle (`B-*`) | ~4 min |
| **Devices** | KNX-**Geräte** am TP gegen Volume 3 (`D-*`), 20 Fälle je Gerät | ~1 min/Gerät |
| **Hardening** | FTC-Dateitransfer und Konsole, angriffslustig — braucht die Gerätekonsole | ~5 min |
| **Clean** | alte Berichte entfernen — zeigt erst was, fragt dann | Sekunden |
| **Stress** | Last, Lecks, fehlerhafte Clients | ~8 min |
| **Legacy** | ältere Skripte (Tunnels, Soak, Fuzz) | ~3 min |

`-What All` fährt alle. Einzeln über `-What Conformance` usw.

**Dauerlauf** (`-What Endurance -Iterations 29`) trennt `STABLE PASS` von `FLAKY` und
`STABLE FAIL`. 29 ist kein Zufallswert: Ein Fehler, der in 10 % der Läufe auftritt, zeigt sich
damit mit 95 % Wahrscheinlichkeit mindestens einmal.

**Referenzvergleich** (`-What Reference -ReferenceIp …`) fährt dieselben Fälle gegen ein
zertifiziertes Gerät. Ein Fall, den unser Gerät **und** die Referenz nicht bestehen, ist mit
hoher Wahrscheinlichkeit ein Testfehler.

---

## 2a. Geräte am TP — die Devices-Stufe

Alle anderen Stufen beurteilen ein **KNXnet/IP-Gerät** gegen Volume 8. Diese Stufe beurteilt
etwas anderes: ein ganz normales Busgerät — einen NeoPixel, einen Nuki, einen Dimmer — gegen
**Volume 3**. Die Schnittstelle ist hier nicht der Prüfling, sie ist das Fenster.

```
pwsh ./Run-Tests.ps1 -What Devices -Ip 11.11.0.126 -DeviceTargets 5.0.3,5.0.9
```

Das entscheidet, was ein roter Fall bedeutet: Er sagt „das **Gerät** an dieser Adresse verhält
sich nicht so, wie Volume 3 es verlangt" — und das sagt er erst, nachdem sich derselbe Tunnel in
den KNXnet/IP-Stufen bewährt hat. Deshalb: **erst die anderen Stufen, dann diese.** Ein kaputtes
Fenster lässt jedes Gerät kaputt aussehen. Der Runner bricht ab, wenn das Fenster nicht taugt.

| Gruppe | Was geprüft wird |
|---|---|
| `D-1` | Identität: Maskenversion, Seriennummer, Hersteller, max. APDU — und ob das Gerät zweimal dasselbe sagt |
| `D-2` | Transportschicht: die verbindungsorientierte Zustandsmaschine, auf die sich ETS verlässt |
| `D-3` | Anwendungsschicht: Property-Dienste und die vorgeschriebene Fehlerantwort |
| `D-4` | Robustheit: abgeschnittene und überlange Anfragen, Slot-Lecks |
| `D-5` | Adressierung: antwortet es für seine Adresse — und nur für die |

**Jeder Fall passt sich der Maskenversion an.** Ein BCU1 hat keine Interface-Objekte, also melden
die Property-Fälle **N-A mit der Maske als Grund** statt einer Wand aus Rot für ein Gerät, das
sie nie implementieren musste.

**Was hier bewusst nicht steht: die Applikation.** Ob dein NeoPixel die richtige Farbe zeigt,
steht in keiner Spezifikation — kein Test kann das „konform" nennen. Prüfbar ist die KNX-Schicht
darunter, und genau die ist es, die eine Firmware-Änderung kaputtmachen kann, ohne dass es
jemandem auffällt.

---

## 3. Der Busmonitor im Detail

Das Kernfeature dieses Produkts, deshalb eine eigene Stufe. Entscheidend ist nicht, *dass*
Frames ankommen, sondern dass sie **unverändert** ankommen: Ein Monitor, der still glattbügelt,
ist schlimmer als einer, der Frames verliert — man sieht etwas, das nie auf der Leitung war.

| | |
|---|---|
| `B-1` | Quittungen kommen als Ein-Oktett-Frames durch (Muster `xx00 xx00`, **ohne** FCS) |
| `B-2` | Wiederholungsflag bleibt erhalten — ein Repeat ist ein eigenes Busereignis |
| `B-3` | Länge stimmt mit der Header-Angabe (STD `8+LG`, EXT `9+LG`) |
| `B-4` | Sequenz lückenlos, Lost-Flag frei |
| `B-5` | FCS auf jedem Telegramm gültig |
| `B-6` | Start/Stop-Zyklen latchen den Transceiver nicht |
| `B-7` | Priorität und Hop Count unverändert |
| `B-8` | zweiter Busmonitor wird abgewiesen |
| `B-10` | 60 fehlerhafte Datagramme auf den offenen Kanal — Kanal und Discovery überleben |
| `B-11` | 15 Connect/Disconnect ohne Pause |
| `B-12` | Treue unter hoher Buslast |
| `B-13` | Frame-/Bit-/Paritätsflags sind lesbar, werden nicht verschluckt |
| `B-14` | feindselige Telegramme (Prioritäten, Hop Counts, Broadcast, lange APDUs) kommen mit gültiger FCS und stimmiger Länge zurück |
| `B-9` | verwaister Slot wird freigegeben — **läuft absichtlich zuletzt** |

**Zwei Grenzen, die bewusst benannt sind:**

Ein **echt korruptes** TP-Frame (falsche FCS, Paritätsfehler) lässt sich mit einer Schnittstelle
nicht erzeugen — sie rechnet die Prüfsumme selbst. Dass der Monitor so etwas *melden würde*,
belegt `B-13` über die Lesbarkeit der Fehlerflags.

`B-14` bewertet **nicht**, ob Prioritäten und Hop Counts verschieden zurückkommen. Der Weg ist
Generator → sendende Schnittstelle → TP → Monitor; ein einheitlicher Wert kann ebenso von der
**sendenden** Seite stammen. Der Fall protokolliert die Beobachtung als Evidenz, statt sie dem
Monitor anzulasten.

**Betriebshinweis:** Ein abgestürzter Busmonitor-Client blockiert den Busmonitor **~80 Sekunden**,
bis der Reaper den Slot freigibt. Das Gerät klemmt nicht, aber weil der Busmonitor exklusiv ist,
ist das Feature so lange für alle weg.

---

## 4. Was läuft, was nicht

| | Bedeutung |
|---|---|
| **PASS** | geprüft und in Ordnung |
| **FAIL** | geprüft und abweichend |
| **SKIP** | konnte nicht geprüft werden — Aufbau oder Client fehlt |
| **N-A** | gilt für dieses Produkt nicht |

### SKIP — Aufbau fehlt

| Fall | Braucht | Aktivieren |
|---|---|---|
| `H-3.5.4`, `H-4.2.12` | **Lastschalter**, der die Busspannung schaltet | `-LoadSwitchGa 1/1/50 -LoadSwitchPa 1.1.50` |
| `H-4.2.7`, `H-4.2.8` | ändern die **PA des Prüflings** | `-IncludeDestructive -RunProfile Full` |
| `H-5.3.1/2/5/6` | **überschreiben den Tunnel-Adresspool** | `-IncludeDestructive -RunProfile Full` |

> `H-5.3.5` / `H-5.3.6` prüfen gezielt `E_NO_MORE_UNIQUE_CONNECTIONS` mit doppelten
> Pool-Adressen — sie beantworten die Frage „0x25 oder 0x24?" direkt.

### SKIP — Client oder Gerät bietet es nicht

`H-4.2.6` braucht einen **verbindungsorientierten Transportclient** (`T_Connect`,
Sequenznummern, `T_Ack`); der Testclient kann bisher nur One-Shot-Lesen. Offene Lücke im
Werkzeug, kein Aufbauproblem.

`X-ID-3` liest `PID_MAX_LOCAL_APDU_LENGTH` (69) am cEMI-Server-Objekt. **Gemessen:** die
zertifizierte Referenz legt sie ebenfalls nicht offen — also optional, kein Mangel.

### N-A — gilt nicht

* **§7 Remote Diagnosis** (33 Fälle) — das Gerät bewirbt die Familie nicht. Optionaler Dienst
  (`03_08_07`); als ToDo erfasst, nicht umgesetzt.
* **§8 IP als KNX-Medium** (8 Fälle) — gilt nur für Geräte, bei denen **IP das Medium ist**
  (Maske `57B0`/`5705`), also ohne TP-Anschluss. Interface ist `07B0`, Router `091A`.

Die Suiten lesen die Maske **am Gerät** (`PID_DEVICE_DESCRIPTOR`, PID 83 im Device-Objekt) statt
sie anzunehmen. Wechselt ein Produkt die Maske, verlangen die Fälle automatisch echte
Ergebnisse statt still N-A zu bleiben.

> **Nicht in der `DESCRIPTION_RESPONSE` suchen:** die Extended Device Information DIB ist dort
> laut `03_08_02` Table 5 (S. 31) *„Not allowed"* — Maske und APDU-Länge stehen in Properties,
> nicht in dieser Antwort. Ein früherer Testfall suchte sie dort und meldete deshalb dauerhaft
> „unknown".

---

## 5. Aufrufe

| Ziel | Aufruf |
|---|---|
| Alles, ein Urteil | `./Run-Tests.ps1 -What All …` |
| Nur Konformität | `./Run-Tests.ps1 -What Conformance …` |
| Nur Busmonitor | `./Run-Tests.ps1 -What Busmonitor -Ip … -TrafficIp …` |
| Nur Produktverhalten | `./Run-Tests.ps1 -What Features -Ip …` |
| Last und Lecks | `./Run-Tests.ps1 -What Stress -Ip …` |
| Stabilität | `./Run-Tests.ps1 -What Endurance -Iterations 29` |
| Gegen ein zertifiziertes Gerät | `./Run-Tests.ps1 -What Reference -ReferenceIp …` |
| Bibliothek offline prüfen | `pwsh runners/Invoke-Conformance.ps1 -SelfTest` |
| Geräte im Netz finden | `pwsh Tools/Find-KnxDevices.ps1` |

`wreck` aus der Stress-Stufe läuft **nie** automatisch: Er kann den Watchdog auslösen, und
OpenKNX-Auto-Erase löscht dann die KNX-Konfiguration. Bei Bedarf direkt:
`pwsh stress/Invoke-Stress.ps1 <ip> wreck`.

---

## 6. Aufbau des Ordners

```
Run-Tests.ps1     der eine Einstieg, fragt den Aufbau ab
lib/              KnxTest.psm1 (Frames, Parser, Urteilslogik, Selbsttest)
                  KnxSerial.psm1 (Ports finden, Gerät erkennen, Konsole bedienen)
                  Sync-TestLib.ps1 (Abgleich mit dem Router-Repo)
runners/          Invoke-AllTests · Invoke-Conformance · Invoke-Endurance
                  Invoke-DeviceTests · Compare-Reference
Suites/           3-Core … 8-IpMedium — die TSSH-Fälle
                  D-Device.Tests — Geräte am TP (D-*)
Features/         Test-Features (X-*) · Test-Busmonitor (B-*)
stress/           Invoke-Stress.ps1 — Last, Lecks, Robustheit
legacy/           Test-Tunnels · Test-Soak · Test-Fuzz
Tools/            Find-KnxDevices · Start-FakeKnxDevice (Offline-Gerät)
                  Clear-Reports.ps1 — Berichte aufräumen (zeigt erst, fragt dann)
viewer/           BusmonViewer.html · Start-BusmonBridge
repro/            Einzelfall-Reproduktionen
Reports/          Markdown + JSON je Lauf
```

`lib/Sync-TestLib.ps1` hält Interface- und Router-Repo byte-gleich. **Vor jedem Testen im
anderen Repo laufen lassen**, sonst prüfen die Seiten unterschiedlich.

---

## 6a. Serielle Geräte — `lib/KnxSerial.psm1`

Vier Skripte öffneten den seriellen Port früher von Hand, jedes mit eigener Wartezeit und
eigenem Leeren des Puffers — und nur eines lief unter Windows. Das steckt jetzt in einem
Modul, das neben `KnxTest.psm1` importiert wird und von nichts anderem abhängt:

```powershell
Import-Module (Join-Path $here 'lib/KnxSerial.psm1') -Force

Get-KnxSerialDevices -Probe                      # was steckt dran, und was ist es
$s = Open-KnxSerial -Port /dev/cu.usbmodem84101
Invoke-KnxSerialCommand -Session $s -Command 'bcu'
Close-KnxSerial -Session $s
```

**Die Portsuche ist dieselbe wie im OpenKNX-Firmware-Uploader**
(`OGM-Common/scripts/setup/reusable/data/Upload-Firmware-Generic.ps1`, `ScanPicoPorts` und
`ScanEsp32Ports`): macOS `/dev/cu.*`, Linux `/dev/ttyACM*` und `/dev/ttyUSB*`, Windows über
`Get-PnpDevice` mit Hersteller-Filter (2E8A Raspberry, 303A Espressif, 1A86/10C4/0403 die
üblichen Brücken). Ein Board wird hier also genauso gefunden wie beim Flashen. Bluetooth und
Debug-Konsole fallen raus, weil sie nie ein Gerät sind.

**Und es zeigt, *welches* Gerät.** `-Probe` fragt jeden Port mit dem Konsolenbefehl `i` und
liest Name, Firmware-Version und Seriennummer — dieselben Felder, die der Uploader vor dem
Flashen anzeigt:

```
    5 port(s) found - asking each one who it is, about 3 s each:
      /dev/cu.usbmodem3101         no answer
      /dev/cu.usbmodem84101        "IP-Interface REG2"  v1.1.0  SN 00FA132F8531
      /dev/cu.wchusbserial8430     no answer

   [1] /dev/cu.usbmodem3101        (did not answer)
   [2] /dev/cu.usbmodem84101       "IP-Interface REG2"  v1.1.0  SN 00FA132F8531
   [0] none - skip everything that needs the console
```

Die Abfrage läuft Port für Port und wartet je auf eine Antwort — bei fünf Ports gut zehn
Sekunden. Deshalb schreibt sie mit, während sie sucht: eine stumme Pause liest sich wie ein
Hänger, und die natürliche Reaktion darauf ist eine Taste oder Strg-C. Beides kostet den Lauf.

> **Vorsicht:** Das Öffnen eines Ports setzt DTR. Bei Boards hinter CP210x oder CH34x löst
> das einen Reset aus. **Nie sondieren, während auf dem Gerät eine Messung läuft** — der
> Reset ist lautlos und der Lauf ist weg.

---

## 7. Windows

Alle Skripte laufen unter Windows PowerShell 5.1 und PowerShell 7. Dafür gilt:

* **Alle `.ps1`/`.psm1` tragen einen UTF-8-BOM.** Ohne ihn nimmt PowerShell 5.1 die
  ANSI-Codepage an — Logo-Header, Umlaute und Rahmenzeichen werden zu Mojibake, und in
  Zeichenketten kann das das Parsen abbrechen. Beim Anlegen neuer Skripte mitdenken.
* **Serielle Ports** nie über `/dev/…`-Globs suchen — `Get-KnxSerialPorts` aus der Bibliothek
  liefert sie plattformunabhängig (`COM5` unter Windows, `/dev/cu.*` unter macOS).
* Pfade immer über `Join-Path`, nie mit hartem `/`.

---

## 8. Zwei Regeln, die teuer erkauft sind

**Unser Gerät grün und beide Referenzen rot ⟹ der Test ist der Verdächtige.**
Kontraintuitiv, aber an einem Tag dreimal bestätigt. Ein zertifiziertes Gerät weicht selten ab,
zwei gleichzeitig fast nie. Beispiele: `H-4.2.11` (falsche Klausel zitiert), `H-3.2.1` (SEARCH
unicast statt an die Discovery-Gruppe) und `X-ID-3` (optionale Property als Pflicht behandelt).
In allen drei Fällen war unser Gerät nur permissiver, nicht besser.

**Immer Klausel *und* Dokument zitieren.**
`03_08_04` sagt für `TUNNELLING_REQUEST` „repeated **once**", `03_08_03` für
`DEVICE_CONFIGURATION_REQUEST` „repeat **three (3) times**". Dieselbe Frage, zwei Dokumente,
zwei Antworten. Eine Zahl ohne Herkunft ist wertlos — die Verwechslung steckte sowohl im Test
als auch im Firmware-Kommentar an der betroffenen Codestelle.

Daraus die Reihenfolge bei jedem roten Fall: **erst gegen eine Referenz messen, dann die
Klausel im richtigen Dokument nachschlagen, dann erst das Gerät verdächtigen.**

Und: **ein Testfall darf nur behaupten, was er auch zuordnen kann.** `B-14` hat das gelernt —
er sieht die Leitung, nicht den Sender, und beschuldigt deshalb den Monitor nicht mehr für
etwas, das ebenso von der sendenden Seite kommen kann.

---

## 9. Vor jedem Urteil

Der Selbsttest (54 Vektoren) läuft **vor** jedem Lauf und bricht ab, wenn er fehlschlägt — ein
Gerät wird nicht mit einer defekten Bibliothek beurteilt. Er prüft unter anderem jede
Property-ID gegen `knx/src/knx/property.h`, weil Nummern aus der Prüfvorschrift wiederholt von
der Implementierung abwichen.

Ebenso gilt: **Buildtime jedes beteiligten Geräts prüfen**, nicht nur die des Prüflings. Ein
Vergleich über zwei Firmwarestände sieht aus wie ein Gerätebefund und ist keiner.

```
pio device monitor --raw -b 115200 -p /dev/cu.usbmodem3101   →  v  →  Buildtime:
```
