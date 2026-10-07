# Audit os-fritzbox-failover 1.0 (mit Stand der Behebung in 1.1)

Stand: Commit `b434733` auf `main`, Release v1.0 (`os-fritzbox-failover-1.0.pkg`).
Zielsystem: OPNsense 26.1.11_10 (FreeBSD 14.3, VM auf Proxmox mit VirtIO), FRITZ!Box 6660 Cable mit FRITZ!OS 8.25.

## Was geprüft wurde

- Der gesamte Code: Shell-Skript, PHP-Hilfsskript, Modell, Controller, GUI, configd-Aktionen, rc.d-Skript, Release-Workflow, PowerShell-Installer.
- Jede OPNsense-Funktion, die das Plugin benutzt, gegen den Quellcode von **opnsense/core Tag 26.1.11**.
- Das veröffentlichte Paket v1.0: entpackt, Dateiliste, Manifest und Installationsskripte gelesen.
- Die Umschaltlogik mit nachgebauten Programmen (FRITZ!Box-Antwort, ping, pluginctl) simuliert.

**Nicht geprüft:** Lauf auf einer echten OPNsense und Abfrage einer echten FRITZ!Box. Alles, was dort passiert, ist aus dem Quellcode abgeleitet, nicht beobachtet.

---

## Stand der Behebung (Version 1.1)

Die Befunde unten beschreiben Version 1.0. In Version 1.1 wurde Folgendes geändert. Die neue Logik wurde wieder mit nachgebauten Programmen getestet, nicht auf echter Hardware.

| Befund | Status in 1.1 | Was geändert wurde |
|---|---|---|
| H1 „Verbindung testen“ kaputt | **behoben** | Aufruf von `sessionClose()` entfernt. |
| H2 Deinstallation hinterlässt tote Monitor-IP | **behoben** | Neues Paket-Skript `+PRE_DEINSTALL.pre`: stoppt den Dienst; bei echter Deinstallation wird die normale Monitor-IP zurückgesetzt, bei einem Update (`PKG_UPGRADE=true`) bleibt ein Failover erhalten. `+POST_INSTALL.post` startet den Dienst nach Installation oder Update neu, wenn er aktiviert ist. Der Workflow prüft, dass das Skript im Paket ist. |
| H3 Rückschaltung aufs tote Kabel bei „Übernehmen“/Reboot | **behoben** | Der Stopp-Haken setzt die Monitor-IP nur noch zurück, wenn das Plugin deaktiviert oder der Testmodus an ist. Bei einem reinen Neustart bleibt der Failover erhalten. Neuer Button „Normale Monitor-IP wiederherstellen“ für den manuellen Fall. |
| M1 Konfiguration ohne Sperre geschrieben | **behoben** | `Config::getInstance()->lock()` vor dem Laden, wie in den Core-Controllern. |
| M2 Dauer-Fehlanmeldungen an der FRITZ!Box | **behoben** | Nach einer abgelehnten TR-064-Anmeldung pausiert TR-064 für 15 Minuten (UPnP läuft weiter). „Verbindung testen“ versucht es trotzdem sofort; ein Neustart des Dienstes hebt die Pause auf. |
| M3 FRITZ!Box-Benutzer mit Admin-Rechten | **entschärft** | TR-064-Login ist jetzt optional. Ohne Login liest das Plugin den Status per UPnP, ganz ohne Passwort; das ist jetzt die empfohlene Einrichtung. Für TR-064 empfiehlt das README einen eigenen Benutzer ohne Zusatzrechte. Offen: welches Recht TR-064 mindestens braucht. |
| M4 Fehl-Failover nach dem Booten | **behoben** | In den ersten 120 s nach dem Booten wird nur gemessen, nicht umgeschaltet (Status „Starting up“). |
| M5 Lieferkette des Builds | **behoben** | Alle Actions auf feste Commit-IDs gepinnt; `opnsense/plugins` auf Tag `26.1.11` gepinnt und die Commit-ID geprüft. Bleibt: Paket unsigniert, Zwei-Faktor-Anmeldung auf GitHub ist Pflicht. |
| N1 Einträge in der Konfigurations-Historie | **behoben** | Umschaltungen werden ohne Backup-Eintrag gespeichert; im Systemlog stehen sie weiter. |
| N2 IP-Felder akzeptieren „any“ | **behoben** | `WildcardEnabled N` in allen vier Feldern. |
| N3 Veralteter Status | **behoben** | Ist die Konfiguration nicht lesbar, wird der Status „unknown“ mit Hinweis geschrieben. |
| N4 Viel Log bei Ausfall | **behoben** | Während eines (auch simulierten) Failovers werden verlorene Pings nicht mehr einzeln geloggt; die Statistik zählt weiter. |
| N5 Vorhandene Monitor-IP wird überschrieben | **entschärft** | „Verbindung testen“ weist darauf hin, wenn das Gateway gerade eine andere Monitor-IP hat. Gewolltes Verhalten bleibt. |
| N6 Zähler aus dem Testmodus | **behoben** | Zähler werden bei jedem Start des Dienstes zurückgesetzt (ein Moduswechsel braucht „Übernehmen“, also einen Neustart). |
| N7 Stoppen dauert bis 60 s | **verbessert** | Die Prüfung läuft im Hintergrund, der Dienst beendet sich sofort. Eine laufende Prüfung (max. ca. 17 s) wird noch zu Ende geführt. |
| N8 TR-064 über HTTP | **bewusst nicht geändert** | Digest schützt das Passwort; übertragen wird nur der Verbindungsstatus, auf der Direktstrecke zur FRITZ!Box. HTTPS mit dem selbstsignierten Zertifikat der Box brächte kaum Gewinn. Mit UPnP ohne Login entfällt das Passwort ganz. |

