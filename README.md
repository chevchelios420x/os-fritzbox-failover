# os-fritzbox-failover

OPNsense-Plugin für einen sauberen, automatischen WAN-Failover hinter einer **FRITZ!Box Cable** (getestet mit FRITZ!Box 6660 Cable, FRITZ!OS 8.x) – z. B. Vodafone-Kabel als Hauptleitung, 5G/LTE als Backup.

Das Plugin wird als fertiges `.pkg` installiert. Auf der Firewall müssen **kein git, keine opnsense-devtools und kein Compiler** installiert werden.

---

## Das Problem: Vodafone-Kabel „flappt“, OPNsense schaltet nicht sauber zurück

- Bei Störungen im Vodafone-Backbone bleibt das Kabelmodem oft **synchron (DOCSIS-Sync)**, die FRITZ!Box meldet „verbunden“, aber das Internet ist weg.
- OPNsense erkennt das per `dpinger` (Gateway-Monitoring) und schaltet auf das Backup-Gateway um – soweit gut.
- Auf virtualisierten OPNsense-Instanzen (VirtIO, `vtnet`) bleibt der Monitor danach aber häufig bei **100 % Paketverlust hängen** (veraltete ARP-Einträge, TTL-Drops, Host-Route des Monitors zeigt ins Leere). Die Kabelleitung ist längst wieder da, OPNsense schaltet aber **nie zurück**.
- Das Gateway einfach zu deaktivieren ist keine Lösung: dadurch verschwinden Gateway-Gruppen-Einträge und **Policy-Based-Routing-Regeln** brechen.

## Die Lösung

Das Plugin läuft als kleiner Dienst und prüft alle paar Sekunden:

1. **FRITZ!Box-Status per TR-064** (`WANIPConnection:1` → `GetStatusInfo`, Digest-Authentifizierung wie von FRITZ!OS 8 verlangt; Fallback auf den unauthentifizierten UPnP-IGD-Dienst).
2. **Erzwungenen Test-Ping über die Kabelschnittstelle** (Quelladresse der Kabel-Schnittstelle, bei Bedarf temporäre Host-Route über das Kabel-Gateway) – unabhängig davon, über welche Leitung die Firewall gerade routet.

Ist die Leitung mehrmals hintereinander gestört, setzt das Plugin die **Monitor-IP des Kabel-Gateways auf eine tote Adresse** (`192.0.2.1`). OPNsense sieht 100 % Verlust und schaltet mit seinen **eigenen Gateway-Gruppen** auf das Backup um. Ist die Kabelleitung wieder mehrmals hintereinander gesund, wird die **normale Monitor-IP** zurückgesetzt und OPNsense schaltet zurück. Das Gateway selbst wird **nie deaktiviert**.

---

## Installation (eine Zeile)

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
- **System → Gateways → Gruppen**: Gruppe anlegen, Kabel = Tier 1, Backup = Tier 2, Auslöser „Paketverlust“ oder „Mitglied ausgefallen“.
- Die Gateway-Gruppe in den Firewall-Regeln (LAN) als Gateway eintragen.

### 3. Plugin konfigurieren (Dienste → FRITZ!Box Failover)

| Feld | Standard | Bedeutung |
|---|---|---|
| FRITZ!Box IP-Adresse | `192.168.0.1` | Adresse der FRITZ!Box aus Sicht der OPNsense |
| TR-064 Benutzer / Passwort | – | der in Schritt 1 angelegte Benutzer |
| Kabel-Gateway-Name | `WAN_CABLE_GW` | exakt wie unter System → Gateways |
| Kabel-Schnittstelle | Automatisch | z. B. WAN (`vtnet5`); automatisch = Schnittstelle des Gateways |
| Normale Monitor-IP | `9.9.9.9` | öffentliche IP, die im Normalbetrieb überwacht wird |
| Fake-Monitor-IP | `192.0.2.1` | antwortet nie, löst den Failover aus |
| Prüfintervall | 10 s | wie oft geprüft wird |
| Pings pro Prüfung | 2 | |
| Ping-Timeout | 2 s | |
| Fehler bis Failover | 3 | Fehlschläge in Folge bis zur Umschaltung |
| Erfolge bis Rückschaltung | 3 | Erfolge in Folge bis zur Rückschaltung |

Dann **„Verbindung testen“** klicken und anschließend **„Übernehmen“**. Der Status oben auf der Seite zeigt live, was das Plugin sieht. Meldungen landen im Systemlog (Tag `fritzfailover`).

> Wichtig: Die normale Monitor-IP darf nicht gleichzeitig Monitor-IP des Backup-Gateways sein.

Wird der Dienst gestoppt oder deaktiviert, setzt das Plugin die normale Monitor-IP automatisch zurück.

---

## Selbst bauen / Release erstellen

Bei jedem Tag `vX.Y` (oder GitHub-Release) baut `.github/workflows/release.yml` das Paket in einer FreeBSD-14-VM mit dem offiziellen [opnsense/plugins](https://github.com/opnsense/plugins)-Build-System (`make package`) und hängt `os-fritzbox-failover-X.Y.pkg` sowie `os-fritzbox-failover.pkg` an das Release.

```sh
git tag v1.0 && git push origin v1.0
```

Die Verzeichnisstruktur entspricht dem offiziellen Plugin-Layout (`Makefile`, `pkg-descr`, `src/…`) und kann unverändert als `net/fritzbox-failover` in das opnsense/plugins-Repository übernommen werden.

## Lizenz

BSD 2-Clause
