# Roadmap

## Geplant nach erfolgreichem Praxistest von 1.1

### DOCSIS-Pegel als zusätzliches Signal
- Downstream-/Upstream-Pegel, SNR (MER) und Fehlerzähler (korrigierbar/unkorrigierbar) pro Kanal aus der FRITZ!Box lesen.
- Zugriff nur über die Weboberfläche: Anmeldung per `login_sid.lua` (PBKDF2-Challenge, wie in itsDNNS/docsight), Daten über `data.lua` (Seite `docInfo`). Braucht Benutzername und Passwort.
- Idee: bei deutlich schlechten Werten vorbeugend umschalten oder die Rückschaltung verzögern; Schwellwerte in der GUI, zuerst nur im Testmodus anzeigen und protokollieren.
- Voraussetzung: positive Rückmeldung zum Praxistest der Version 1.1.

## Zurückgestellt (vorerst nicht verfolgen)

Grundsatz: Das Plugin nutzt nur Werte, die auf allen bestätigten FRITZ!Boxen (6660 Cable, 6850 5G, 7590) ohne Passwort verfügbar sind.

- DOCSIS-Pegel (oben) – nur bei Kabel-Boxen und nur mit Login über die Weboberfläche.
- DSL mit PPPoE-Einwahl über `WANPPPConnection:1` – bisher keine Box zum Bestätigen.

## Erledigt

- Physischer Leitungsstatus (`GetCommonLinkProperties` → `NewPhysicalLinkStatus`) als zusätzliches Signal, seit 1.15.
