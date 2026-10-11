# Testprofile

Ein Profil ist eine benannte JSON-Datei, die einen Testlauf beschreibt: **was** gefahren wird,
**an welchem Gerät**, **mit welchem Testaufbau** und **was der Lauf abzudecken verspricht**. Es macht einen
Lauf wiederholbar und nachlesbar, statt dass die Werte bei jedem Start von Hand eingegeben werden.

Die Adressen des Testaufbaus stehen nicht im Profil, sondern einmal in `Test-Bench-Config.json` neben
`Run-Tests.ps1`. Ein Profil nennt nur noch, welches Gerät daraus der Prüfling ist und welche Werte es
übernimmt. Ändert sich eine Adresse, wird sie an einer Stelle geändert.

```
pwsh ./Run-Tests.ps1 -ListProfiles                  # alle Profile mit ihren Werten anzeigen
pwsh ./Run-Tests.ps1 -TestProfile interface-all     # ein Profil fahren
pwsh ./Run-Tests.ps1 -TestProfile interface-all -Ip 11.11.0.211   # ein Wert von Hand, der Rest aus dem Profil
```

## Begriffe

| Begriff | Bedeutung |
|---|---|
| **rig** | englisch für Prüfstand oder Testaufbau ("test rig"): alles, was um den Prüfling herum steht. Der Block `rig` im Profil beschreibt genau das |
| **Prüfling** (device under test, BDUT) | das Gerät, über das der Lauf urteilt |
| **Traffic-Interface** | ein zweites KNXnet/IP-Gerät auf derselben TP-Linie, das Telegramme auf den Bus legt |
| **Zeuge** (witness) | ein Interface mit Hardware-Busmonitor, das die Linie unabhängig mitliest |
| **Referenz** | ein zertifiziertes Fremdgerät, gegen das verglichen wird |

## Woher ein Wert kommt

In dieser Reihenfolge, der erste Treffer gilt:

1. **Kommandozeile** (`-Ip`, `-TrafficIp`, ...)
2. **Profil**, ein dort ausgeschriebener Wert
3. **Test-Bench-Config.json**, soweit das Profil darauf verweist (`device`, `traffic`, `rig.fromBench`)
4. **gemerkte Antwort** des letzten Laufs (`.last-run.json`), als Vorschlag in der Nachfrage
5. **Nachfrage** am Bildschirm

Ein leerer Wert (`""`) heißt "nicht gesetzt" und fällt auf die nächste Quelle durch.

## Test-Bench-Config.json – der Testaufbau an einer Stelle

Die Datei beschreibt den eigenen Aufbau und ist deshalb nicht eingecheckt (`.gitignore`). Eingecheckt ist die
Vorlage `Test-Bench-Config.example.json`:

```
cp Test-Bench-Config.example.json Test-Bench-Config.json     # dann die eigenen Adressen eintragen
```

Fehlt die Datei, lässt `Run-Tests.ps1` jedes Profil aus, das darauf verweist, und sagt das in einer Meldung.

```json
{
  "$schema": "./Test-Bench-Config.schema.json",
  "networkInterface": "en0",
  "devices": {
    "interface": { "ip": "11.11.0.210", "pa": "1.1.13", "role": "Interface", "hardwareBusmonitor": "yes" },
    "router":    { "ip": "11.11.0.126", "pa": "1.1.0",  "role": "Router",    "hardwareBusmonitor": "no"  }
  },
  "rig":    { "witnessIp": "11.11.0.2", "p2pTarget": "1.1.5", "...": "..." },
  "safety": { "allowedLines": ["1.1"] }
}
```

