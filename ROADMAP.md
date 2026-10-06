# Roadmap

## Geplant nach erfolgreichem Praxistest von 1.1

### DOCSIS-Pegel als zusätzliches Signal
- Downstream-/Upstream-Pegel, SNR (MER) und Fehlerzähler (korrigierbar/unkorrigierbar) pro Kanal aus der FRITZ!Box lesen.
- Zugriff nur über die Weboberfläche: Anmeldung per `login_sid.lua` (PBKDF2-Challenge, wie in itsDNNS/docsight), Daten über `data.lua` (Seite `docInfo`). Braucht Benutzername und Passwort.
- Idee: bei deutlich schlechten Werten vorbeugend umschalten oder die Rückschaltung verzögern; Schwellwerte in der GUI, zuerst nur im Testmodus anzeigen und protokollieren.
- Voraussetzung: positive Rückmeldung zum Praxistest der Version 1.1.

### Physischer Leitungsstatus als zusätzliches Signal
- `WANCommonInterfaceConfig:1` → `GetCommonLinkProperties` liefert ohne Passwort `NewPhysicalLinkStatus` (Up/Down) und `NewWANAccessType`.
- Geprüft vorhanden bei 6660 Cable, 7590 (ATA) und 6850 5G mit FRITZ!OS 8.25.
- Idee: `Down` sofort als Fehler werten (Leitung komplett weg), schneller als die Ping-Prüfung.

### DSL mit PPPoE-Einwahl
- Status dort vermutlich über `WANPPPConnection:1` (UPnP: `/igdupnp/control/WANPPPConn1`). Noch keine Ausgabe einer solchen Box; erst einbauen, wenn bestätigt.
