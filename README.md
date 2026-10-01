# os-fritzbox-failover

OPNsense-Plugin für einen sauberen, automatischen WAN-Failover hinter einer **FRITZ!Box Cable** (getestet mit FRITZ!Box 6660 Cable, FRITZ!OS 8.x) – z. B. Vodafone-Kabel als Hauptleitung, 5G/LTE als Backup.

Das Plugin wird als fertiges `.pkg` installiert. Auf der Firewall müssen **kein git, keine opnsense-devtools und kein Compiler** installiert werden.

---

## Das Problem: falscher Failover trotz funktionierender Kabelleitung

- OPNsense überwacht ein Gateway mit `dpinger`, der dauerhaft eine Monitor-IP anpingt.
- Steht dort eine Internet-Adresse wie `9.9.9.9`, läuft das oft Minuten oder Stunden gut. Irgendwann meldet dpinger auf virtualisierten OPNsense-Instanzen (VirtIO, `vtnet`) hinter der FRITZ!Box aber **100 % Verlust, obwohl die Leitung sauber läuft**. OPNsense schaltet dann unnötig auf 5G/LTE um.
- Steht als Monitor-IP die **FRITZ!Box selbst** (z. B. `192.168.0.1`, gleich der Gateway-Adresse), tritt das nicht auf. Dann erkennt OPNsense aber keine echten Ausfälle mehr, etwa wenn bei Vodafone der Backbone gestört ist, das Modem aber synchron bleibt.
- Das Gateway zu deaktivieren ist keine Lösung: Damit brechen Gateway-Gruppen und **Policy-Based-Routing-Regeln**.

## Die Lösung

Das Gateway wird im Normalbetrieb **gegen die FRITZ!Box** überwacht (stabil, kein Fehlalarm). Ob das Internet hinter der Kabelleitung wirklich funktioniert, entscheidet das Plugin. Dafür prüft es alle paar Sekunden:

1. **Den Status der FRITZ!Box per TR-064**: den Wert `NewConnectionStatus` aus `WANIPConnection:1` → `GetStatusInfo`. Er erkennt, wenn die Box ihre Verbindung verliert (Kabel-Sync weg, keine IP-Adresse mehr). Einen gestörten Vodafone-Backbone erkennt er **nicht**, weil die Box dann weiter „Connected“ meldet.
2. **Einen Internet-Test über die Kabelleitung**: Ping an mehrere Adressen gleichzeitig (Standard `9.9.9.9`, `1.1.1.1`, `8.8.8.8`), mit der Adresse der Kabel-Schnittstelle als Absender. Die OPNsense-Regel „let out anything from firewall host itself (force gw)“ schickt diese Pings immer über das Kabel-Gateway, auch während des Failovers. Für jeden Test wird ein neuer Ping-Prozess gestartet. Die Leitung gilt erst als tot, wenn **keine** Adresse antwortet.

Welche Prüfungen benutzt werden, stellst du in der GUI ein: beide (empfohlen), nur die FRITZ!Box oder nur der Ping.

Ist die Leitung mehrmals hintereinander tot (Standard 3), setzt das Plugin die **Monitor-IP des Kabel-Gateways auf eine tote Adresse** (`192.0.2.1`). Dazu startet es nur den Gateway-Monitor (dpinger) dieses einen Gateways neu (`pluginctl -c monitor <Gateway>`). dpinger meldet 100 % Verlust, und OPNsense schaltet mit seinen **eigenen Gateway-Gruppen** auf das Backup um. Ist die Leitung wieder mehrmals hintereinander gesund, wird die normale Monitor-IP (die FRITZ!Box) zurückgesetzt, und OPNsense schaltet selbst zurück.

Das Plugin greift so wenig wie möglich ein. Es ändert **ausschließlich die Monitor-IP eines bestehenden Gateways** und startet den dpinger dieses Gateways neu. Es legt keine Gateways an, deaktiviert keine, löscht keine Routen und lädt weder Routing noch Firewall selbst neu. Die Umschaltung macht OPNsense wie bei jedem Gateway-Ausfall.

### Testmodus (Dry Run)

Nach der Installation ist der **Testmodus eingeschaltet**. Dabei laufen alle Prüfungen, aber an der OPNsense wird **nichts** geändert. Die Statusseite zeigt:
- was das Plugin tun *würde* („würde jetzt auf Backup umschalten“),
- eine **Statistik pro Testadresse**: Prüfungen, verlorene Pings, Prüfungen ganz ohne Antwort, Zeitpunkt des letzten Verlusts.

So siehst du nach ein paar Tagen, ob die Testadressen (z. B. `9.9.9.9`) dieselben Aussetzer haben wie dpinger, und ob das Plugin in dieser Zeit fälschlich umgeschaltet hätte. Jeder verlorene Ping steht zusätzlich im Systemlog (Tag `fritzfailover`). Erst wenn alles sauber aussieht, schaltest du den Testmodus aus.

---

## Installation mit Windows (am einfachsten)

1. [`tools/Install-FritzFailover.ps1`](tools/Install-FritzFailover.ps1) herunterladen (auf der Seite rechts oben „Download raw file“).
2. Rechtsklick auf die Datei → **„Mit PowerShell ausführen“**.
   Falls Windows das blockiert: PowerShell öffnen und
   `powershell -ExecutionPolicy Bypass -File .\Install-FritzFailover.ps1` eingeben.
3. IP der OPNsense und Benutzer (`root`) eingeben; das Passwort fragt ssh ab (bei Prüfung und Installation je einmal).
   Benötigt nur den in Windows 10/11 eingebauten OpenSSH-Client.