| Block | Inhalt |
|---|---|
| `networkInterface` | die Netzwerkschnittstelle des Rechners, an der der Testaufbau hängt (`en0`, `Ethernet 2`). `Tools/Test-RigNetwork.ps1` prüft und setzt die Wege darüber. Leer heißt: die Schnittstelle wird gesucht |
| `devices` | die KNXnet/IP-Geräte des Aufbaus unter einem frei gewählten Namen. Ein Profil nennt diesen Namen in `device` und `traffic`. Felder wie unter [`device`](#device--der-prüfling) |
| `rig` | alles um den Prüfling herum. Dieselben Felder wie der Block [`rig`](#rig--der-testaufbau) im Profil, ohne `trafficIp` |
| `safety` | die Linien, die der Aufbau ansprechen darf. Gilt für jedes Profil, das kein eigenes `safety` hat |

## Die mitgelieferten Profile

| Profil | Fährt | Prüfling | Zweck |
|---|---|---|---|
| `interface-all` | alles, auch zustandsändernde Fälle | IP-Interface | vollständiger Lauf vor einer Freigabe des Interface |
| `router-all` | alles, auch zustandsändernde Fälle | IP-Router | vollständiger Lauf vor einer Freigabe des Routers |
| `tp-all` | nur die Stufen für TP-Geräte | die TP-Geräte selbst, das Interface ist nur das Werkzeug | Geräteprüfung |
| `quick-check` | nur die Konformitätsstufe, nur lesend | IP-Router | Schnelltest nach einem Flash |

## Aufbau

```json
{
  "$schema": "./schema/profile.schema.json",
  "name": "...",        "description": "...",
  "what": "All",        "stages": "...",
  "device":   "interface",
  "traffic":  "router",
  "rig":      { "fromBench": "all" },
  "flags":    { ... },
  "requires": [ ... ],
  "safety":   { ... },
  "notes": "..."
}
```

### Kopf

| Feld | Bedeutung |
|---|---|
| `$schema` | Verweis auf das Schema. Damit zeigt der Editor die Feldbeschreibungen an und prüft die Datei |
| `name` | der Name, unter dem das Profil gestartet wird. Eine Datei ohne `name` ist kein Profil |
| `description` | ein Satz für die Profilliste |
| `what` | die Stufe: `Conformance`, `Features`, `All`, `Endurance`, `Reference`, `Stress`, `Busmonitor`, `Devices`, `Hardening` |
| `stages` | nur bei `what: All`: welche Stufen laufen, mit Komma getrennt. Ohne das Feld laufen alle. Bekannt sind `SelfTest`, `Dpt`, `HostStack`, `Conformance`, `Features`, `Rename`, `Busmonitor`, `Fidelity`, `DeviceState`, `Devices`, `Hardening`, `Legacy`, `Reference`, `EtsReadback`, `Speed` |
| `notes` | freier Text für den Leser |

### `device` – der Prüfling

Der Name eines Geräts aus `devices` in `Test-Bench-Config.json`, z. B. `"device": "interface"`. Wer ein Profil
ohne die Bench-Config schreiben will, setzt stattdessen die Werte selbst ein:
`"device": { "ip": "...", "pa": "...", "role": "...", "hardwareBusmonitor": "..." }`.

| Feld | Parameter | Bedeutung | Beispiel |
|---|---|---|---|
| `ip` | `-Ip` | IP-Adresse des Prüflings | `11.11.0.210` |
| `pa` | `-BdutPa` | physikalische Adresse des Prüflings. Der Lauf liest die Adresse, die das Gerät meldet; weicht ein ausdrücklich angegebenes `-BdutPa` ab, bricht er ab | `1.1.13` |
| `role` | `-Role` | `Interface` oder `Router`. Entscheidet, welche Fälle gelten: ein Router muss ROUTING bewerben, ein Interface darf es nicht | `Interface` |
| `hardwareBusmonitor` | `-Busmon` | `yes` oder `no`. Die Busmonitor-Fälle laufen nur mit `yes` | `yes` |

### `traffic` – das Traffic-Interface

Der Name eines Geräts aus `devices`. Seine IP wird zu `-TrafficIp`. Das Gerät **muss auf der TP-Linie des
Prüflings sitzen**. Ein ausgeschriebenes `rig.trafficIp` geht vor.

### `rig` – der Testaufbau

Üblich ist nur `fromBench`, dazu die Werte, die in diesem Profil abweichen:

| `fromBench` | Wirkung |
|---|---|
| `"all"` | alle Werte aus dem Block `rig` der Bench-Config |
| `["p2pTarget", "multicast"]` | nur die genannten Felder |
| fehlt | nichts wird übernommen |

Ein im Profil ausgeschriebenes Feld geht vor dem Wert aus der Bench-Config. `quick-check` nimmt so zwei
Felder und schaltet `powerGuard` selbst auf `off`.

| Feld | Parameter | Bedeutung | Beispiel |
|---|---|---|---|
| `trafficIp` | `-TrafficIp` | zweites Interface, das Telegramme auf den Bus legt. **Muss auf der TP-Linie des Prüflings sitzen** | `11.11.0.126` |
| `witnessIp` | `-WitnessIp` | Interface mit Hardware-Busmonitor, das die Linie mitliest. Weder der Prüfling noch das Traffic-Interface | `11.11.0.2` |
| `p2pTarget` | `-P2pTarget` | ein TP-Gerät, das auf Punkt-zu-Punkt-Anfragen antwortet | `1.1.5` |
| `deviceTargets` | `-DeviceTargets` | die TP-Geräte, über die die Gerätestufe urteilt, mit Komma getrennt | `1.1.5,1.1.8` |
| `testGa` | `-TestGa` | Gruppenadresse(n), auf die nur das Zielgerät reagiert | `0/7/1` |
| `serialPort` | `-SerialPort` | serielle Konsole des Prüflings. Die Hardening-Stufe steuert den FTC-Client darüber; ohne sie wird die Stufe übersprungen | `/dev/cu.usbmodem3101`, `COM5` |
| `ftcTarget` | `-FtcTarget` | das TP-Gerät, gegen das der FTC-Client in der Hardening-Stufe arbeitet | `1.1.8` |
| `referenceIp` | `-ReferenceIp` | eine zertifizierte Referenz. Wird benutzt, wenn `referenceIps` leer ist | `11.11.0.2` |
| `referenceIps` | `-ReferenceIps` | mehrere Referenzen für die Stufen Fidelity und Reference, mit Komma getrennt | `11.11.0.2,11.11.0.5` |
| `speedTarget` | `-SpeedTarget` | das TP-Gerät, das die Durchsatzmessung empfängt | `1.1.8` |
| `speedKb` | `-SpeedKb` | Nutzlast in KB je Übertragungsart, als Zeichenkette mit einer Zahl | `"50"` |
| `multicast` | `-Multicast` | Routing-Multicast-Gruppe des Laufs. `224.0.23.12` ist die Produktivgruppe: damit fällt die Routing-Suite weg, ein Testaufbau nimmt eine Laborgruppe | `224.0.23.13` |
| `powerGuard` | `-PowerGuard` | `on` oder `off`. Mit `on` werden die Netzteil-Relais vor jeder Stufe geprüft und `protectedTargets` durchgesetzt | `on` |
| `powerRelayWrite` | `-PowerRelayWrite` | Schalt-Gruppenadressen der Relais. Die **erste** muss das TP aller Geräte in `powerRelayFeeds` trennen | `0/3/100,0/3/110` |
| `powerRelayStatus` | `-PowerRelayStatus` | Status-Gruppenadressen, in derselben Reihenfolge | `0/3/101,0/3/111` |
| `powerRelayVia` | `-PowerRelayVia` | das Interface, über das die Relais geschaltet werden. Darf selbst nicht an den Relais hängen | `11.11.0.2` |
| `protectedTargets` | `-ProtectedTargets` | Geräte, die den Aufbau versorgen. Sie bekommen keinen Neustart, keinen Master-Reset und keinen Schreibzugriff | `1.1.3` |
| `powerRelayFeeds` | `-PowerRelayFeeds` | Prüflinge, deren TP die Relais trennen, als IP. Nur für sie laufen die KNX-Fehler-Fälle der Stufe DeviceState | `11.11.0.126` |

### `flags` – Schalter

| Feld | Parameter | Bedeutung |
|---|---|---|
| `guided` | `-Guided` | Fälle zulassen, die eine Hand am Gerät oder in der ETS brauchen |
| `includeDestructive` | `-IncludeDestructive` | Fälle zulassen, die den Gerätezustand ändern. Jeder stellt ihn wieder her |
| `iterations` | `-Iterations` | Anzahl der Durchgänge bei `what: Endurance`; `0` lässt die Vorgabe |

### `requires` – was das Profil verspricht

Eine Liste von Argumenten, die einen Wert haben **müssen**, aus dem Profil oder von der Kommandozeile. Fehlt
einer, startet der Lauf nicht (Exit 3). Der Grund: ein Lauf namens "All" lief früher auch ohne Zielgerät oder
Zeugen zwanzig Minuten durch und meldete PASS über Fälle, die er nie ausgeführt hatte.

Erlaubte Einträge: `-BdutPa`, `-TrafficIp`, `-P2pTarget`, `-DeviceTargets`, `-TestGa`, `-WitnessIp`,
`-SerialPort`, `-FtcTarget`, `-IncludeDestructive`, `-Guided`, `-Multicast` (verlangt eine Laborgruppe, also
nicht `224.0.23.12`).

### `safety` – was der Lauf ansprechen darf

| Feld | Bedeutung |
|---|---|
| `allowedLines` | die TP-Linien, die zum Testaufbau gehören, als `Bereich.Linie`, z. B. `["1.1"]`. Liegt der Prüfling, `p2pTarget`, `ftcTarget` oder ein Eintrag aus `deviceTargets` auf einer anderen Linie, bricht der Lauf vor dem ersten Telegramm ab |
| `note` | warum diese Linien, für den Leser |

Das ist die Sicherung gegen einen Test, der versehentlich ein Gerät der produktiven Anlage anspricht.
Hat das Profil kein `safety`, gilt das aus `Test-Bench-Config.json`.

## Ein eigenes Profil anlegen

1. Die Adressen des eigenen Aufbaus in `Test-Bench-Config.json` eintragen. Was es nicht gibt, bleibt `""`.
   Die mitgelieferten Profile laufen damit schon.
2. Für einen eigenen Lauf ein vorhandenes Profil kopieren, z. B. `interface-all.json` nach `mein-lauf.json`.
3. `name` ändern. Der Name muss nicht dem Dateinamen entsprechen, es ist aber übersichtlicher.
4. `device` und `traffic` auf die Gerätenamen aus der Bench-Config setzen, `what`/`stages` auf das, was laufen
   soll.
5. `requires` so lassen, wie es zum Profil passt: lieber ein Lauf, der nicht startet, als einer, der grün
   meldet, ohne geprüft zu haben.
6. Prüfen: `pwsh ./Run-Tests.ps1 -ListProfiles` zeigt das Profil mit den aufgelösten Werten.

Die Zeile `"$schema": "./schema/profile.schema.json"` bleibt stehen.

## Hilfe im Editor und Prüfung

Mit der `$schema`-Zeile zeigt Visual Studio Code beim Überfahren eines Feldes dessen Beschreibung an, schlägt
Feldnamen vor und markiert Tippfehler, unbekannte Felder und Werte, die nicht passen (eine Rolle, die es
nicht gibt, eine Adresse im falschen Format).

Von Hand prüfen, ab PowerShell 7:

```
Test-Json -Path ./Profiles/mein-lauf.json -SchemaFile ./Profiles/schema/profile.schema.json
Test-Json -Path ./Test-Bench-Config.json    -SchemaFile ./Test-Bench-Config.schema.json
```

`-SchemaFile` gibt es ab PowerShell 7.4. Es ist nötig, weil das Profilschema auf das Schema der Bench-Config
verweist und der Verweis nur über den Dateipfad aufgelöst wird.

`Run-Tests.ps1` prüft beim Laden beide Dateien gegen ihr Schema und nennt als Warnung die Stelle, die nicht
passt; geladen wird die Datei trotzdem. Mit einer älteren PowerShell entfällt die Schemaprüfung.

## Was nicht in ein Profil gehört

- **Passwörter.** Das FTC-Passwort wird nur auf der Kommandozeile übergeben (`-FtcPassword`) und nirgends
  gespeichert.
- **Adressen des Testaufbaus.** Sie stehen in `Test-Bench-Config.json`, ebenso die Netzwerkschnittstelle des
  Rechners (`networkInterface`).
