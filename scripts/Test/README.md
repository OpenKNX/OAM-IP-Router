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
pwsh ./Run-Tests.ps1 -What All -Ip 11.11.0.210 -BdutPa 1.1.13 -TrafficIp 11.11.0.126 -P2pTarget 1.1.5
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
| `-BdutPa` | dessen physikalische Adresse, z. B. `1.1.13` |
| `-TrafficIp` | **zweite** Schnittstelle, erzeugt Bustelegramme — muss auf **derselben TP-Linie** sitzen |
| `-P2pTarget` | ein Gerät auf der Linie, das auf Punkt-zu-Punkt antwortet, z. B. `1.1.5` |

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
│ PA 1.1.13    │   │ 2. Interface │   │ optional     │                   │
└──┬───────────┘   └─────┬────────┘   └────────┬─────┘                   │
   │                     │                     │                        │
═══╪═════════════════════╪═════════════════════╪════════════════  TP1  Linie 1.1
   │                                           │
┌──┴───────────┐                      ┌────────┴─────┐
│ P2P-Ziel     │  antwortet auf       │ Lastschalter │  optional
│ 1.1.5        │  Punkt-zu-Punkt      │ Aktor        │  (Busspannung)
└──────────────┘  (z. B. KNeoPix)     └──────────────┘
```

**Die eine Regel, an der die meisten Fehlläufe hingen:** Prüfling und Verkehrsquelle müssen
auf **derselben TP-Linie** sitzen. Ein Interface auf einer anderen Linie (z. B. 1.0) kann kein Telegramm zu einem
Prüfling auf Linie 1.1 bringen — dann scheitern alle „from KNX"-Fälle aus einem Rig-Grund und
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

Die ROUTING_BUSY-Fälle P-6.BUSY.1-4, .9 und .10 messen Abstände im Millisekundenbereich. PowerShell stempelt
ein Datagramm erst beim Lesen; ein Hänger des Rechners verschiebt den Stempel. Diese Fälle nehmen deshalb
mit Wiresharks `dumpcap` Kernel-Zeitstempel auf, auf einer kabelgebundenen Karte (macOS: ChmodBPF aus der
Wireshark-Installation, Windows: Npcap, sonst `KNX_DUMPCAP` auf den Pfad setzen). BUSY.1, .2, .3, .9 und .10
verlangen wie das Validation Tool nach jedem BUSY t_d ≥ tw; BUSY.1 und .2 zusätzlich t_d ≤ tw + N·50 ms nach
dem (letzten) BUSY. Anders als das Tool übergehen sie Telegramme, die innerhalb 1 ms nach dem BUSY eintreffen
und damit schon unterwegs waren.
Ohne `dumpcap` oder im WLAN enden diese fünf als NOT-RUN; BUSY.4 (höchstens 50 pro Sekunde) fällt auf die Lesestempel zurück.

Die Busmonitor-Stufe erkennt am Gerät, ob ein Busmonitor vorhanden ist, und läuft beim Router
folgerichtig leer — kein Schalter nötig.

---

## 2. Die Stufen

| Stufe | Umfang | Dauer |
|---|---|---|
| **Selbsttest** | 65 Vektoren plus 12 Ergebnis-Prüfungen (`Tools/Test-ResultContract.ps1`), offline — läuft vor jedem Urteil | ~2 s |
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
pwsh ./Run-Tests.ps1 -What Devices -Ip 11.11.0.126 -DeviceTargets 1.1.5,1.1.8
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

**Busmonitor-Zeuge.** `-WitnessIp` nennt eine zweite Schnittstelle im Busmonitor-Modus. `D-30.*`
beurteilen Quittungen auf dem Bus und enden ohne sie als NOT-RUN; `D-19.2` urteilt ohne Zeugen nur
über die sendende Schnittstelle und vermerkt das.

**`D-30.2` nur im Prüfaufbau von 08_02_02.** Ob ein Gerät einen Rahmen an eine fremde Adresse quittiert,
ist nur zuzuordnen, wenn außer dem Prüfling und den eigenen Schnittstellen niemand an der Linie hängt.
`-IsolatedLine` sichert diesen Aufbau zu (ein Ziel, kein Koppler oder Router unter den Schnittstellen,
die Nachbaradresse gehört keiner von ihnen). Ohne den Schalter bleibt `D-30.2` NOT-RUN.

**Jeder Fall passt sich der Maskenversion an.** Ein BCU1 hat keine Interface-Objekte, also melden
die Property-Fälle **N-A mit der Maske als Grund** statt einer Wand aus Rot für ein Gerät, das
sie nie implementieren musste.

**Was hier bewusst nicht steht: die Applikation.** Ob dein NeoPixel die richtige Farbe zeigt,
steht in keiner Spezifikation — kein Test kann das „konform" nennen. Prüfbar ist die KNX-Schicht
darunter, und genau die ist es, die eine Firmware-Änderung kaputtmachen kann, ohne dass es
jemandem auffällt.

---

## 2b. Rig-Stromwächter (power guard)

Ein Gerät am Prüfstand kann die Relais tragen, die den Prüfstand versorgen (hier 1.1.3: Relais auf
`0/3/100`/`0/3/110`, Status `0/3/101`/`0/3/111`, u. a. die TP-Seite des Routers). Ein Neustart dieses
Geräts schaltet die Relais ab, und jeder folgende Fall wirft dem falschen Gerät „antwortet nicht" vor.

| Parameter | Profilfeld (`rig`) | |
|---|---|---|
| `-PowerGuard on\|off` | `powerGuard` | Schalter; Parameter vor Profil, ohne beides `off` |
| `-PowerRelayWrite` | `powerRelayWrite` | Schalt-GAs, z. B. `0/3/100,0/3/110` (Wert 1 = EIN) |
| `-PowerRelayStatus` | `powerRelayStatus` | Status-GAs, gleiche Reihenfolge, z. B. `0/3/101,0/3/111` |
| `-PowerRelayVia` | `powerRelayVia` | Schnittstelle für **alle** Wächter-Telegramme — nicht `-TrafficIp`, die kann selbst an den Relais hängen |
| `-ProtectedTargets` | `protectedTargets` | PAs, die den Prüfstand versorgen, z. B. `1.1.3` |
| `-PowerRelayFeeds` | `powerRelayFeeds` | IPs der Prüflinge, deren TP die Relais trennen, z. B. `11.11.0.126` (nicht in `quick-check`). Die **erste** Schalt-GA muss das TP **jedes** gelisteten Geräts trennen; `powerRelayVia` darf nicht in der Liste stehen (sonst Abbruch, Exit 3) |

- **`off`**: kein Relais-Telegramm, keine geschützten Ziele — alles wie ohne Wächter.
- **`on`** ohne Relais-GAs, mit ungleich langen Listen oder ohne `powerRelayVia`: der Lauf startet nicht (Exit 3).
- `Assert-KnxRigPower` (`lib/KnxDevice.psm1`) liest jeden Status über `powerRelayVia`; bei 0 oder ohne
  Antwort schreibt es 1 auf die Schalt-GA, liest erneut und wartet danach bis 30 s, bis der Prüfling auf
  seiner PA wieder antwortet.
- Der Gesamtlauf ruft den Wächter vor jeder Stufe am Prüfstand; ein Wiedereinschalten steht als
  **Rig event** im Bericht.
- In der Devices-Stufe läuft er vor den Neustart- und „antwortet nicht mehr"-Urteilen; musste er
  einschalten, endet der Fall als SKIP („result … void"). Antwortet das Ziel nur über `-TrafficIp`,
  geht der FAIL an den Prüfling („lost its bus access").
- Geschützte Ziele bekommen keinen Neustart, Master-Reset, keine Adress-, Speicher- oder Property-Schreibung
  (SKIP „powers the rig (protected)"). Das Broadcast-Adressschreiben in `D-21.3` läuft weiter; antwortet
  danach ein Gerät auf `15.15.254`, nennt der FAIL dessen Seriennummer. Antwortet dort schon **vor** dem
  Schreiben ein Gerät (Rest eines früheren Laufs), wird nicht geschrieben (SKIP mit Seriennummer).

**KNX-Fehler per Relais (Stufe „Device state", `Tools/Test-DeviceStateIndication.ps1`).** Nur mit Wächter `on`,
konfigurierten Relais, `-Ip` in `powerRelayFeeds`, `powerRelayVia` nicht darin und `-IncludeDestructive`; sonst
NOT-RUN mit dem fehlenden Parameter. Ablauf: DM-Verbindung (CRI 3) auf den Prüfling, Vorprüfung (CONNECTIONSTATE 0x00, alle Relais EIN),
erstes Relais über `powerRelayVia` AUS (Status muss AUS lesen, sonst Rückschalten + SKIP), CONNECTIONSTATE alle 0,5 s:

| | |
|---|---|
| `DS-KF-1` | CONNECTIONSTATE 0x27 (E_KNX_CONNECTION) binnen 10 s nach dem Trennen (03_08_02, TSSH 10503) |
| `DS-KF-2` | M_PropInfo.ind Objekt 11 PID 69 Bit 0 = 1 binnen 20 s, M_PropRead bestätigt Bit 0 = 1 (03_08_03 2.5.20, TSSH 20212) |
| `DS-KF-3` | nach dem Wiedereinschalten binnen 5 s: M_PropInfo.ind Bit 0 = 0, CONNECTIONSTATE 0x00, M_PropRead Bit 0 = 0 |

Das Wiedereinschalten steht in einem `finally` (auch nach FAIL oder Ausnahme): Schreiben wird bis ~10 s
wiederholt, bis der Tunnel quittiert, danach wird der Status bis ~10 s auf EIN geprüft, dann `Assert-KnxRigPower`.
War das erste Wiedereinschalten nicht quittiert, brauchte es ein zweites oder musste der Wächter ein Relais
einschalten, endet `DS-KF-3` als SKIP — ein Prüfstandsfehler wird nie dem Prüfling angelastet. Ein FAIL setzt
voraus, dass das Fenster bis zum Budget abgefragt wurde; war es durch Prüfstands-Aufwand nicht abgedeckt, SKIP.
Alle Zeiten (mit Abfrage-Auflösung) stehen als `timing:`-Notiz im Bericht `device-state_*.json`; die Budgets sind
Konstanten (`$script:KnxFault*`) neben den Wächter-Werten in `lib/KnxDevice.psm1`.

Stufenergebnis (Exit des Tools): `0` PASS nur mit Bericht und allen drei Fällen PASS; `1` FAIL (ein Fall oder eine
Property-Prüfung fehlgeschlagen); `2` FAIL **RIG FAULT** — das Relais ist nach dem Trennen nicht als EIN bestätigt,
die Stufe nennt „relay X is OFF, switch on via …"; `3` SKIPPED, nicht alle Fälle liefen (Grund im Stufentext).

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

**Betriebshinweis:** Ein abgestürzter Busmonitor-Client blockiert den Busmonitor **120 Sekunden**
(das Heartbeat-Timeout aus 03_08_02 Core 5.4), bis der Reaper den Slot freigibt. Das Gerät klemmt
nicht, aber weil der Busmonitor exklusiv ist, ist das Feature so lange für alle weg. Warten ist
seit v1.2.0 nicht mehr nötig: auf der Webseite des **IP-Interface** lässt sich der Busmonitor unter
*Busmonitor* sofort beenden, unabhängig davon, wer ihn hält. Der Router hat keinen HW-Busmonitor
und damit auch diesen Abschnitt nicht.

---

## 4. Was läuft, was nicht

| | Bedeutung |
|---|---|
| **PASS** | geprüft und in Ordnung |
| **FAIL** | geprüft und abweichend |
| **SKIP** | konnte nicht geprüft werden — Aufbau oder Client fehlt |
| **N-A** | gilt für dieses Produkt nicht |
| **NOT-RUN** | dem Lauf fehlte eine Eingabe, die der Fall braucht (z. B. `-WitnessIp`) — eine Lücke im Lauf, nicht im Gerät |
| **NO-PROOF** | der Fall lief durch, ohne eine einzige Zusicherung zu prüfen — er sagt nichts über das Gerät |

Nur PASS und FAIL zählen als beurteilt. `-What All` endet mit Exit 3 („unvollständig"), wenn eine Stufe
übersprungen, eine Suite verworfen wurde oder ein Fall NO-PROOF ist; ein FAIL oder ein unlesbarer Bericht
ergibt Exit 1.

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
| Ergebnislogik offline prüfen | `pwsh Tools/Test-ResultContract.ps1` |
| Geräte im Netz finden | `pwsh Tools/Find-KnxDevices.ps1` |

`wreck` aus der Stress-Stufe läuft **nie** automatisch: Er kann den Watchdog auslösen, und
OpenKNX-Auto-Erase löscht dann die KNX-Konfiguration. Bei Bedarf direkt:
`pwsh stress/Invoke-Stress.ps1 <ip> wreck`.

---

## 6. Aufbau des Ordners

```
Run-Tests.ps1     der eine Einstieg, fragt den Aufbau ab
lib/              KnxTest.psm1 (Frames, Parser, Ergebnislogik, Selbsttest)
                  KnxDevice.psm1 (Gerätedienste am TP für die Devices-Stufe)
                  KnxSerial.psm1 (Ports finden, Gerät erkennen, Konsole bedienen)
                  KnxLogo.ps1 (Logo-Kopf aller Skripte)
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
                  Test-ResultContract.ps1 — prüft offline, welches Ergebnis ein Fall bekommt
                  New-TestReport.ps1 — HTML-Bericht aus den Lauf-Daten