**Neue Einschätzung für 1.1:** Betrieb im echten Modus ist vertretbar, nachdem du ein paar Tage im Testmodus beobachtet hast. Vorher zur Sicherheit „Verbindung testen“ benutzen und prüfen, dass Status und Pings stimmen.

---

## Kurzfazit (Version 1.0)

| Frage | Einschätzung |
|---|---|
| Kann das Plugin die OPNsense zum Absturz bringen? | **Sehr unwahrscheinlich.** Es lädt keine Kernel-Module, ändert keine Firewall-Regeln, keine Schnittstellen und keine Routing-Tabelle. Es ist ein Shell-Skript mit PHP-Hilfe; ein Fehler darin trifft nur das Plugin selbst. |
| Bleibt die OPNsense aus dem LAN erreichbar? | **Ja.** Das Plugin fasst LAN, LAN-Regeln, Web-GUI und SSH nicht an. Auch im schlimmsten Fall kommst du per Browser oder SSH aus dem LAN an die OPNsense, ohne Proxmox. |
| Installation | **Geringes Risiko.** Das Paket hat keine Abhängigkeiten und liefert nur eigene Dateien. Bei der Installation startet OPNsense configd und syslog kurz neu, wie bei jedem Plugin. |
| Betrieb im Testmodus (Standard) | **Geringes Risiko.** Es wird nichts an der OPNsense geändert. Einziger Eingriff: eine echte Umschaltung von früher wird beim Stoppen rückgängig gemacht. |
| Betrieb im echten Modus | **Mittleres Risiko, bis die Punkte H1 bis M5 behoben sind.** Keiner davon bringt die OPNsense zum Absturz. Sie können aber das Internet kurz über die falsche Leitung schicken oder eine gleichzeitige GUI-Änderung verlieren. |

**Empfehlung:** Installieren und im Testmodus laufen lassen ist jetzt vertretbar. Den Testmodus erst abschalten, wenn H1 bis M5 behoben sind.

---

## Befunde

Schweregrade: **HOCH** = Fehlfunktion oder hängender Zustand wahrscheinlich, **MITTEL** = kann in bestimmten Situationen stören, **NIEDRIG** = Schönheitsfehler oder Randfall.

### H1 – HOCH: „Verbindung testen“ bricht mit PHP-Fehler ab

- **Fundstelle:** `src/opnsense/mvc/app/controllers/OPNsense/FritzFailover/Api/ServiceController.php:81`, Aufruf `$this->sessionClose()`.
- **Problem:** Diese Methode gibt es in OPNsense 26.1.11 nicht (im Core-Quellcode nicht vorhanden). Der Aufruf endet in einem PHP-Fehler, der Button liefert keine Antwort.
- **Auswirkung:** Nur der Test-Button ist kaputt. Der Dienst selbst ist nicht betroffen.
- **Behebung:** Zeile entfernen.

### H2 – HOCH: Deinstallation während eines Failovers hinterlässt die tote Monitor-IP

