# Wann ein Testfall fertig ist

**Für wen:** wer einen Testfall unter `scripts/Test/` schreibt oder gegenliest. **Wann:** bevor der
Fall in eine Suite geht, und bevor du ein Ergebnis daraus meldest.

Die zwölf Fragen unten dauern zusammen ein paar Minuten. Sind alle mit Ja zu beantworten, ist der
Fall fertig. Bleibt eine offen, ist das kein Schönheitsfehler: dann behauptet der Fall etwas über
das Gerät, was er nicht zeigt — und genau daraus sind alle zwölf Regeln entstanden.

Jede Regel nennt deshalb **den Fall, der sie erzwungen hat**. Wenn dir eine Regel übertrieben
vorkommt, lies erst diesen Gegenfall; ohne ihn lässt sich über die Regel nicht reden.

Der Aufbau ist überall gleich: **Regel** — was gilt. **Erzwungen durch** — welcher echte Fall danebenlag.
**Form** — wie es im Code aussieht. **Vorbild im Bestand** — wo es schon richtig gemacht ist.

---

## Die Checkliste

| # | Frage | Wenn nein |
|---|---|---|
| 1 | Wenn Abwesenheit das Kriterium ist: steht ein Lebendbeweis **danach** im selben Fall? | nicht abnehmbar |
| 2 | Steht die Positivkontrolle **im** Fall, wenn der Fall mehrere Negative in Folge fährt? | nicht abnehmbar |
| 3 | Beweist der Fall, dass der Stimulus den behaupteten Codepfad erreicht hat? | nicht abnehmbar |
| 4 | Kann ein FAIL dieses Falls nur vom Gerät kommen, nie vom Prüfstand? | nicht abnehmbar |
| 5 | Scheitert der Fall, wenn der Prüfling die Eigenschaft nicht hat — statt durchzulaufen? | nicht abnehmbar |
| 6 | Ist jedes Ergebnis das engste zutreffende (N-A / SKIP / NOT-RUN / NO-PROOF / FAIL)? | Ergebnis korrigieren |
| 7 | Ist jedes Toleranzband mit einer **Messung aus dieser Sitzung** belegt? | Band neu herleiten |
| 8 | Ist jede Klausel **und** jede Seite in `-Clause` selbst aufgeschlagen worden? | Zitat neu herleiten |
| 9 | Trägt die zitierte Klausel das Kriterium wirklich — oder nur ein verwandtes? | Klausel nachziehen |
| 10 | Wird jeder geteilte Puffer vor der Frage geleert, nicht danach? | nicht abnehmbar |
| 11 | Antwortet dieser Fall auf dieselbe Frage in derselben Form wie sein Zwilling? | Divergenz melden |
| 12 | Geht die Summe der Ergebnisse gegen die **erwartete** Fallzahl auf? | Zählspalte fehlt |

---

## 1. Abwesenheit als Kriterium

**Regel.** „Kein Frame", „keine Antwort", „`$null`", „`Count -eq 0`", „keine Ausnahme" ist allein
nie ein Erfolgskriterium. Daneben muss im **selben Fall, nach dem Stimulus**, ein positiver
Nachweis stehen, dass der Kanal noch trägt und der Prüfling noch antwortet.

**Erzwungen durch.** `9-Tcp.Tests.ps1` K-2.5.21: die erste Fassung nahm `$null -eq $r` als Erfolg.
`Receive-KnxTcpFrame` gibt `$null` aber auch zurück, wenn die Gegenseite die Verbindung schliesst
(`lib/KnxTcp.psm1`: Timeout und FIN — derselbe Rückgabewert). Der Fall bestand deshalb gegen einen
Server, der die TCP-Verbindung sofort schloss, und er bestand gegen dasselbe Gerät, das ab sieben
offenen Verbindungen auch auf **gültige** Anfragen schwieg. Gleiche Klasse stand in
`D-Device.Tests.ps1` D-23.x/D-24.1: `Assert-KnxEqual 0 @($frames).Count` bzw.
`Assert-KnxEqual 0 $unexpected.Count` ohne Nachweis, dass der Tunnel danach noch lebte.
Inzwischen nachgezogen: beide rufen bei Schweigen `$liveGate` vor der Assertion (zur Grenze bei
D-24.1 siehe Regel 2).