viewer/           BusmonViewer.html · Start-BusmonBridge
repro/            Einzelfall-Reproduktionen
Reports/          über Run-Tests je Lauf ein Ordner <What>_<Zeit>/: Gesamtbericht (MD + JSON),
                  settings.json, HTML-Bericht; Devices, Features, Busmonitor und Hardening
                  schreiben ihre Stufenberichte noch direkt nach Reports/
QA-ACCEPTANCE.md  wann ein Testfall fertig ist
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

---

## 10. Das KNX/IP Validation Tool — Vorbereitung ist Pflicht

Das Werkzeug der KNX Association prüft gegen dieselbe Vorschrift wie die Conformance-Stufe, aber
mit einem eigenen Aufbau. Seine Konfigurationen liegen in `config/`:

```
config/KNX-IP-Validation-config-IPIF-Test.yml        Prüffälle Interface
config/KNX-IP-Validation-config-IPIF-Test-Setup.yml  Gerät + Aufbau (Adressen, SN, Schnittstelle)
config/KNX-IP-Validation-config-IPIF-NAT-Only.yml    nur die NAT-Fälle
config/KNX-IP-Validation-config-IPRO-Test.yml        Prüffälle Router
config/KNX-IP-Validation-config-IPRO-Test-Setup.yml  Gerät + Aufbau Router
```