- **Fundstelle:** Paket-Skripte. Das Paket hat nur `post-install` und `post-deinstall` (OPNsense-Standard), kein `pre-deinstall`.
- **Problem:** `pkg delete` stoppt den Dienst nicht und setzt die Monitor-IP nicht zurück.
  - Steht das Kabel-Gateway gerade auf `192.0.2.1`, bleibt das so. OPNsense hält das Kabel dann dauerhaft für tot und bleibt auf 5G.
  - Der laufende Prozess läuft verwaist weiter, schreibt alle 10 s „unable to read configuration“ ins Log und verschwindet erst beim Neustart.
- **Behebung:** Ein `+PRE_DEINSTALL.pre` im Plugin-Verzeichnis, das den Dienst stoppt und die normale Monitor-IP zurücksetzt. Das Build-System von OPNsense unterstützt solche Dateien.
- **Bis dahin:** Vor dem Deinstallieren das Plugin in der GUI deaktivieren und übernehmen. Das stoppt den Dienst und setzt die Monitor-IP zurück.

### H3 – HOCH: „Übernehmen“, Neustart oder Reboot während eines Failovers schaltet kurz auf die tote Leitung zurück

- **Fundstelle:** `src/etc/rc.d/fritzfailover:22-27` (`stop_postcmd` ruft `restore` auf).
- **Problem:** In OPNsense 26.1.11 gibt `reconfigureForceRestart()` immer `1` zurück. Jedes „Übernehmen“ in der GUI ist daher Stopp und Start. Beim Stopp setzt das Plugin die normale Monitor-IP zurück. Dasselbe passiert beim Herunterfahren, weil der Dienst dabei gestoppt wird.
- **Auswirkung:** Klickst du während eines echten Kabel-Ausfalls auf „Übernehmen“, schaltet OPNsense zurück aufs tote Kabel. Erst nach 3 Fehlprüfungen plus dpinger-Reaktionszeit (grob 30 bis 90 s) geht es wieder auf 5G. In dieser Zeit hat das LAN kein Internet.
- **Behebung:** Nur zurücksetzen, wenn das Plugin danach nichts mehr verwaltet (deaktiviert, Testmodus, Deinstallation). Bei einem Neustart des Dienstes den Failover-Zustand behalten. Der neu gestartete Dienst erkennt ihn an der Monitor-IP und schaltet zurück, sobald die Leitung wirklich gesund ist.

### M1 – MITTEL: Konfiguration wird ohne Sperre geschrieben (mögliche verlorene GUI-Änderung)

- **Fundstelle:** `src/opnsense/scripts/OPNsense/FritzFailover/fritzfailover_helper.php:150-157`.
- **Problem:** Das Hilfsskript liest die Konfiguration, ändert die Monitor-IP und speichert. Die OPNsense-Controller rufen vorher `Config::getInstance()->lock()` auf (sperren und neu laden), das Plugin nicht.
- **Auswirkung:** Speicherst du genau in derselben Sekunde etwas in der GUI, kann eine der beiden Änderungen verloren gehen. Selten, aber möglich.
- **Behebung:** Vor dem Laden des Gateway-Modells `Config::getInstance()->lock()` aufrufen; `save()` gibt die Sperre wieder frei. So macht es der Core.

### M2 – MITTEL: Falsches FRITZ!Box-Passwort führt zu Dauer-Fehlanmeldungen

- **Fundstelle:** `fritzbox_failover.sh:204-236`.
- **Problem:** Bei falschem TR-064-Passwort versucht das Plugin alle 10 s erneut, sich anzumelden.
- **Auswirkung:** FRITZ!OS reagiert auf wiederholte Fehlanmeldungen mit wachsenden Sperrzeiten und kann darüber benachrichtigen. Die Sperre kann auch deine eigene Anmeldung an der Box behindern. Am Failover ändert das nichts: Der Ping entscheidet weiter, im Modus „nur FRITZ!Box“ wird nicht umgeschaltet.
- **Behebung:** Nach einer Antwort 401 TR-064 für einige Minuten pausieren und das in der GUI deutlich anzeigen.

### M3 – MITTEL: FRITZ!Box-Benutzer hat zu viele Rechte

