# Roadmap

## Geplant nach erfolgreichem Praxistest von 1.1

### DOCSIS-Pegel als zusätzliches Signal
- Downstream-/Upstream-Pegel, SNR (MER) und Fehlerzähler (korrigierbar/unkorrigierbar) pro Kanal aus der FRITZ!Box lesen.
- Zugriff nur über die Weboberfläche: Anmeldung per `login_sid.lua` (PBKDF2-Challenge, wie in itsDNNS/docsight), Daten über `data.lua` (Seite `docInfo`). Braucht Benutzername und Passwort.
- Idee: bei deutlich schlechten Werten vorbeugend umschalten oder die Rückschaltung verzögern; Schwellwerte in der GUI, zuerst nur im Testmodus anzeigen und protokollieren.
- Voraussetzung: positive Rückmeldung zum Praxistest der Version 1.1.

## Zurückgestellt (vorerst nicht verfolgen)

Grundsatz: Das Plugin nutzt nur Werte, die auf allen bestätigten FRITZ!Boxen (6660 Cable, 6850 5G, 7590 ATA und 7590 DSL/PPPoE) ohne Passwort verfügbar sind.

- DOCSIS-Pegel (oben) – nur bei Kabel-Boxen und nur mit Login über die Weboberfläche.

- Kontroll-Ziel „nur übers Kabel erreichbar“: ein Testziel markieren, das nur von der öffentlichen Kabel-IP antwortet (z. B. eigener Server mit IP-Freigabe). Antworten die übrigen Ziele, dieses aber nicht, laufen die Test-Pings über eine andere Leitung: Warnung anzeigen und die Pings nicht als Erfolg werten. Seit 1.18/1.19 durch eigene Routing-Tabelle und Firewall-Regeln abgedeckt; nur als zusätzliche Absicherung gedacht.

## Erledigt

- DSL mit PPPoE-Einwahl: nicht nötig. Eine 7590 (FRITZ!OS 8.21, `NewLinkType=PPPoE`) liefert den Status per UPnP ebenfalls über `WANIPConnection:1`, `WANPPPConnection` wird nicht gebraucht.

- Physischer Leitungsstatus (`GetCommonLinkProperties` → `NewPhysicalLinkStatus`) als zusätzliches Signal, seit 1.15.
