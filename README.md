# os-fritzbox-failover

OPNsense-Plugin für einen zuverlässigen, automatischen WAN-Failover zwischen zwei Leitungen:

- **Hauptleitung** hinter einer **Haupt-FRITZ!Box** (z. B. FRITZ!Box 6660 Cable an Vodafone-Kabel, eine 7590 an DSL oder Glasfaser),
- **Failover-Leitung** über ein zweites Gateway (z. B. eine FRITZ!Box 6850 5G oder ein anderer LTE/5G-Router).

Das Plugin erkennt, ob über die Hauptleitung wirklich Internet kommt, und lässt OPNsense dann mit seinen eigenen Gateway-Gruppen umschalten. Es wird als fertiges `.pkg` installiert; auf der Firewall sind **kein git, keine opnsense-devtools und kein Compiler** nötig.

---

## Das Problem

- OPNsense überwacht ein Gateway mit `dpinger`, der dauerhaft eine Monitor-IP anpingt.
- Steht dort eine Internet-Adresse wie `9.9.9.9`, meldet dpinger auf manchen Installationen (z. B. virtualisiert mit VirtIO/`vtnet` hinter einer FRITZ!Box) irgendwann **100 % Verlust, obwohl die Leitung läuft**. OPNsense schaltet dann unnötig auf die Failover-Leitung.
- Steht als Monitor-IP die **Haupt-FRITZ!Box selbst** (z. B. `192.168.0.1`), gibt es keine Fehlalarme mehr. Dann erkennt OPNsense aber keine echten Ausfälle: Die FRITZ!Box bleibt erreichbar und meldet oft weiter „verbunden“, obwohl beim Anbieter kein Verkehr mehr durchgeht. Genau solche Ausfälle sind in der Praxis häufig.
- Das Gateway zu deaktivieren ist keine Lösung: Damit brechen Gateway-Gruppen und **Policy-Based-Routing-Regeln**.

## Die Lösung

Das Haupt-Gateway wird im Normalbetrieb **gegen die Haupt-FRITZ!Box** überwacht (stabil, kein Fehlalarm). Ob dahinter wirklich Internet ankommt, entscheidet das Plugin. Dafür prüft es alle paar Sekunden:

1. **Den Status der Haupt-FRITZ!Box** per UPnP ohne Passwort (oder TR-064 mit eigenem Benutzer):
   - Verbindungsstatus (`WANIPConnection:1` → `GetStatusInfo` → `NewConnectionStatus`),
   - physischer Leitungsstatus (`WANCommonInterfaceConfig:1` → `NewPhysicalLinkStatus`); „Down“ gilt sofort als Ausfall.
2. **Einen Internet-Test über die Hauptleitung**: Pings an mehrere Adressen (Standard `9.9.9.9`, `1.1.1.1`, `8.8.8.8`). Die Leitung gilt erst als tot, wenn **keine** Adresse antwortet. Die Pings laufen auch während eines Failovers nachweislich über die Hauptleitung (siehe unten).

Welche Prüfungen benutzt werden, stellst du ein: beide (empfohlen), nur die FRITZ!Box oder nur die Pings.

Ist die Hauptleitung mehrmals hintereinander tot (Standard 3), setzt das Plugin die **Monitor-IP des Haupt-Gateways auf eine Adresse, die nie antwortet** (`192.0.2.1`) und startet nur den dpinger dieses Gateways neu. dpinger meldet 100 % Verlust, und OPNsense schaltet mit seinen **eigenen Gateway-Gruppen** auf die Failover-Leitung. Ist die Hauptleitung wieder mehrmals hintereinander gesund, setzt das Plugin die normale Monitor-IP zurück, und OPNsense schaltet selbst zurück.

## Was das Plugin an der OPNsense ändert

Die Umschaltung selbst macht immer OPNsense, wie bei jedem Gateway-Ausfall. Das Plugin legt **keine Gateways an, deaktiviert keine und löscht keine**. Damit die Erkennung auch im Failover stimmt, greift es aber an einigen Stellen ein:

| Was | Wann | Warum |
|---|---|---|
| Monitor-IP des Haupt-Gateways (in `config.xml`, ohne Eintrag in der Konfigurations-Historie) und Neustart von dessen dpinger | bei jeder Umschaltung | löst den Failover bzw. die Rückschaltung aus |
| Zwei eigene Routing-Tabellen (FreeBSD-FIBs, `net.fibs` wird erhöht) mit je einer Standardroute über das Haupt- bzw. Failover-Gateway | beim Start | Test-Pings und IP-Abfragen laufen gezielt über eine Leitung, egal wohin die Firewall gerade routet. Der übrige Verkehr nutzt weiter die normale Tabelle. |
| Automatische Firewall-Regeln: pro Testadresse eine ICMP-Regel über das Haupt-Gateway (abschaltbar) | beim Laden der Firewall-Regeln | verhindert, dass eine Regel mit Gateway-Gruppe die Test-Pings im Failover auf die Failover-Leitung umleitet |
| Neu Laden der Firewall-Regeln | bei „Apply“, bei Installation/Deinstallation und automatisch, wenn die Regeln oben fehlen (höchstens alle 15 Minuten) | damit die Regeln zu den Einstellungen passen |
| Cloudflare-DNS-Eintrag, Pushover-Nachricht | nur wenn eingerichtet, bei echten Umschaltungen | optional, siehe unten |

Nicht angefasst werden LAN-Einstellungen, deine eigenen Firewall-Regeln, Web-GUI und SSH. Die OPNsense bleibt aus dem LAN immer erreichbar.

### Testmodus (Dry Run)

Nach der Installation ist der **Testmodus eingeschaltet**. Alle Prüfungen laufen, aber Monitor-IP, DNS und Benachrichtigungen bleiben unverändert. Die Statusseite zeigt:
- was das Plugin tun *würde* („würde jetzt auf Backup umschalten“),
- eine **Statistik pro Testadresse**: Prüfungen, verlorene Pings, Prüfungen ganz ohne Antwort, Zeitpunkt des letzten Verlusts.

So siehst du nach ein paar Tagen, ob das Plugin in dieser Zeit richtig entschieden hätte. Jeder verlorene Ping steht zusätzlich im Systemlog (Tag `fritzfailover`). Erst wenn alles sauber aussieht, schaltest du den Testmodus aus.

---

## Installation mit Windows (am einfachsten)

1. [`tools/Install-FritzFailover.ps1`](tools/Install-FritzFailover.ps1) herunterladen (auf der Seite rechts oben „Download raw file“).
2. Rechtsklick auf die Datei → **„Mit PowerShell ausführen“**.
   Falls Windows das blockiert: PowerShell öffnen und
   `powershell -ExecutionPolicy Bypass -File .\Install-FritzFailover.ps1` eingeben.
3. IP der OPNsense und Benutzer (`root`) eingeben; das Passwort fragt ssh ab (bei Prüfung und Installation je einmal).
   Benötigt nur den in Windows 10/11 eingebauten OpenSSH-Client.

Das Skript prüft per SSH, ob die OPNsense passt (Version, FreeBSD 14, nötige Programme, Speicherplatz, Download von GitHub, FRITZ!Box erreichbar), zeigt die gefundenen Gateways an und installiert das Plugin nach Rückfrage. Mit `-CheckOnly` wird nur geprüft.

Voraussetzung: SSH ist in der OPNsense aktiviert (**System → Einstellungen → Verwaltung → Secure Shell**, inkl. Root-Login mit Passwort).

## Installation per SSH (eine Zeile)

Per SSH auf der OPNsense anmelden (Menüpunkt `8) Shell`) und einfügen:

```sh
curl -fL --retry 3 --connect-timeout 15 --progress-bar -o /tmp/os-fritzbox-failover.pkg https://github.com/chevchelios420x/os-fritzbox-failover/releases/latest/download/os-fritzbox-failover.pkg && env IGNORE_OSVERSION=yes pkg add -f /tmp/os-fritzbox-failover.pkg && rm -f /tmp/os-fritzbox-failover.pkg
```