- **Fundstelle:** `README.md:71` empfiehlt das Recht „FRITZ!Box Einstellungen“.
- **Problem:** Das ist praktisch Admin-Zugriff auf die Box. Das Passwort steht im Klartext in der `config.xml` der OPNsense (wie alle Passwörter dort). Jeder OPNsense-Admin mit Zugriff auf die Plugin-Seite kann es über die API lesen, und es landet in jedem Konfigurations-Backup.
- **Behebung:**
  - Prüfen, ob `GetStatusInfo` mit einem Benutzer ohne Sonderrechte funktioniert.
  - Oder nur die unauthentifizierte UPnP-Statusabfrage nutzen (FRITZ!Box: „Statusinformationen über UPnP übertragen“). Die ist im Plugin schon als Ausweichweg eingebaut und braucht gar kein Passwort.
  - Mindestens: einen eigenen Benutzer nur für die OPNsense anlegen, nicht das eigene Konto.

### M4 – MITTEL: Möglicher Fehl-Failover direkt nach dem Booten

- **Fundstelle:** `fritzbox_failover.sh:320-324`.
- **Problem:** Hat die Kabel-Schnittstelle beim Start noch keine IPv4-Adresse (DHCP von der FRITZ!Box noch nicht fertig), zählt das als Fehlschlag. Dauert das länger als 3 Prüfungen (etwa 30 s), schaltet das Plugin auf 5G um.
- **Auswirkung:** Der Zustand heilt sich selbst: Nach 3 erfolgreichen Prüfungen geht es zurück. Es entstehen aber eine unnötige Umschaltung und ein Konfigurations-Eintrag.
- **Behebung:** Eine Anlaufzeit nach dem Start (z. B. 2 Minuten), in der nur gemessen und nicht umgeschaltet wird.

### M5 – MITTEL: Lieferkette des Release-Builds

- **Fundstelle:** `.github/workflows/release.yml:28, 60, 96, 103` und `:73`.
- **Problem:**
  - Die GitHub Actions sind nur per Versions-Tag eingebunden (`@v1`, `@v2`, `@v4`), nicht per fester Commit-ID. Würde eine davon kompromittiert, könnte sie Code ins Paket schmuggeln, der auf der Firewall als root läuft.
  - Das OPNsense-Build-System wird ungepinnt vom Hauptzweig geholt; eine Änderung dort kann den Build verändern (siehe das `-devel`-Problem beim ersten Build).
- **Behebung:** Actions auf Commit-IDs pinnen, `opnsense/plugins` auf einen festen Tag.
- Zusätzlich: Das Paket ist nicht signiert. Wer dein GitHub-Konto übernimmt, kann ein manipuliertes Release veröffentlichen. Zwei-Faktor-Anmeldung auf GitHub ist Pflicht.

### N1 – NIEDRIG: Jede Umschaltung erzeugt einen Eintrag in der Konfigurations-Historie

- **Fundstelle:** `fritzfailover_helper.php:157` (`save()` mit Backup).
- **Problem:** Jede Umschaltung speichert die Konfiguration samt Backup-Eintrag und löst ein Konfigurations-Ereignis aus. Bei einer stark flappenden Leitung (z. B. 20 Umschaltungen am Tag) werden ältere, echte Backups aus der Historie verdrängt (System → Konfiguration → Historie hat eine feste Anzahl).
- **Behebung:** Eine Mindestdauer zwischen Umschaltungen, oder bei vielen Umschaltungen ohne Backup speichern. Deine heruntergeladenen Backups sind davon nicht betroffen.

### N2 – NIEDRIG: IP-Felder akzeptieren „any“

- **Fundstelle:** `FritzFailover.xml:14, 52, 59, 66`.
- **Problem:** `NetworkField` erlaubt in OPNsense standardmäßig Platzhalter wie `any`. Das Plugin fängt das zur Laufzeit ab (Umschaltung wird verweigert, Testadressen werden gefiltert), aber erst dann statt schon beim Speichern.
- **Behebung:** `<WildcardEnabled>N</WildcardEnabled>` in den vier Feldern.

### N3 – NIEDRIG: Status in der GUI kann veraltet sein

- **Fundstelle:** `fritzbox_failover.sh:401-403`.
- **Problem:** Kann das Skript die Konfiguration nicht lesen (z. B. während eines Firmware-Updates), schreibt es keinen neuen Status. Die GUI zeigt dann den letzten Stand mit alter Uhrzeit.
- **Auswirkung:** Keine; das Verhalten ist sicher (nichts wird geändert). Es kann nur verwirren.

### N4 – NIEDRIG: Viel Log bei langem Ausfall

- **Problem:** Während eines Ausfalls stehen pro Prüfung 3 Zeilen „probe loss“ im Log, bei 10 s Intervall über 25.000 Zeilen pro Tag.
- **Behebung:** Im Failover-Zustand nur Zustandswechsel loggen.

