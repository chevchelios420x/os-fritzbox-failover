# Audit os-fritzbox-failover 1.0

Stand: Commit `b434733` auf `main`, Release v1.0 (`os-fritzbox-failover-1.0.pkg`).
Zielsystem: OPNsense 26.1.11_10 (FreeBSD 14.3, VM auf Proxmox mit VirtIO), FRITZ!Box 6660 Cable mit FRITZ!OS 8.25.

## Was geprüft wurde

- Der gesamte Code: Shell-Skript, PHP-Hilfsskript, Modell, Controller, GUI, configd-Aktionen, rc.d-Skript, Release-Workflow, PowerShell-Installer.
- Jede OPNsense-Funktion, die das Plugin benutzt, gegen den Quellcode von **opnsense/core Tag 26.1.11**.
- Das veröffentlichte Paket v1.0: entpackt, Dateiliste, Manifest und Installationsskripte gelesen.
- Die Umschaltlogik mit nachgebauten Programmen (FRITZ!Box-Antwort, ping, pluginctl) simuliert.

**Nicht geprüft:** Lauf auf einer echten OPNsense und Abfrage einer echten FRITZ!Box. Alles, was dort passiert, ist aus dem Quellcode abgeleitet, nicht beobachtet.

---

## Kurzfazit

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
- Die Regel „let out anything from firewall host itself (force gw)“ existiert und ist standardmäßig aktiv. Damit gehen die Test-Pings mit Kabel-Absenderadresse immer übers Kabel.
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

Notfall per SSH (Menüpunkt 8, Shell):

```sh
# Dienst stoppen (setzt die normale Monitor-IP zurück)
/usr/local/etc/rc.d/fritzfailover onestop

# Plugin komplett entfernen
pkg delete -y os-fritzbox-failover

# Prüfen, welche Monitor-IP das Kabel-Gateway gerade hat
grep -A30 "<name>WAN_CABLE_GW</name>" /conf/config.xml | grep monitor
```

Steht danach noch `192.0.2.1` drin: in der GUI unter System → Gateways korrigieren. Oder unter System → Konfiguration → Historie eine Version von vor der Umschaltung wiederherstellen.

---

## Empfohlene Reihenfolge

1. **Jetzt möglich:** installieren, Testmodus an lassen, ein paar Tage die Statistik beobachten.
2. **Vor dem echten Modus beheben:** H1, H2, H3, M1, M2, M4.
3. **Für mehr Sicherheit:** M3 (FRITZ!Box-Rechte), M5 (Build pinnen), N1, N2.
4. **Vor dem Abschalten des Testmodus:** Monitor-IP des Kabel-Gateways selbst auf `192.168.0.1` setzen (N5). Backup und Snapshot frisch halten.