Danach die Weboberfläche neu laden. Das Plugin erscheint unter **Dienste → FRITZ!Box Failover** und in **System → Firmware → Plugins** als installiert.

Updates: denselben Befehl erneut ausführen. Ein laufender Failover bleibt dabei erhalten, der Dienst wird danach automatisch neu gestartet.
Deinstallieren: `pkg delete os-fritzbox-failover`. Dabei wird der Dienst gestoppt, die normale Monitor-IP zurückgesetzt, die Routing-Tabellen des Plugins geleert und die Firewall-Regeln neu geladen (ohne die Plugin-Regeln).

---

## Einrichtung

### 1. Haupt-FRITZ!Box vorbereiten

**Empfohlen, ohne Passwort:** unter **Heimnetz → Netzwerk → Netzwerkeinstellungen** die Option **„Statusinformationen über UPnP übertragen“** aktivieren. Das Plugin liest den Verbindungsstatus dann ohne Anmeldung. Auf der OPNsense wird kein FRITZ!Box-Passwort gespeichert.

**Nur falls das nicht geht, per TR-064:**
- **Heimnetz → Netzwerk → Netzwerkeinstellungen → „Zugriff für Anwendungen zulassen“** aktivieren.
- **System → FRITZ!Box-Benutzer**: einen **eigenen** Benutzer nur für die OPNsense anlegen, nicht dein eigenes Konto. Zuerst ohne Zusatzrechte anlegen und mit „Verbindung testen“ prüfen. Nur wenn das nicht reicht, Rechte schrittweise ergänzen.
- Das Passwort steht im Klartext in der OPNsense-Konfiguration (wie alle Passwörter dort) und damit auch in jedem Konfigurations-Backup.
- Nach einer fehlgeschlagenen Anmeldung pausiert das Plugin TR-064 für 15 Minuten, damit die FRITZ!Box die Anmeldung nicht sperrt. In der Zeit nutzt es UPnP, falls aktiviert.

### 2. OPNsense vorbereiten
- **System → Gateways → Konfiguration**: Haupt-Gateway (z. B. `WAN_DHCP` oder `WAN_CABLE_GW`) und Failover-Gateway (z. B. `WAN_5G`) müssen vorhanden sein, **Monitoring aktiviert**.
- Beim Haupt-Gateway als **Monitor-IP die Haupt-FRITZ!Box** eintragen (z. B. `192.168.0.1`) und **speichern**. Das gilt auch für automatisch erzeugte Gateways wie `WAN_DHCP`; das Plugin ändert nur gespeicherte Gateways.
- **System → Gateways → Gruppen**: Gruppe anlegen, Haupt-Gateway = Tier 1, Failover-Gateway = Tier 2, Auslöser „Paketverlust“ oder „Mitglied ausgefallen“.
- Die Gateway-Gruppe in den Firewall-Regeln (LAN) als Gateway eintragen.
- Damit die Firewall selbst (DNS, Benachrichtigungen) im Failover ins Internet kommt: **System → Einstellungen → Allgemein** → „Allow default gateway switching“ aktivieren.

### 3. Plugin konfigurieren (Dienste → FRITZ!Box Failover)

Die Weboberfläche ist englisch; dort heißt die Hauptleitung „cable“.

| Feld | Standard | Bedeutung |
|---|---|---|
| FRITZ!Box IP address | `192.168.0.1` | Adresse der Haupt-FRITZ!Box aus Sicht der OPNsense |
| How to detect a dead cable line | FRITZ!Box + Ping | wie ein Ausfall erkannt wird (siehe oben) |
| TR-064 username / password | leer | optional; leer = Status per UPnP ohne Anmeldung |
| Cable gateway name | – | das Haupt-Gateway, Auswahl aus den gefundenen Gateways |
| Backup gateway | – | das Failover-Gateway; für die Abfrage der öffentlichen IP über die Failover-Leitung |
| Cable interface | Automatisch | Schnittstelle der Hauptleitung, z. B. WAN (`vtnet5`) |
| Normal monitor IP | `192.168.0.1` | die Haupt-FRITZ!Box |
| Fake monitor IP | `192.0.2.1` | antwortet nie, löst den Failover aus |
| Internet test addresses | `9.9.9.9, 1.1.1.1, 8.8.8.8` | mindestens zwei; tot erst, wenn keine antwortet |
| Check interval | 10 s | wie oft geprüft wird |
| Pings per check | 2 | je Testadresse |
| Ping timeout | 2 s | |
| Failures before failover | 3 | Fehlschläge in Folge bis zur Umschaltung |
| Successes before switching back | 3 | Erfolge in Folge bis zur Rückschaltung; bei wackligen Leitungen höher setzen |
| Firewall rules for test pings | an | siehe unten |