### N5 – NIEDRIG: Vorhandene Monitor-IP wird beim ersten Zyklus überschrieben

- **Problem:** Steht beim Kabel-Gateway z. B. noch `9.9.9.9` als Monitor-IP, lässt das Plugin sie zunächst stehen. Nach dem ersten Failover und der Rückschaltung steht dort aber die FRITZ!Box-IP (`192.168.0.1`). Ist das Feld leer, steht danach `192.168.0.1` explizit drin.
- **Das ist so gewollt**, sollte aber vor dem Abschalten des Testmodus bewusst selbst eingetragen werden.

### N6 – NIEDRIG: Zähler aus dem Testmodus werden übernommen

- **Problem:** Beim Wechsel vom Test- in den echten Modus zählen bereits gezählte Fehlschläge weiter.
- **Auswirkung:** Höchstens eine Umschaltung eine Prüfung früher.

### N7 – INFO: Stoppen kann bis zu etwa 60 s dauern

- **Problem:** Läuft beim Stoppen gerade eine Prüfung (bis ca. 17 s), wartet der Stopp darauf. Die Rücksetzung wartet bis zu 60 s auf die Sperre. Herunterfahren und „Übernehmen“ können sich dadurch etwas verzögern.

### N8 – INFO: TR-064 läuft über HTTP statt HTTPS

- **Problem:** Die Abfrage geht an Port 49000 per HTTP. Das Passwort wird per Digest-Verfahren nicht im Klartext übertragen, der Inhalt aber unverschlüsselt. Die Strecke ist das direkte Kabel zwischen OPNsense und FRITZ!Box.
- **Möglich:** HTTPS über Port 49443.

---

## Geprüft und in Ordnung

**OPNsense 26.1.11 – alle benutzten Funktionen vorhanden:**
- `Gateways::createOrUpdateGateway()` ändert nur die übergebenen Felder (hier nur `monitor`).
- `pluginctl -c monitor <Gateway>` startet nur den dpinger dieses einen Gateways neu (Argumentweitergabe in `pluginctl` und `dpinger_configure_do()` nachgelesen).
- ~~Die Regel „let out anything from firewall host itself (force gw)“ … Damit gehen die Test-Pings mit Kabel-Absenderadresse immer übers Kabel.~~ **Falsch, im Praxistest widerlegt (siehe „Test-Pings während des Failovers“).**
- Die GUI-Bausteine (`SimpleActionButton`, `updateServiceControlUI`, `mapDataToFormUI`, `saveFormToEndpoint`, Tokenizer, Passwortfeld) gibt es alle.
- Die Validierungs-Klasse `Message` und das Validierungsmuster sind identisch zu Core-Modellen (z. B. Unbound).
- Dienste in `/usr/local/etc/rc.d` mit `_enable=YES` startet OPNsense beim Booten über `rc.freebsd`.
- `opnsense-shell` reicht per SSH übergebene Befehle an eine Shell weiter. Der PowerShell-Installer funktioniert also mit dem root-Login.

**Paket v1.0:**
- Name `os-fritzbox-failover`, Version 1.0, ABI `FreeBSD:14:amd64`. Das passt zu OPNsense 26.1 (FreeBSD 14.3, amd64).
- Keine Abhängigkeiten; nichts wird nachinstalliert.
- 17 Dateien, alle unter `/usr/local`; ausführbar nur die beiden Skripte und das rc.d-Skript.
- Installationsskript: configd neu starten, Modell-Migrationen ausführen, Plugin-Konfiguration neu laden (Caches leeren, syslog neu starten), Template laden. Das ist das Standardverhalten jedes OPNsense-Plugins.

**Sicherheit:**
- Keine Befehlsinjektion: Alle Werte aus der GUI werden vom Modell geprüft und vor der Übergabe an die Shell sicher gequotet. Der Gateway-Name ist auf Buchstaben, Ziffern und `_` beschränkt.
- Das FRITZ!Box-Passwort steht nie in der Prozessliste, in Logs oder in Dateien unter `/var/run`; es geht nur über eine Pipe an curl.
- Die configd-Aktionen nehmen keine Parameter entgegen.
- API-Zugriff nur mit OPNsense-Anmeldung und eigener Berechtigung („Services: FRITZ!Box Failover“); ändernde Aufrufe nur per POST.
- Arbeitsdateien unter `/var/run` nur für root lesbar; die Statusdatei (ohne Geheimnisse) ist lesbar.