**Form.** `Test-StillServing` nach jedem Negativ (`9-Tcp.Tests.ps1`), bzw. `$liveGate`
(`Invoke-KnxSuiteDevice` in `D-Device.Tests.ps1`), bzw. ein Lesezugriff, der gelingen **muss**.
Ein offener Socket ist kein Lebendbeweis: er beweist nicht, dass der Empfänger auf dem Strom
resynchronisiert hat.

**Vorbild im Bestand.** `D-Device.Tests.ps1` D-2.4 stellt **zwei** Fragen nach dem Reiz, in
dieser Reihenfolge: lebt das **Gerät** (verbindungslos, `$alive`), und lebt die **Verbindung**
(`$after`). Nur die zweite zu stellen meldet „Gerät tot" für ein Gerät, das lediglich die Sitzung
geschlossen hat, die es halten sollte.

**Zusatz.** Wer `$null` als Kriterium benutzt, muss die Ursachen trennen. Ein Helfer, der
Timeout, FIN, Fehlerstatus und Parse-Fehler auf denselben Wert abbildet, macht das unmöglich —
siehe Regel 4.

## 2. Positivkontrolle im Fall, nicht davor

**Regel.** Eine Positivkontrolle als eigener, früherer Fall beweist nur, dass das Gerät
**irgendwann** antwortete. Sie muss in den Fall hinein, wenn der Fall mehrere Negative in Folge
fährt oder wenn der Zustand des Prüflings sich durch die Negative ändern kann.

**Erzwungen durch.** Beide Sitzungen hatten die Kontrolle als Vorgängerfall. K-2.5.21 fährt fünf
Negative hintereinander, jedes mit eigener TCP-Verbindung; eine Kontrolle davor sagt nichts über
den Zustand bei Negativ Nummer vier. Heute steht `Test-StillServing` **in** jeder Iteration
(K-2.5.21 in `9-Tcp.Tests.ps1`, Schleife über die fünf Negative) und die Annahme-Kontrolle am Ende
desselben Falls.

**Grenze.** Die Kontrolle am Ende prüft die Annahme der gültigen Kombination; den Kanal prüft die
Kontrolle **je Negativ**. Beides ist nötig, keins ersetzt das andere.

**Einmal je Fall reicht nicht, wenn der Fall eine Kehre fährt.** `D-Device.Tests.ps1` hält
`$liveGate` laut Kommentar an der Definition bewusst auf einmal je Fall, und D-24.1 ruft es einmal
nach der Kehre, nicht je Reiz. Für einen Fall mit einem Reiz trägt das. Für D-24.1 — 39 Reize auf
einer Verbindung — feuert das Gatter nur, wenn **alle 39** schwiegen (Aufruf nach der Kehre);
zieht ein einziger Reiz eine Reaktion, bleiben die anderen 38 Schweigen unbelegt. Die Regel lautet
deshalb: **je Reiz, wenn der Reiz einzeln bewertet wird.**

## 3. Nachweis, dass der Stimulus angekommen ist

**Regel.** Der Fall muss zeigen, dass der Prüfling den Codepfad betreten hat, über den der Fall
urteilt. Ein Reiz, den das Gerät verwerfen darf, prüft die Eigenschaft nicht, die im Titel steht.