Dann **„Test connection“** klicken und anschließend **„Apply“**. Der Testmodus ist anfangs an, siehe oben. Der Status oben auf der Seite zeigt live, was das Plugin sieht. Meldungen landen im Systemlog (Tag `fritzfailover`).

### Wie die Test-Pings über die Hauptleitung gehen

Im Failover routet die Firewall selbst über die Failover-Leitung. Damit die Test-Pings trotzdem die Hauptleitung prüfen, nutzt das Plugin zwei Mechanismen:

1. **Eigene Routing-Tabelle:** Die Pings laufen per `setfib` in einer Tabelle, deren einzige Standardroute das Haupt-Gateway ist. Lässt sich die Tabelle nicht einrichten, werden die Pings nicht für die Entscheidung verwendet.
2. **Firewall-Regeln (Firewall rules for test pings):** Pro Testadresse eine automatische Floating-Regel
   `pass out quick route-to (<Haupt-Schnittstelle> <Haupt-Gateway>) inet proto icmp from (<Haupt-Schnittstelle>) to <Testadresse>`.
   Sie hat Priorität 1 und steht damit vor allen Floating-, Gruppen- und Schnittstellenregeln aus der GUI. Typischer Grund, warum sie nötig ist: eine eigene Floating-Regel in Richtung **out** mit Gateway-Gruppe, die auch den Verkehr der Firewall selbst erfasst und ihn im Failover auf die Failover-Leitung umleitet.

Das Plugin prüft bei jeder Prüfung, ob die Regeln geladen sind (Statuszeile *Firewall rules for test pings*). Fehlen sie, lädt es die Firewall-Regeln neu (höchstens alle 15 Minuten). Steht eine andere Regel mit Gateway davor (z. B. von einem anderen Plugin), zeigt die Statuszeile eine Warnung mit deren Beschreibung.

Tipp: Eine Testadresse, die **nur** von der öffentlichen IP deiner Hauptleitung antwortet (z. B. ein eigener Server mit IP-Freigabe), zeigt eindeutig, ob die Pings wirklich über die Hauptleitung gehen.

### Verhalten bei Neustart, Deaktivieren und Deinstallieren

| Situation | Was mit einem aktiven Failover passiert |
|---|---|
| „Apply“, Dienst-Neustart, Reboot, Update | **bleibt erhalten**. Der Dienst setzt nach dem Start fort und schaltet erst zurück, wenn die Hauptleitung wirklich wieder gesund ist. |
| Plugin deaktivieren, Testmodus einschalten | normale Monitor-IP wird zurückgesetzt, OPNsense schaltet zurück auf die Hauptleitung |
| Plugin deinstallieren | normale Monitor-IP wird zurückgesetzt |
| Dienst nur gestoppt (Plugin bleibt aktiv) | **bleibt erhalten** (Internet läuft weiter über die Failover-Leitung). Die Statusseite zeigt das an. |

Nach einem Neustart der OPNsense misst das Plugin die ersten 2 Minuten nur und schaltet nicht um. So löst eine noch nicht fertige WAN-Verbindung beim Booten keinen Failover aus.

### Cloudflare-DNS umschalten (optional)

Damit z. B. WireGuard-Clients bei einem Failover automatisch über die Failover-Leitung kommen, kann das Plugin einen DNS-Eintrag bei Cloudflare umstellen:

- **Record (CNAME):** z. B. `wg.domain.com`, der Name, den deine Clients benutzen.
- **Normales Ziel:** z. B. `fritz-main.domain.com` (DynDNS der Haupt-FRITZ!Box).
- **Failover-Ziel:** z. B. `fritz-5g.domain.com` (DynDNS der Failover-Leitung).
- **TTL:** 60 Sekunden (Minimum bei Cloudflare).

**API-Token anlegen:** dash.cloudflare.com → My Profile → API Tokens → Create Token → *Create Custom Token*
- Permissions: **Zone → Zone → Read** und **Zone → DNS → Edit**
- Zone Resources: **Include → Specific zone → deine Domain**
- Keine weiteren Rechte, nicht den Global API Key verwenden.

Der Eintrag wird als CNAME „DNS only“ (nicht proxied) gesetzt; existiert er noch nicht, wird er angelegt. Einen vorhandenen A/AAAA-Eintrag mit demselben Namen fasst das Plugin nicht an. Mit **„Check Cloudflare“** prüfst du Token und Eintrag, ohne etwas zu ändern.

### Push-Benachrichtigung per Pushover (optional)

Bei jedem Failover (und auf Wunsch bei der Rückschaltung) kommt eine Pushover-Nachricht, sobald OPNsense tatsächlich umgeschaltet hat. Das erkennt das Plugin am Gateway-Status oder an der Standardroute der Firewall; spätestens nach 5 Minuten wird trotzdem gesendet. Dazu kommt eine einstellbare Verzögerung (3–30 Sekunden, Standard 5).

Die Nachricht enthält Uhrzeit, Grund und die öffentliche IPv4-Adresse der jetzt genutzten Leitung. Trägst du das **Backup gateway** ein, wird die IP gezielt über die Failover-Leitung (Failover) bzw. die Hauptleitung (Rückschaltung) abgefragt. Die Dienste dafür sind einstellbar, Standard `https://ifconfig.me/ip` und `https://ip.me`; mindestens zwei eintragen, falls einer ausfällt. Nötig sind ein **Application API Token** (pushover.net → Your Applications → Create an Application) und dein **User Key**. Mit **„Send test push“** prüfst du die Einstellungen.

Kommt Cloudflare oder Pushover nicht durch (z. B. direkt beim Ausfall), versucht es das Plugin bei jeder Prüfung erneut. Beides passiert nur bei echten Umschaltungen und beim Test-Failover, nie im Testmodus.

### Umschalt-Verlauf

Die Statusseite zeigt, wann zuletzt umgeschaltet wurde, seit wann die Failover-Leitung aktiv ist (mit laufender Dauer) und eine Tabelle der letzten 20 Umschaltungen mit Grund. Der Verlauf liegt unter `/var/db/fritzfailover/` und übersteht Neustarts; beim Deinstallieren wird er gelöscht.

Umschaltungen werden ohne Eintrag in der Konfigurations-Historie gespeichert, damit eine flappende Leitung deine echten Backups nicht aus der Historie verdrängt. Jede Umschaltung steht im Systemlog (Tag `fritzfailover`).

### Test-Failover

Der Button **„Test failover (2 minutes)“** löst einen **echten** Failover für 2 Minuten aus, auf demselben Weg wie bei einem Ausfall: Die Monitor-IP des Haupt-Gateways wird auf die Fake-Monitor-IP gesetzt, dpinger meldet 100 % Verlust, OPNsense schaltet auf die Failover-Leitung. Nach 2 Minuten wird die normale Monitor-IP gesetzt und OPNsense schaltet zurück. Das funktioniert auch im Testmodus. Während des Tests trifft das Plugin keine eigenen Entscheidungen, misst aber weiter über die Hauptleitung; die Statusseite zeigt einen Countdown. Stoppen des Dienstes oder **„Restore normal monitor IP“** beendet den Test sofort.

### Debug-Modus