**Umschaltlogik (Simulation):**
- Ein einzelnes Ziel ausgefallen: keine Reaktion.
- Alle Ziele 3-mal hintereinander tot: Failover. 3-mal gesund: Rückschaltung. Unterbrechung setzt den Zähler zurück.
- Box meldet „Disconnected“: Failover. Falscher Login im Modus „nur FRITZ!Box“: keine Entscheidung, keine Umschaltung.
- Testmodus: keinerlei Aufrufe von `setmonitor` oder `pluginctl`.
- Ein Gateway, das nicht in der Konfiguration gespeichert ist, wird nicht angefasst.

**Offen, nur auf der echten Hardware zu klären:**
- Was die FRITZ!Box 6660 mit FRITZ!OS 8.25 bei DS-Lite in `NewConnectionStatus` meldet.
- Welches FRITZ!Box-Recht `GetStatusInfo` mindestens braucht (siehe M3).
- Ob der Ping mit Kabel-Absenderadresse auf deiner VM wirklich übers Kabel geht. Prüfbar mit „Verbindung testen“ (nach Behebung von H1) während eines Failovers.

---

## Was im schlimmsten Fall passiert und wie du es ohne Proxmox behebst

Das Plugin ändert nur die Monitor-IP des Kabel-Gateways. Die realistisch schlimmsten Fälle:

| Fall | Folge | Lösung aus dem LAN |
|---|---|---|
| Hängt im Failover | Internet läuft über 5G, Kabel ungenutzt | GUI: Plugin deaktivieren und übernehmen. Oder System → Gateways → Kabel-Gateway → Monitor-IP `192.168.0.1` → speichern, übernehmen. |
| Schaltet aufs tote Kabel zurück (H3) | Kurz kein Internet | Abwarten (heilt sich nach 3 Prüfungen) oder Plugin deaktivieren. |
| Gleichzeitige GUI-Änderung verloren (M1) | Eine Einstellung fehlt | Erneut speichern, oder unter System → Konfiguration → Historie vergleichen. |
| Plugin-Fehler, GUI-Seite lädt nicht | Nur das Plugin betroffen | Per SSH: `configctl fritzfailover stop` oder `pkg delete os-fritzbox-failover`. |

Notfall per SSH (Menüpunkt 8, Shell), ab Version 1.1:

```sh
# normale Monitor-IP sofort zurücksetzen (wirkt immer, auch im Failover)
/usr/local/opnsense/scripts/OPNsense/FritzFailover/fritzbox_failover.sh restore

# Plugin komplett entfernen (stoppt den Dienst und setzt die Monitor-IP zurück)
pkg delete -y os-fritzbox-failover

# Prüfen, welche Monitor-IP das Kabel-Gateway gerade hat
grep -A30 "<name>WAN_CABLE_GW</name>" /conf/config.xml | grep monitor
```

Steht danach noch `192.0.2.1` drin: in der GUI unter System → Gateways korrigieren.

---

## Empfohlene Reihenfolge

1. **Jetzt möglich:** installieren, Testmodus an lassen, ein paar Tage die Statistik beobachten.
2. **Vor dem echten Modus beheben:** H1, H2, H3, M1, M2, M4.
3. **Für mehr Sicherheit:** M3 (FRITZ!Box-Rechte), M5 (Build pinnen), N1, N2.
4. **Vor dem Abschalten des Testmodus:** Monitor-IP des Kabel-Gateways selbst auf `192.168.0.1` setzen (N5). Backup und Snapshot frisch halten.

---

## Langzeitbetrieb (Stand 1.13)

Frage: Kann das Plugin bei monatelangem Betrieb auf dem Hauptrouter etwas volllaufen lassen oder hängen bleiben? Geprüft wurden alle Stellen im Code, an denen geschrieben wird oder Prozesse gestartet werden.

### Speicher und Dateien