Der YAML-Leser des Werkzeugs **wirft bei unbekannten Schlüsseln** statt sie zu überspringen — das
ist die Meldung „The selected file is not a valid configuration file!". Schlüssel und Reihenfolge
also nicht umsortieren.

### Vor dem Lauf: zwei Schritte, beide nicht optional

**1. Den Bus ruhig stellen — und das prüfen, nicht annehmen.**
Mehrere Prüffälle erwarten auf dem Tunnel bzw. der Routing-Gruppe **Stille** und melden den
ersten Rahmen, den sie sehen — ganz gleich, von wem er kommt. Ein einziges Gerät im Sekundentakt
macht sie damit unbestehbar. Also: alle nicht benötigten TP-Geräte abstecken, dann 90 s passiv
mithören und auf Null prüfen.

**2. Die Gruppenadressen der KOs des Prüflings entfernen.**
Zyklisches Senden abschalten genügt **nicht**. `TunnelActive` ist *ereignisgesteuert* und feuert
bei jedem Tunnel-Auf- und Abbau — und genau das tut das Werkzeug permanent. Für einen Lauf, dessen
Ergebnis etwas bedeutet, darf an diesen KOs keine Gruppenadresse hängen.

### Was es gekostet hat, das nicht zu tun

Zwei Läufe, **gleiche Firmware**, 193 Prüffälle, nur der Bus war unterschiedlich:

| Prüffall | lauter Bus | ruhiger Bus |
|---|---|---|
| `30212` Broadcast von TP getunnelt | Failure | Success |
| `60205` T_Data_Connected | Failure | Success |
| `60206` T_Data_Individual | Failure | Success |

Der Störer war ein fremdes `5.0.7`, das `0/7/0` im Sekundentakt schickte: 118 Rahmen in 150 s.
Dazu die vier KOs des Prüflings alle 10 s. Drei rote Fälle, kein Gerätefehler.

### Einen gemeldeten Rahmen zuordnen, bevor man das Gerät verdächtigt

Das Werkzeug druckt den Rahmen mit, der ihm nicht gefallen hat. Zwei Prüfungen entscheiden
schneller als jede Codesuche:

- **Quelladresse gegen die Geräteadresse des Prüflings.** Steht dort eine andere, ist es fremder
  Verkehr, den ein Interface weiterleiten *muss*. Die eigene Adresse liest `curl -s
  http://<ip>/ipif/state` als `pa`.
- **APCI gegen die erwartete Antwort.** `0x080` ist ein `A_GroupValue_Write` — niemals die Antwort
  auf einen `A_PropertyValue_Read`. Eine Geräteantwort ist individuell adressiert; ein
  Gruppentelegramm zählt nicht als Antwort.