Für die Analyse eines Ausfalls (z. B. wenn ein Techniker an der Leitung arbeitet): Auf der Statusseite ganz unten den Bereich **Debug mode** aufklappen und **„Start debug mode (12 hours)“** drücken. Ab dann wird bei jeder Prüfung eine Zeile geschrieben mit
- Entscheidung des Plugins, Zählern und aktiver Monitor-IP,
- Rohwerten der Haupt-FRITZ!Box (Verbindungsstatus, letzter Verbindungsfehler, Uptime, physischer Leitungsstatus, Anschlussart),
- Ergebnis jedes Test-Pings und Zustand der Plugin-Firewall-Regeln,
- Sicht von OPNsense auf beide Gateways (Status, Verlust, Latenz, Monitor-IP),
- Standardroute der Firewall.

Zeilen, in denen sich etwas Relevantes geändert hat, beginnen mit `*`. Der Modus endet nach spätestens 12 Stunden von selbst. Er lässt sich auch **planen**: Datum und Uhrzeit wählen, „Schedule“ drücken; ab dann läuft er 12 Stunden (der Dienst muss dafür laufen). Mit **„Download debug log“** lädst du die Datei herunter (`/var/db/fritzfailover/debug.log`, max. 20 MB). Die tägliche Selbstheilung löscht das Log, aber nie während einer laufenden Aufzeichnung. Die öffentliche IP wird nicht protokolliert.

Mit dem Schalter **Verbose** schreibt der Debug-Modus zusätzlich
- alle geladenen Firewall-Regeln mit `route-to`/`reply-to` (Gateway-Gruppen, Policy-Routing),
- die Standard- und statischen Routen der normalen und der beiden Plugin-Routing-Tabellen,

jeweils nur wenn sich daran etwas geändert hat, sowie bei jeder Prüfung die Firewall-States der Test-Pings. Damit sieht man direkt, ob eine Regel die Test-Pings umleitet.

### Selbstheilung

Unter **Self-healing** (standardmäßig an, täglich 04:00 Uhr) startet das Plugin seinen eigenen Überwachungsprozess regelmäßig neu und leert seine Laufzeitdateien (Zähler, Temp-Dateien). Statistik und Umschalt-Verlauf bleiben erhalten. OPNsense, Routing, Firewall und dpinger werden dabei nicht angefasst. Der Neustart passiert nur, wenn alles in Ordnung ist; während eines Failovers, eines Test-Failovers, beim Mitzählen von Fehlern oder solange eine Benachrichtigung/DNS-Umstellung aussteht, wird er auf das nächste Zeitfenster verschoben. Wählbar: täglich oder wöchentlich (Sonntag) und die Stunde.

### Langzeitbetrieb

Alles, was das Plugin speichert, ist in der Größe begrenzt:

| Was | Wo | Größe |
|---|---|---|
| Status, Zähler, Sperre | `/var/run/fritzfailover.*` | je eine Zeile bzw. einige hundert Byte, wird überschrieben |
| Statistik je Testadresse | `/var/run/fritzfailover.stats` | eine Zeile je Adresse |
| Umschalt-Verlauf | `/var/db/fritzfailover/history` | max. 50 Einträge |
| Debug-Log | `/var/db/fritzfailover/debug.log` | nur im Debug-Modus, max. 20 MB |
| Push-Warteschlange | `/var/run/fritzfailover.push_queue` | nur bis zum Versand, max. 1 Tag |
| Konfiguration | `config.xml` | nur bei Umschaltungen, ohne Backup-Einträge |
| Systemlog | OPNsense-Log (rotiert von OPNsense) | normal nichts; nur Umschaltungen und verlorene Pings |

Prozesse: ein dauerhafter Überwachungsprozess (von `daemon(8)` bei einem Absturz automatisch neu gestartet); jede Prüfung startet kurzlebige Prozesse (PHP, ping, curl), die alle ein Zeitlimit haben und sich wieder beenden.

**Frühe Anzeichen für Probleme:**
- Die Statusseite zeigt eine rote Warnung, wenn die letzte Prüfung länger als 3 Prüfintervalle + 60 Sekunden her ist.
- Status „unknown“ oder Meldungen mit `fritzfailover` unter **System → Protokolldateien → Allgemein**.
- In der Statistik steigen „Checks“ nicht mehr.