| Was | Wo | Begrenzung |
|---|---|---|
| Status, Zähler, Sperre, Test-Failover, Cloudflare-Auftrag | `/var/run/fritzfailover.*` | je eine Zeile bzw. wenige hundert Byte, wird überschrieben |
| Statistik je Testadresse | `/var/run/fritzfailover.stats` | eine Zeile je Adresse (max. 5); Zähler sind 64-bit-Ganzzahlen |
| Umschalt-Verlauf | `/var/db/fritzfailover/history` | max. 50 Einträge (`tail`) |
| Push-Warteschlange | `/var/run/fritzfailover.push_queue` | nur bis zum Versand, Einträge älter als 1 Tag werden verworfen |
| Konfiguration | `/conf/config.xml` | nur bei echten Umschaltungen, ohne Backup-Einträge in der Historie |
| Temp-Ordner je Prüfung | `/var/run/fritzfailover.XXXXXX` | werden sofort gelöscht; Reste hart abgebrochener Prüfungen räumt ab 1.13 jede Prüfung nach 10 Minuten weg |
| Systemlog | OPNsense-Log | im Normalbetrieb keine Einträge; nur Umschaltungen, Fehler und verlorene Pings (nicht während eines Failovers); OPNsense rotiert die Logs selbst |

Ergebnis: Nichts wächst unbegrenzt.

### Prozesse

- Ein dauerhafter Überwachungsprozess, von `daemon(8)` überwacht und bei einem Absturz nach 10 Sekunden neu gestartet.
- Jede Prüfung startet nur kurzlebige Prozesse (PHP-Hilfsskript, `ping`, `curl`), alle mit Zeitlimit: `curl` max. 6–10 s, `ping` max. `Anzahl × Timeout + 1` s.
- Alle Aktionen laufen nacheinander über eine Sperre (`lockf`, max. 60 s Wartezeit). Seit 1.3 können gestartete Langläufer (dpinger) die Sperre nicht mehr erben (vorher Ursache für stehenbleibende Prüfungen).
- Der Test-Failover startet einen einzelnen Timer-Prozess, der nach 2 Minuten endet. Fällt er aus, beendet die nächste Prüfung den Test.

### Last

Pro Prüfung (Standard alle 10 s) 2–3 kurze PHP-Aufrufe, eine UPnP-/TR-064-Anfrage an die FRITZ!Box und 2 Pings je Testadresse. Für eine OPNsense-VM vernachlässigbar.

### Frühe Anzeichen für Probleme

- **Ab 1.13:** Rote Warnung auf der Statusseite, wenn die letzte Prüfung länger als 3 Prüfintervalle + 60 Sekunden her ist. Voraussetzung: Die Uhr des Browsers geht ungefähr richtig, sonst ist eine Fehlwarnung möglich.
- Status „unknown“ oder Fehlermeldungen mit `fritzfailover` unter System → Protokolldateien → Allgemein.
- In der Statistik steigt „Checks“ nicht mehr.
- Abhilfe: Dienst neu starten; ein aktiver Failover bleibt dabei erhalten.

### Selbstheilung (ab 1.14)

- Optionaler Neustart des eigenen Überwachungsprozesses, Standard: an, täglich in der Stunde 04:00–04:59.
- Ablauf: Der Prozess beendet sich selbst mit Exit-Code 0, `daemon(8)` startet ihn nach 10 Sekunden neu. Laut FreeBSD-Quellcode (`daemon.c`) startet `daemon` bei jedem Ende neu; nur ein SIGTERM an `daemon` selbst beendet die Überwachung. Der rc.d-Stopp-Haken läuft dabei nicht, die Monitor-IP wird also nie angefasst.
- Geleert werden Zähler, Login-Pause, Statusdatei und Temp-Reste. Statistik und Verlauf bleiben.
- Nur bei Status „ok“, ohne laufenden Test-Failover und ohne ausstehende Push-/DNS-Aufträge; höchstens einmal pro Zeitfenster (Sperre 20 Stunden).
- Mit nachgebauten Programmen getestet: Neustart bei „ok“ in der eingestellten Stunde, kein zweiter Neustart im selben Fenster, kein Neustart während eines Failovers.

### Debug-Modus (ab 1.16)

- Start per Button, Ende nach spätestens 12 Stunden (Zeitstempel in `/var/db/fritzfailover/debug_until`, geprüft bei jeder Prüfung). Keine Änderung an der Konfiguration.
- Eine Zeile pro Prüfung (ca. 600–800 Byte), also ca. 3–4 MB in 12 Stunden bei 10 s Intervall; harte Grenze 20 MB (danach wird die ältere Hälfte verworfen).
- Zusätzliche Last nur während der Aufzeichnung: zwei UPnP-Abfragen, ein Aufruf von `gateway_status.php` und `route get` je Prüfung.
- Datei nur für root lesbar (0600); öffentliche IP wird nicht protokolliert.
- Die Selbstheilung löscht das Log täglich, aber nicht während einer laufenden Aufzeichnung; beim Deinstallieren wird es mit `/var/db/fritzfailover` entfernt.