Das Skript prüft per SSH, ob die OPNsense passt (Version, FreeBSD 14, nötige Programme, Speicherplatz, Download von GitHub, FRITZ!Box/TR-064 erreichbar), zeigt die gefundenen Gateways an und installiert das Plugin nach Rückfrage. Mit `-CheckOnly` wird nur geprüft.

Voraussetzung: SSH ist in der OPNsense aktiviert (**System → Einstellungen → Verwaltung → Secure Shell**, inkl. Root-Login mit Passwort).

## Installation per SSH (eine Zeile)

Per SSH auf der OPNsense anmelden (Menüpunkt `8) Shell`) und einfügen:

```sh
fetch -o /tmp/os-fritzbox-failover.pkg https://github.com/chevchelios420x/os-fritzbox-failover/releases/latest/download/os-fritzbox-failover.pkg && env IGNORE_OSVERSION=yes pkg add -f /tmp/os-fritzbox-failover.pkg && rm -f /tmp/os-fritzbox-failover.pkg
```

Danach die Weboberfläche neu laden. Das Plugin erscheint unter **Dienste → FRITZ!Box Failover** und in **System → Firmware → Plugins** als installiert.

Updates: denselben Befehl erneut ausführen.
Deinstallieren: `pkg delete os-fritzbox-failover`

---

## Einrichtung

### 1. FRITZ!Box vorbereiten
- **Heimnetz → Netzwerk → Netzwerkeinstellungen → „Zugriff für Anwendungen zulassen“** aktivieren (TR-064).
- **System → FRITZ!Box-Benutzer**: eigenen Benutzer anlegen, z. B. `opnsense`, mit Recht „FRITZ!Box Einstellungen“.

### 2. OPNsense vorbereiten
- **System → Gateways → Konfiguration**: Kabel-Gateway (z. B. `WAN_CABLE_GW` oder `WAN_DHCP`) und Backup-Gateway (5G/LTE) müssen vorhanden sein, **Monitoring aktiviert**.
- Beim Kabel-Gateway als **Monitor-IP die FRITZ!Box** eintragen (z. B. `192.168.0.1`) und **speichern**. Das Gateway muss gespeichert sein, das gilt auch für automatisch erzeugte Gateways wie `WAN_DHCP`. Das Plugin legt selbst keine Gateways an.
- **Firewall → Einstellungen → Erweitert**: die Option „Disable force gateway“ **nicht** anhaken (Standard). Sonst weicht das Plugin für die Test-Pings auf kurzzeitige Host-Routen aus.
- **System → Gateways → Gruppen**: Gruppe anlegen, Kabel = Tier 1, Backup = Tier 2, Auslöser „Paketverlust“ oder „Mitglied ausgefallen“.
- Die Gateway-Gruppe in den Firewall-Regeln (LAN) als Gateway eintragen.

### 3. Plugin konfigurieren (Dienste → FRITZ!Box Failover)

| Feld | Standard | Bedeutung |
|---|---|---|
| FRITZ!Box IP-Adresse | `192.168.0.1` | Adresse der FRITZ!Box aus Sicht der OPNsense |
| Erkennung | FRITZ!Box + Ping | wie ein Ausfall erkannt wird (siehe oben) |
| TR-064 Benutzer / Passwort | – | der in Schritt 1 angelegte Benutzer |
| Kabel-Gateway-Name | `WAN_CABLE_GW` | exakt wie unter System → Gateways |
| Kabel-Schnittstelle | Automatisch | z. B. WAN (`vtnet5`); automatisch = Schnittstelle des Gateways |
| Normale Monitor-IP | `192.168.0.1` | die FRITZ!Box, gleiche Adresse wie das Gateway |
| Fake-Monitor-IP | `192.0.2.1` | antwortet nie, löst den Failover aus |
| Internet-Testadressen | `9.9.9.9, 1.1.1.1, 8.8.8.8` | werden über das Kabel angepingt; tot erst, wenn keine antwortet |
| Prüfintervall | 10 s | wie oft geprüft wird |
| Pings pro Prüfung | 2 | je Testadresse |
| Ping-Timeout | 2 s | |
| Fehler bis Failover | 3 | Fehlschläge in Folge bis zur Umschaltung |
| Erfolge bis Rückschaltung | 3 | Erfolge in Folge bis zur Rückschaltung |

Dann **„Verbindung testen“** klicken und anschließend **„Übernehmen“**. Der Testmodus ist anfangs an, siehe oben. Der Status oben auf der Seite zeigt live, was das Plugin sieht. Meldungen landen im Systemlog (Tag `fritzfailover`).

Wird der Dienst gestoppt oder deaktiviert, setzt das Plugin die normale Monitor-IP automatisch zurück.

---

## Selbst bauen / Release erstellen

Bei jedem Tag `vX.Y` (oder GitHub-Release) baut `.github/workflows/release.yml` das Paket in einer FreeBSD-14-VM mit dem offiziellen [opnsense/plugins](https://github.com/opnsense/plugins)-Build-System (`make package`) und hängt `os-fritzbox-failover-X.Y.pkg` sowie `os-fritzbox-failover.pkg` an das Release.

```sh
tools/release.sh 1.1
```

Das Skript prüft, ob `main` sauber und aktuell ist, setzt `PLUGIN_VERSION` im Makefile, committet, legt den Tag `v1.1` an und pusht beides.

Ohne lokales git: auf GitHub unter **Actions → Build and release package → Run workflow** die Version (z. B. `1.1`) eintragen. Der Workflow legt Tag und Release dann selbst an. Die Version im Makefile sollte vorher passen.

Die Verzeichnisstruktur entspricht dem offiziellen Plugin-Layout (`Makefile`, `pkg-descr`, `src/…`) und kann unverändert als `net/fritzbox-failover` in das opnsense/plugins-Repository übernommen werden.

## Lizenz

BSD 2-Clause
