# Roadmap

## Geplant nach erfolgreichem Praxistest von 1.1

### DOCSIS-Pegel als zusätzliches Signal
- Downstream-/Upstream-Pegel, SNR (MER) und Fehlerzähler (korrigierbar/unkorrigierbar) pro Kanal aus der FRITZ!Box lesen.
- Zugriff nur über die Weboberfläche: Anmeldung per `login_sid.lua` (PBKDF2-Challenge, wie in itsDNNS/docsight), Daten über `data.lua` (Seite `docInfo`). Braucht Benutzername und Passwort.
- Idee: bei deutlich schlechten Werten vorbeugend umschalten oder die Rückschaltung verzögern; Schwellwerte in der GUI, zuerst nur im Testmodus anzeigen und protokollieren.
- Voraussetzung: positive Rückmeldung zum Praxistest der Version 1.1.