### Test-Pings während des Failovers (behoben in 1.18)

- **Befund aus dem Praxistest:** Während eines Failovers gingen die Test-Pings trotz Kabel-Absenderadresse über die Backup-Leitung hinaus und meldeten das Kabel fälschlich als wieder erreichbar. Die Annahme, die OPNsense-Regel „force gw“ würde solche Pakete aufs Kabel zwingen, war falsch. Folge: mögliche Rückschaltung auf eine tote Leitung (Flattern).
- **Behebung:** Das Plugin legt zwei eigene Routing-Tabellen an (FreeBSD-FIBs, `net.fibs` wird zur Laufzeit erhöht – laut FreeBSD-14.3-Quellcode `sysctl_fibs` erlaubt, nur Vergrößerung). Tabelle „Kabel“ enthält nur eine Host-Route zum Kabel-Gateway über die Kabel-Schnittstelle und eine Standardroute darüber; Tabelle „Backup“ entsprechend. Test-Pings laufen per `setfib` in der Kabel-Tabelle, die IP-Abfrage für Push-Nachrichten in der passenden Tabelle. Der übrige Verkehr der Firewall nutzt weiter Tabelle 0. OPNsense selbst verwendet keine zusätzlichen FIBs (im Core-Quellcode geprüft).
- Lässt sich die Kabel-Tabelle nicht einrichten (z. B. Gateway-Adresse unbekannt), gilt das Ping-Ergebnis als unbrauchbar und es wird nicht anhand der Pings entschieden.
- Mit nachgebauten Programmen getestet (Ping ohne eigene Tabelle „leckt“ über das Backup): Das Plugin bleibt im Failover, bis das Kabel selbst antwortet. Auf echter Hardware noch zu bestätigen.

### Test-Pings und Policy-Routing (1.19)

- **Befund aus dem Praxistest mit 1.18:** Nach Erholung der Kabelleitung blieben die Test-Pings erfolglos, bis die Monitor-IP von Hand zurückgesetzt wurde. Die eigene Routing-Tabelle wirkt nur auf die Routenwahl; eine pf-Regel mit `route-to` (Gateway-Gruppe/Policy-Routing) wird danach ausgewertet und kann die Pakete trotzdem auf das Backup umleiten, solange das Kabel-Gateway als „down“ gilt. Folge: Das Plugin konnte die Erholung nicht erkennen.
- **Behebung:** Das Plugin registriert über den OPNsense-Firewall-Hook (`fritzfailover_firewall`, Priorität 1, also vor allen Benutzerregeln) pro Testadresse eine `quick`-Regel `pass out route-to (<Kabel-Schnittstelle> <Kabel-Gateway>) proto icmp from (<Kabel-Schnittstelle>) to <Testadresse>`. Laut Core-Quellcode (`Plugin::setGateways` nutzt auch ausgefallene Gateways) entsteht die Regel auch dann, wenn das Kabel-Gateway „down“ ist. Abschaltbar in den Einstellungen (Standard an).
- **Kontrolle:** Bei jeder Prüfung wird `pfctl -sr` auf die Regeln je Testadresse geprüft; Ergebnis in Status, Test-Dialog und Debug-Log. Fehlende Regeln lösen `configctl filter reload skip_alias` aus, höchstens alle 15 Minuten. „Apply“ lädt die Firewall ebenfalls neu.
- **Verbose-Debug:** schreibt `route-to`/`reply-to`-Regeln und Routen der FIBs bei Änderung sowie die pf-States der Test-Pings je Prüfung.
- Noch auf echter Hardware zu bestätigen (Test-Failover, danach Kabel wieder hochkommen lassen).

### Restrisiken

- Was sich nur im Dauerbetrieb zeigt (z. B. Verhalten der FRITZ!Box bei Abfragen alle 10 s über Monate oder Speicherverhalten von PHP/OPNsense selbst), lässt sich nicht im Voraus testen. Die Warnung bei ausbleibenden Prüfungen macht ein Hängen sichtbar.
- Firmware-Updates von OPNsense können interne Schnittstellen ändern, die das Plugin nutzt (Gateway-Modell, `pluginctl`, `gateway_status.php`). Nach größeren OPNsense-Updates einmal „Verbindung testen“ und einen Test-Failover ausführen.