**Erzwungen durch.** `9-Tcp.Tests.ps1` K-2.5.11 („Gesamtlänge 508 wird korrekt behandelt"): die
erste Fassung schickte einen unbelegten Service-Typ und prüfte „nicht geschlossen, noch im
Tritt". Das bestand bei Gesamtlänge 1024 an einem Gerät mit gemessenen 600 Oktetten
Empfangspuffer — also auf dem **Skip**-Zweig, während der Fall über den **Verarbeitungs**-Zweig
urteilte. Konsumieren und Resynchronisieren tut der Skip-Zweig ebenso; die Fassung konnte die
Zweige nicht unterscheiden und ein Gerät mit Puffer unter 508 nie durchfallen lassen.

**Form.** Ein Reiz, dessen Antwort nur der gemeinte Zweig erzeugen kann. Heute: ein
`SEARCH_REQUEST_EXTENDED` auf exakt 508 Oktette, dessen Antwort `0x020C` nur kommt, wenn der
Körper verarbeitet wurde (K-2.5.11 in `9-Tcp.Tests.ps1`). Schweigen wäre der Skip-Zweig.

**Zweiter Beleg derselben Regel.** K-2.5.3 („verschmolzene Frames"): zwei **gleiche**
`DESCRIPTION_REQUEST` in einem Write bestanden auch bei falscher Grenzerkennung, weil Oktett
15..28 des Blobs selbst ein gültiger `06 10 02 03`-Header ist. Erst zwei **verschiedene** Frames
mit zwei verschiedenen Antworten (`0x0204`, dann `0x0208`) machen die Grenze prüfbar.

**Dritter Beleg.** Der Reiz muss auch die richtige **Grösse** haben: „nicht schliessen bei
Überlänge" erreicht den Skip-Zweig erst bei 65535 Oktetten, weil jedes Gerät mit grösserem Puffer
darunter den Verarbeitungszweig nimmt (K-2.5.8 in `9-Tcp.Tests.ps1`).

**Auf dem TP-Bus ist der Nachweis das Link-Layer-Acknowledge.** Das `.Acked` von
`Send-KnxDeviceTpdu` ist es **nicht**: es ist das TUNNELLING_ACK der Schnittstelle aus
`Send-KnxTunnelCemi` und zeigt nur, dass die Schnittstelle das Frame angenommen hat.
`D-Device.Tests.ps1` D-2.4 prüft genau das (`Assert-KnxTrue $sent.Acked`, „the interface did not
accept the reserved-TPCI telegram") — ohne das besteht der Fall auch dann, wenn der Prüfstand nie
gesendet hat, aber dass der Reiz das Gerät erreicht hat, ist damit nicht belegt. Einen
geräteseitigen Empfangsnachweis prüft D-18.1: `.Acked` aus `Invoke-KnxDeviceService` ist das T_ACK
des Geräts, und fehlt es, endet der Schweige-Zweig als N-A. `Get-KnxFramesFrom` verwirft selbst die
Quittung der Schnittstelle (`lib/KnxDevice.psm1`, `[void](Send-KnxDeviceTpdu ...)`) — jeder Fall,
der darüber zählt, hat keinen der beiden Nachweise.

## 4. Ein FAIL ist eine Aussage über das Gerät — sonst ist es keins

**Regel.** Für jeden Fall muss beantwortbar sein, ob ein FAIL das Gerät oder den Prüfstand
beschreibt. **Eine unbehandelte Ausnahme ist nie eine Aussage über das Gerät.** Ein Helfer, der
Geräteantwort und Prüfstandsstörung auf denselben Rückgabewert abbildet, macht jedes FAIL seiner
Fälle unbrauchbar.

**Erzwungen durch.** Drei Funktionen wurden aus einem Skript-Rumpf in ein PowerShell-**Modul**
verschoben. Ein Modul sieht die Scope-Kette des Aufrufers nicht, die Konstantentabelle `$K` war
unsichtbar, die Funktionen warfen bei jedem Aufruf. `Invoke-KnxTestCase` bucht eine unbehandelte
Ausnahme regelkonform als FAIL (in `lib/KnxTest.psm1`) — 13 Fälle im Standardprofil, bis zu 39
mit allen Schaltern, alle rot, alle als Geräteurteil ausgewiesen.

**Zweiter Beleg.** `10-Properties.Tests.ps1` `Get-PropOrNull` gab bei **jedem** Misserfolg
`$null` zurück: Property nicht vorhanden, Verbindung weg, Timeout, Fehlerstatus, unparsbare
Antwort. Der Fall meldete daraufhin „Property konnte nicht gelesen werden" — ein Geräteurteil
über eine Ursache, die er nicht kennt. Inzwischen behoben: `Read-PropOutcome` trennt vier Ausgänge
(`Present` / `Absent` / `NoAnswer` / `Mismatch`); von den Fehlausgängen kann nur `Absent` ein
Geräteurteil tragen (bei `Mandate = 'Required'`), `NoAnswer` und `Mismatch` enden als N-A.

**Form.** Drei Ausgänge statt zwei, wie `Test-KnxDeviceStillUsable` in `lib/KnxDevice.psm1` es
vormacht: `Ok` / `RigFault` / Befund. `RigFault` endet als N-A mit Grund, nicht als FAIL — so
bereits benutzt in `$liveGate` (`D-Device.Tests.ps1`). Für Property-Lesezugriffe heisst das:

- keine Antwort / Verbindung tot → Prüfstand, N-A oder NOT-RUN, **nie** FAIL
- Antwort mit Fehlerstatus → Geräteurteil, FAIL zulässig
- Antwort ohne Element → Geräteurteil „Property existiert nicht", FAIL zulässig

**Kaskade.** Eine Verbindung, die für eine ganze Sektion einmal geöffnet wird
(`$script:PropConn` aus `Invoke-KnxSuiteProperties` in `10-Properties.Tests.ps1`), macht aus einem
Verbindungsverlust in Fall drei einen Rest der Sektion ohne Geräteurteil — früher rot, heute N-A
über `Read-PropOutcome` (`NoAnswer`); auf einem Router enden die von PID 70 abhängigen Fälle
C-72..C-75 dann als NOT-RUN. Wer eine Verbindung teilt, muss ihre Lebendigkeit je Fall
prüfen oder sie neu öffnen.

## 5. Ein Fall, der nichts prüft, endet als NO-PROOF

**Regel.** Jeder Fall muss mindestens eine Assertion **auf einem empfangenen Wert** ausführen oder
ein Ergebnis setzen. Ein Rumpf, der nur liest und protokolliert, hat nichts bewiesen.

**Erzwungen durch.** `Invoke-KnxTestCase` in `lib/KnxTest.psm1` belegt `$result = 'PASS'` vor.
Früher entstand ein anderes Ergebnis nur durch einen Wurf aus dem Rumpf, und der Prüfstand zählte
**keine Assertions**: ein Rumpf ohne jede Assertion endete als PASS, und `Judged = Pass + Fail`
zählte ihn als beurteilt.

**Heute durchgesetzt.** Jede `Assert-Knx*`-Funktion in `lib/KnxTest.psm1` ruft als Erstes
`Add-KnxAssertion`, vor der Bedingung, damit auch eine fehlschlagende Assertion zählt; ein
suite-eigener `Assert-*`-Helfer zählt nur über die Bibliotheks-Assertions, die er aufruft.
`Invoke-KnxTestCase` setzt den Zähler je Fall auf 0 und macht aus einem Rumpf, der ohne Wurf und
ohne Assertion endet, **NO-PROOF**. SKIP, N-A, NOT-RUN und FAIL kommen per Wurf und bleiben, was
sie sind. `Tools/Test-ResultContract.ps1` prüft offline, dass jede Fallform dieses Ergebnis und
diese Assertion-Zahl bekommt. NO-PROOF zählt nicht in `Judged` (`Get-KnxRunSummary`), hat eine
eigene Spalte in Konsole (`Write-KnxRunSummary`), Bericht und Maschinendatei, und
`Write-KnxRunGaps` nennt jeden solchen Fall mit Id.

**Grenze.** Der Zähler weiss nur, **dass** eine Assertion lief, nicht **worauf**. Eine Assertion auf
einen selbst gebauten Wert zählt genauso wie eine auf die Antwort des Geräts; „auf einem
empfangenen Wert" bleibt Prüffrage an den Gegenleser.

**Belege im Bestand, beide inzwischen nachgezogen.** `D-Device.Tests.ps1` D-14.1 („… wird
konsistent beantwortet oder ignoriert") enthielt im ganzen Rumpf **keine** Assertion: Schweigen
endete als N-A, eine Antwort wurde nur protokolliert. Heute prüft der Antwort-Zweig Länge und Echo
des Parametertyps (`Assert-KnxTrue`, `Assert-KnxBytes`). D-18.1 endete im **Schweige**-Zweig mit
`Add-KnxEvidence` — und damit PASS, auch gegen ein totes Gerät. Heute prüft der Zweig das
Transport-Acknowledge (sonst N-A), ruft `$liveGate` und endet in `Assert-KnxTrue (-not $answered)`.

**Abgrenzung nach oben.** `10-Properties.Tests.ps1` C-R51 liest `PID_MEDIUM_STATUS`, protokolliert
den Wert und setzt bewusst keine Assertion (`Invoke-PropCase`, Zweig für `Mandate =
'Informational'`): die zitierte Klausel beschreibt den Inhalt, fordert die Implementierung nicht.
Das ist zulässig (Regel unten); auf einem Router, der antwortet, ist das Ergebnis NO-PROOF (auf
einem Gerät ohne Routing N-A), und der Titel sagt es („read and reported, not required by the cited
clause").

**Abgrenzung.** Einen Wert bewusst nur zu beobachten ist zulässig, wenn eine Assertion darauf
nie fehlschlagen könnte (gesunder Bus liest 0). Der Prüfstand weist den Fall dann als NO-PROOF aus;
der Grund gehört in den Fall und die fehlende Abdeckung in den Kopf der Suite — nicht in ein
grünes Ergebnis ohne Hinweis.

## 6. Welches Ergebnis

| Ergebnis | Bedeutung | Vollständige Aussage? |
|---|---|---|
| **PASS / FAIL** | Das Gerät wurde beurteilt. | ja |
| **N-A** | Die Geräteklasse kennt die Funktion nicht. Auch: Prüfstandsstörung, die kein Geräteurteil erlaubt. | ja |
| **SKIP** | Ein Schalter oder ein Bediener hat den Fall abgewählt. | ja |
| **NOT-RUN** | Etwas, das laufen sollte, lief nicht — ein Eingabewert fehlte. | **nein** |
| **NO-PROOF** | Der Fall lief bis zum Ende und hat keine Assertion ausgelöst. Keine Aussage über das Gerät. | **nein** |
| **DROPPED** | Eine ganze Suite wurde vor dem Start verworfen. | **nein** |

**N-A ist eine vollständige Aussage.** „Das Gerät hat keine Routing-Funktion, also bindet die
Klausel es nicht" ist eine Aussage, kein Loch. Deshalb ist N-A das richtige Ergebnis für eine
optionale Funktion (`Test-TcpApplicable` in `9-Tcp.Tests.ps1`: TCP ist laut 03_08_02 8.4.1 p.43
optional) **und** für eine Prüfstandsstörung, die dem Gerät nichts anlastet.

**NOT-RUN, NO-PROOF und DROPPED sind Löcher.** Sie müssen den Lauf als unvollständig kennzeichnen.
`Set-KnxTestNotRun` in `lib/KnxTest.psm1` verlangt `-MissingInput` und `-Reason` beide
verpflichtend, damit der nächste Lauf vollständig sein kann. NO-PROOF setzt kein Fall selbst; der
Prüfstand vergibt es (Regel 5).

**Nie SKIP, wo N-A gilt.** Drei verschiedene Dinge landeten früher in einem SKIP-Eimer, und ein
Report, der sie nicht trennt, meldet „bestanden" über Arbeit, die er nie getan hat
(`.DESCRIPTION` von `Set-KnxTestNotRun` in `lib/KnxTest.psm1`).

## 7. Toleranzbänder

**Regel.** Ein Band wird aus einer Messung **dieser Sitzung** hergeleitet: mindestens fünf
Stichproben, Streuung notiert, Auflösung des Messmittels notiert. Das Wort „Jitter" ist keine
Herleitung. Wo die Prüfspezifikation ein Band nennt, gilt deren Band.

**Erzwungen durch.** K-2.5.17 (TCP-Idle-Timeout) hatte 0,5x..1,5x, begründet mit
Harness-Jitter — das Band nahm 5000..15000 ms für einen Wert an, den 03_08_02 8.4.3.2 p.44 auf
„10 seconds" festlegt. Die Messung beendete das Argument: fünf Stichproben in 10081..10097 ms,
Streuung **16 ms**, Poll-Auflösung 20 ms. Heute 0,9..1,1x, wie 08_TSSK 2.5.17 es verlangt
(K-2.5.17 in `9-Tcp.Tests.ps1`).

**Prüffrage.** Welche Messung rechtfertigt die Breite, und wo steht sie? Steht sie nirgends, ist
das Band nicht abgenommen — auch wenn es eng aussieht.

**Gegenrichtung.** Ein Band braucht eine **Untergrenze**, wo die Klausel ein Warten fordert. Ein
Fall, der nur „irgendwann geschlossen" prüft, besteht auch bei sofortigem Schliessen und prüft
das „shall wait" der Klausel dann nicht.

## 8. Pflichten eines `-Clause`-Eintrags

**Regel.** Klausel **und** Seite selbst aufschlagen. Nicht aus einem Kommentar, einer anderen
Suite oder dem Gedächtnis übernehmen. Ein nachgeprüfter falscher Wert bleibt falsch; ein neu
hergeleiteter nicht.

**Erzwungen durch.** Heute zwei falsche Zitate in Sitzung A (Klausel **und** Seite) und sechs
falsche Erwartungswerte in Sitzung B. Beide Klassen überleben jedes „sieht plausibel aus".

**Vorgehen, das trägt.** Seitenzahl = gedruckte Seite aus der Fusszeile („`page 45 of 60`"), nicht
der PDF-Index. In `03_08_02` stimmen beide überein, in `03_05_01` ist die Fusszeile abschnittsweise
gestückelt — dort zählt die gedruckte Zahl.

**Was in Anführungszeichen steht, steht wörtlich so im Text.** Eine Umschreibung in
Anführungszeichen ist ein falsches Zitat. Beispiel im Bestand, inzwischen behoben: K-2.5.11 in
`9-Tcp.Tests.ps1` zitierte „as if it was not there" für 03_08_02 7.6.3.3.1 p.34; die Stelle sagt
„react as if this SRP were not present". Die Aussage trug, der Wortlaut war umschrieben. Heute
gibt der Kommentar die Aussage ohne Anführungszeichen wieder.

## 9. Die Klausel muss das Kriterium tragen

**Regel.** Die zitierte Stelle muss genau das fordern, was der Fall behauptet — für **diese**
Geräteklasse. Eine Klausel, die den Inhalt einer Eigenschaft beschreibt, fordert nicht ihre
Existenz.

**Erzwungen durch.** `03_08_03` unterscheidet systematisch: wo Implementierung Pflicht ist, steht
ein eigener Satz dafür — „This Property shall be implemented by any KNXnet/IP Server" (2.5.20
p.14), „by devices providing KNXnet/IP Routing" (2.5.21 p.14, 2.5.23 p.15, 2.5.24 p.15, 2.5.25
p.15, 2.5.26 p.16), „by any KNXnet/IP device" (2.5.27 p.16), „mandatory for devices implementing
KNXnet/IP or KNX IP" (2.5.28 p.16). Wo dieser Satz fehlt, fehlt die Pflicht. 2.5.14 p.12
(`PID_DHCP_BOOTP_SERVER`) und 2.5.18 p.13 (`PID_TTL`) haben ihn nicht — sie beschreiben nur
Inhalt und Zugriffsart. Ein FAIL darauf ist nicht aus der zitierten Klausel herzuleiten.

**Prüffrage.** Steht in der Klausel ein Satz, der Implementierung fordert, und nennt er die
Klasse des Prüflings? Wenn nein: N-A oder Beobachtung, nicht FAIL.

**Gegenrichtung, gleich wichtig.** Wenn ein Kriterium aus einer **anderen** Quelle kommt, muss
diese Quelle im `-Clause` stehen. K-2.5.21 argumentiert aus 03_08_02 8.6.2.1 Table 10 p.49; die
Tabelle beschränkt aber nur die Kodierung **für den Host-Protocol-Code IPV4_TCP**. Dass eine
UDP-kodierte HPAI auf einer TCP-Verbindung unzulässig ist, steht dort nicht — es steht in
08_TSSK 2.5.21 p.224 („TCP connection and UDP Route Back HPAI: Not allowed"). Zwei der fünf
Negative hängen also an der TSSK-Quelle, nicht an der Core-Klausel, aus der der Fall argumentiert.

## 10. Geteilte Puffer und geteilter Sitzungszustand

**Regel.** Wer eine neue Frage stellt, leert den geteilten Puffer **vor** der Frage und
protokolliert, was darin lag. Nach der Frage zu leeren, verwirft den Beweis.

**Erzwungen durch.** `Test-KnxTcpClosed` pumpt alles, was der Socket hergibt, in den
Sitzungspuffer, während es auf ein FIN wartet, das nicht kommt (`lib/KnxTcp.psm1`). Die
Lebendprobe danach las deshalb die **vorige** Antwort und urteilte darüber. Ein Review hat beide
Richtungen am Gerät reproduziert: falsch-rot, als der Rest ein `SEARCH_RESPONSE_EXTENDED` war
(`0x020C != 0x0204`, obwohl der Strom im Tritt war), und falsch-grün, als der Rest zufällig ein
`DESCRIPTION_RESPONSE` war — dann wurde Resynchronisierung überhaupt nicht geprüft.

**Zweiter Beleg.** `Receive-KnxTcpFrame` gab in einer früheren Fassung bei `total < 6` den ganzen
Puffer zurück und leerte ihn — ein vollständiges Frame aus demselben Segment verschwand dabei.
Heute werden nur die sechs Header-Oktette verbraucht (`lib/KnxTcp.psm1`).

**Form.** `Clear-KnxTcpPending` gibt die Anzahl zurück, weil „wie viele Oktette lagen noch da"
selbst ein Befund ist: für Fälle, in denen das Gerät schweigen muss, ist alles ausser 0 der
Befund (`Assert-TcpClosedAfter` und K-2.5.8 in `9-Tcp.Tests.ps1`).

**Dritter Beleg, Tunnelseite.** `Receive-KnxTunnelCemi` in `lib/KnxTest.psm1` gibt geparkte Frames
zuerst heraus und liefert `Pending[0]` **ohne Altersprüfung und ohne Bezug zum laufenden Reiz**.
Ein Frame, das ein früherer Reiz auf derselben Verbindung geparkt hat, erreicht damit die nächste
Messung, als wäre es gerade eingetroffen. Die Leerfunktionen existieren dafür
(`Clear-KnxTunnelParked`, `Clear-KnxTunnelTraffic`, `Read-KnxTunnelParked`); `Clear-KnxTunnelTraffic`
wird in `6-Routing`, `5-Tunnelling` und `4-DeviceManagement` benutzt — in `D-Device.Tests.ps1`
**keine der drei, kein einziges Mal** (nachgezählt: 0 Treffer; nur mittelbar leert
`Open-KnxBusWitness` die Zeugen-Verbindung beim Öffnen, nicht die Verbindung des Reizes). Am
stärksten wirkt das, wo mehrere Reize eine Verbindung teilen und Frames gezählt werden.

**Regel für Helfer.** Ein Helfer, der aus geteiltem Zustand liest, leert entweder selbst zuerst
(wie `Test-StillServing` in `9-Tcp.Tests.ps1`) oder dokumentiert in seinem `.DESCRIPTION`, dass
der Aufrufer es tun muss. Beides ungeschrieben zu lassen ist der Fehler.

**Gegenbeispiel, richtig gemacht.** `D-Device.Tests.ps1` D-21.1 leert den Zeugen vor der Messung,
mit dem Grund im Kommentar: was der Lesezugriff auf dem Zeugen hinterliess, ist kein Beweis für
den Schreibzugriff.

## 11. Zwei Fälle, eine Frage, eine Antwortform

**Regel.** Stellen zwei Fälle dieselbe Frage, benutzen sie dieselbe Antwortform. **Divergenz ist
ein Befund, auch wenn beide grün sind** — sie ist der verlässlichste Hinweis darauf, dass eine
der beiden Antworten falsch ist.

**Erzwungen durch.** Dreimal am selben Tag in Sitzung B: Lebendbeweis nach Schweigen wurde in
D-32.x abgerufen, in D-23/D-24 nicht. Zustandsrücknahme wurde in G-1.1 per Assertion ausserhalb
des `finally` geprüft, in D-26.3 und D-34.x gar nicht. Derselbe Kommentarsatz stand in zwei
Dateien, einmal angepasst, einmal nicht. Die ersten beiden sind inzwischen nachgezogen: D-23/D-24
rufen `$liveGate`; D-26.3 und D-34.x prüfen die Rücknahme nach dem `finally` auch dann, wenn der
Rumpf geworfen hat. G-1.1 tut das nicht — dort entfällt die Prüfung, sobald der Rumpf wirft. Die
Form ist damit wieder verschieden, jetzt mit G-1.1 als schwächerem Zwilling.

**Prüffrage.** Welcher andere Fall stellt dieselbe Frage, und beantwortet er sie gleich? Wenn
nicht: welcher von beiden ist falsch? Die Antwort „beide sind grün" ist keine.

## 12. Nichts darf in einer grünen Überschrift verschwinden

**Regel.** Die Summe der Ergebnisse geht gegen die Zahl der **erwarteten** Fälle auf, nicht gegen
die Zahl der gelaufenen. Was vor dem Start wegfällt, braucht eine eigene Spalte — in der Konsole
**und** in der Maschinendatei.

**Erzwungen durch.** Eine Suite, die ein Sicherheitsgatter vor dem Start verwirft, hinterlässt
keine Fälle und taucht in keiner Zählspalte auf. Ein Router-Lauf, dessen Sektion 6 nie lief, las
„conformance PASS" (`.DESCRIPTION` von `Add-KnxRunDropped` in `lib/KnxTest.psm1`). Deshalb gibt
es `Add-KnxRunDropped` und die Spalte `Dropped`; `Total` in `Get-KnxRunSummary` zählt weiterhin
nur **gelaufene** Fälle, `Judged` nur PASS+FAIL.

**Prüffrage.** Kann ein Auswerter aus der Maschinendatei allein `total == Summe der Ergebnisse`
nachrechnen und jede Differenz benennen? Eine Zählspalte, die nur in der Konsole existiert, macht
eine Differenz unerklärbar.

---

## Prüfstand-Hygiene

**Belegte Slots.** Ein Tunnel-Pool ist endlich. Ein Fall, der einen Slot belegt, gibt ihn im
`finally` zurück; ein Fall, der mehrere Verbindungen in Folge öffnet, nennt in seinem Kommentar,
wie viele Slots er gleichzeitig hält. Gemessen, nicht angenommen: dasselbe Gerät schwieg ab sieben
offenen Verbindungen auch auf gültige Anfragen — jeder Negativfall, der danach läuft, urteilt
über einen erschöpften Pool statt über die Klausel.

**Wiederholbarkeit.** Ein Fall, der nur im ersten Lauf nach einem Neustart besteht, ist nicht
abgenommen. Zwei aufeinanderfolgende Läufe ohne Neustart dazwischen, gleiches Ergebnis. Ein Fall,
der Zustand ändert, nimmt ihn im `finally` zurück und prüft die Rücknahme mit einer Assertion —
nicht stillschweigend.

**Firmware-Stand vor dem Urteil.** Bauzeit ablesen genügt nicht. Beweisbar getrennt wird
„das Gerät kann es nicht" von „der Flash ist älter als der Fix" so:

1. Commit-Hash der eingebauten Bibliothek aus dem Prüfling auslesen.
2. `git merge-base --is-ancestor <hash> HEAD` gegen die eigenen Commits.
3. `grep` im Quelltext **genau dieses Stands** nach der Eigenschaft, die der Fall erwartet.

Ohne diese drei Schritte ist ein FAIL gegen eine neu implementierte Eigenschaft unbelegt.

**Reihenfolgeunabhängigkeit.** Ein Fall darf nicht davon abhängen, dass ein anderer Fall vorher
lief. Die Fallauswahl (`-Case`) führt einzelne Fälle allein aus; wer eine Vorbedingung braucht,
stellt sie selbst her oder endet als NOT-RUN mit Nennung dessen, was fehlt.

**Referenzgerät.** Ein Fall, der an einem zertifizierten Gerät rot ist, beschreibt den Prüfstand,
nicht das Produkt. Neue Fälle laufen zuerst dort (der Kopf von `9-Tcp.Tests.ps1`, Abschnitt
„VERIFIED AGAINST A REFERENCE DEVICE", nennt das Gerät und die drei Fälle, die so abgesichert
wurden), bevor ein Rot am eigenen Gerät als Befund gilt.

---

## Was dieser Maßstab nicht leistet

Er prüft Fälle, nicht Abdeckung. Eine Suite kann jeden Punkt hier erfüllen und trotzdem die
Eigenschaft mit der breitesten Pflicht übersehen. Deshalb gehört in den Kopf jeder Suite, was sie
**nicht** abdeckt und warum — nachprüfbar, nicht als Absicherung. Der Kopf von `9-Tcp.Tests.ps1`
(Abschnitt „NOT YET IMPLEMENTED") nennt die nicht implementierten TSSK-Fälle namentlich, statt sie
fehlen zu lassen.