Abhilfe in allen Fällen: Dienst unter **System → Diagnose → Dienste** neu starten (ein aktiver Failover bleibt dabei erhalten).

### Notfall per SSH

```sh
# normale Monitor-IP sofort zurücksetzen
/usr/local/opnsense/scripts/OPNsense/FritzFailover/fritzbox_failover.sh restore

# Plugin komplett entfernen (setzt die Monitor-IP ebenfalls zurück)
pkg delete -y os-fritzbox-failover
```

---

## Geprüfte FRITZ!Boxen

Alle genannten Modelle liefern die benötigten Werte per UPnP ohne Passwort; jede davon kann als Haupt-FRITZ!Box dienen.

| Modell | FRITZ!OS | Anschluss | Status per UPnP (ohne Passwort) |
|---|---|---|---|
| FRITZ!Box 6660 Cable | 8.25 | Kabel (Vodafone) | `WANIPConnection:1` → `Connected` ✔, Leitungsstatus ✔ |
| FRITZ!Box 7590 | 8.25 | Ethernet/ATA (externer Zugang) | `WANIPConnection:1` → `Connected` ✔, Leitungsstatus ✔ |
| FRITZ!Box 6850 5G | 8.25 | 5G/LTE (Carrier-NAT) | `WANIPConnection:1` → `Connected` ✔, Leitungsstatus ✔ |
| FRITZ!Box 7590 | 8.21 | DSL mit PPPoE-Einwahl | `WANIPConnection:1` → `Connected` ✔, Leitungsstatus ✔ |

Ausgaben weiterer Modelle mit dem Diagnose-Skript sind willkommen.

## FRITZ!Box-Diagnose

`tools/fritzbox_probe.py` fragt eine oder mehrere FRITZ!Boxen nur lesend ab: welche WAN-Dienste sie anbietet und was alle Abfragen ohne Parameter liefern (z. B. `NewConnectionStatus`). IP- und MAC-Adressen werden maskiert, die Ausgabe kann geteilt werden. Auf der OPNsense (funktioniert auch in der Standard-Shell `csh`):

```sh
curl -fsSL -o /tmp/fbprobe.py https://raw.githubusercontent.com/chevchelios420x/os-fritzbox-failover/main/tools/fritzbox_probe.py && python3 /tmp/fbprobe.py 192.168.0.1 192.168.1.1
```

Mit `--user BENUTZER` werden zusätzlich die TR-064-Abfragen mit Anmeldung ausgeführt (das Passwort wird abgefragt).

## Selbst bauen / Release erstellen

Bei jedem Tag `vX.Y` (oder GitHub-Release) baut `.github/workflows/release.yml` das Paket in einer FreeBSD-14-VM mit dem offiziellen [opnsense/plugins](https://github.com/opnsense/plugins)-Build-System (`make package`) und hängt `os-fritzbox-failover-X.Y.pkg` sowie `os-fritzbox-failover.pkg` an das Release.

Das Build-System ist auf den Stand `26.1.11` gepinnt, alle GitHub Actions auf feste Commit-IDs. Für eine neue OPNsense-Version `PLUGINS_TAG` und `PLUGINS_COMMIT` im Workflow bewusst anheben.

```sh
tools/release.sh 1.1
```

Das Skript prüft, ob `main` sauber und aktuell ist, setzt `PLUGIN_VERSION` im Makefile, committet, legt den Tag `v1.1` an und pusht beides.

Ohne lokales git: auf GitHub unter **Actions → Build and release package → Run workflow** die Version (z. B. `1.1`) eintragen. Der Workflow legt Tag und Release dann selbst an. Die Version im Makefile sollte vorher passen.

Die Verzeichnisstruktur entspricht dem offiziellen Plugin-Layout (`Makefile`, `pkg-descr`, `src/…`) und kann unverändert als `net/fritzbox-failover` in das opnsense/plugins-Repository übernommen werden.

## Lizenz

BSD 2-Clause
