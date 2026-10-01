<#
.SYNOPSIS
    Prüft per SSH, ob das Plugin os-fritzbox-failover auf einer OPNsense installiert werden kann,
    und installiert es auf Wunsch.

.DESCRIPTION
    Einfach per Rechtsklick -> "Mit PowerShell ausführen" starten.
    Das Skript fragt nach Adresse, Benutzername und Passwort der OPNsense,
    führt eine Reihe von Prüfungen durch und zeigt das Ergebnis farbig an.

    Verbindung: Es wird das in Windows 10/11 eingebaute ssh.exe (OpenSSH-Client) benutzt.
    ssh fragt selbst nach dem Passwort (bei Prüfung und Installation je einmal).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-FritzFailover.ps1
#>

[CmdletBinding()]
param(
    [string]$HostName,
    [string]$UserName,
    [int]$Port = 22,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'
$Repo = 'chevchelios420x/os-fritzbox-failover'
$PkgUrl = "https://github.com/$Repo/releases/latest/download/os-fritzbox-failover.pkg"

# ---------------------------------------------------------------------------
# Skripte, die auf der OPNsense ausgeführt werden (POSIX sh)
# Ausgabeformat je Zeile: STATUS|Text   (STATUS = OK, WARN, FAIL, INFO)
# ---------------------------------------------------------------------------
$RemoteCheck = @'
PKG_URL="__PKG_URL__"
say() { printf '%s|%s\n' "$1" "$2"; }

if [ "$(id -u)" = "0" ]; then
    say OK "Angemeldet als root"
else
    say FAIL "Benutzer ist nicht root. Bitte mit 'root' anmelden (System > Einstellungen > Verwaltung > SSH: Root-Login erlauben)."
fi

if [ -x /usr/local/sbin/opnsense-version ]; then
    VER=$(/usr/local/sbin/opnsense-version -v 2>/dev/null)
    say OK "OPNsense erkannt: Version $VER"
    MAJ=$(echo "$VER" | cut -d. -f1)
    MIN=$(echo "$VER" | cut -d. -f2 | cut -d_ -f1)
    case "$MAJ$MIN" in *[!0-9]*|'') MAJ=0; MIN=0 ;; esac
    if [ "$MAJ" -gt 24 ] || { [ "$MAJ" -eq 24 ] && [ "$MIN" -ge 7 ]; }; then
        say OK "Version ist neu genug (mindestens 24.7)"
    else
        say FAIL "OPNsense $VER ist zu alt. Bitte zuerst auf 24.7 oder neuer aktualisieren."
    fi
else
    say FAIL "Das ist keine OPNsense (opnsense-version fehlt)."
fi

OSMAJ=$(uname -r | cut -d. -f1)
if [ "$OSMAJ" = "14" ]; then
    say OK "FreeBSD $(uname -r) / $(uname -m) - passt zum Paket"
else
    say WARN "FreeBSD $(uname -r): Das Paket wird fuer FreeBSD 14 gebaut. Installation evtl. nicht moeglich."
fi

if grep -q createOrUpdateGateway /usr/local/opnsense/mvc/app/models/OPNsense/Routing/Gateways.php 2>/dev/null; then
    say OK "Gateway-Modell (MVC) vorhanden"
else
    say FAIL "Gateway-Modell nicht gefunden - OPNsense zu alt."
fi

for b in /usr/local/bin/curl /usr/local/bin/php /usr/local/bin/flock /usr/local/sbin/configctl /sbin/ping /usr/sbin/daemon /usr/local/sbin/pkg; do
    if [ -x "$b" ]; then say OK "Programm vorhanden: $b"; else say FAIL "Programm fehlt: $b"; fi
done

if service configd onestatus >/dev/null 2>&1; then
    say OK "configd laeuft"
else
    say WARN "configd scheint nicht zu laufen"
fi

FREE=$(df -k /usr/local | awk 'NR==2 {print $4}')
if [ -n "$FREE" ] && [ "$FREE" -gt 10240 ]; then
    say OK "Genug Speicherplatz frei ($((FREE / 1024)) MB)"
else
    say FAIL "Zu wenig Speicherplatz auf /usr/local"
fi

if pkg info -e os-fritzbox-failover 2>/dev/null; then
    say INFO "Plugin ist bereits installiert: $(pkg query '%n-%v' os-fritzbox-failover). Eine Installation aktualisiert es."
else
    say INFO "Plugin ist noch nicht installiert"
fi

CODE=$(curl -sSIL -o /dev/null -w '%{http_code}' --max-time 20 "$PKG_URL" 2>/dev/null)
if [ "$CODE" = "200" ]; then
    say OK "Paket auf GitHub erreichbar"
else
    say FAIL "Paket nicht herunterladbar (HTTP $CODE). Internet/DNS pruefen oder es gibt noch kein Release."
fi

GW=$(/usr/local/opnsense/scripts/routes/gateways.php 2>/dev/null | php -r '
    $d = json_decode(stream_get_contents(STDIN), true);
    if (is_array($d)) { foreach ($d as $g) { if (!empty($g["name"])) { echo $g["name"], " (", $g["if"] ?? "?", ") "; } } }' 2>/dev/null)
if [ -n "$GW" ]; then
    say INFO "Gefundene Gateways: $GW"
else
    say WARN "Keine Gateways gefunden - bitte unter System > Gateways anlegen"
fi

for FB in 192.168.0.1 192.168.178.1; do
    if ping -c 1 -t 2 "$FB" >/dev/null 2>&1; then
        say INFO "FRITZ!Box antwortet vermutlich unter $FB"
        if curl -s -o /dev/null --max-time 3 "http://$FB:49000/tr64desc.xml"; then
            say OK "TR-064 auf $FB:49000 erreichbar"
        else
            say WARN "TR-064 auf $FB nicht erreichbar - in der FRITZ!Box 'Zugriff fuer Anwendungen zulassen' aktivieren"
        fi
        break
    fi
done
'@

$RemoteInstall = @'
set -e
TMP=/tmp/os-fritzbox-failover.pkg
echo "Lade Paket herunter ..."
fetch -o "$TMP" "__PKG_URL__"
echo "Installiere Paket ..."
env IGNORE_OSVERSION=yes ASSUME_ALWAYS_YES=yes pkg add -f "$TMP"
rm -f "$TMP"
if pkg info -e os-fritzbox-failover; then
    echo "INSTALL_OK $(pkg query '%n-%v' os-fritzbox-failover)"
else
    echo "INSTALL_FAILED"
fi
'@

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------
function Write-Title([string]$Text) {
    Write-Host ''
    Write-Host ('=' * 64) -ForegroundColor Cyan
    Write-Host " $Text" -ForegroundColor Cyan
    Write-Host ('=' * 64) -ForegroundColor Cyan
}

function ConvertTo-RemoteCommand([string]$Script) {
    $clean = ($Script -replace "`r", '').Replace('__PKG_URL__', $PkgUrl)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($clean))
    return "printf '%s' '$b64' | b64decode -r | /bin/sh"
}

function Wait-Exit([int]$Code) {
    Write-Host ''
    Read-Host 'Zum Beenden Enter druecken' | Out-Null
    exit $Code
}

function Initialize-Connection {
    if (-not (Get-Command ssh.exe -ErrorAction SilentlyContinue)) {
        Write-Host 'ssh.exe wurde nicht gefunden.' -ForegroundColor Red
        Write-Host 'Bitte unter Einstellungen > Apps > Optionale Features den "OpenSSH-Client" installieren.' -ForegroundColor Red
        Wait-Exit 1
    }
    Write-Host ''
    Write-Host 'Gib dein OPNsense-Passwort ein, wenn ssh danach fragt (die Eingabe bleibt unsichtbar).' -ForegroundColor Yellow
    Write-Host 'Beim ersten Verbinden fragt ssh evtl., ob du dem Host vertraust: mit "yes" bestaetigen.' -ForegroundColor Yellow
}

function Invoke-Remote([string]$Script) {
    $cmd = ConvertTo-RemoteCommand $Script
    $out = & ssh.exe -p $Port -o ConnectTimeout=15 -o ServerAliveInterval=10 "$UserName@$HostName" $cmd
    return [pscustomobject]@{ Output = @($out); ExitCode = $LASTEXITCODE }
}

# ---------------------------------------------------------------------------
# Ablauf
# ---------------------------------------------------------------------------
Write-Title 'FRITZ!Box Failover fuer OPNsense - Installations-Check'

if (-not $HostName) {
    $HostName = Read-Host 'IP-Adresse oder Name der OPNsense (z.B. 192.168.1.1)'
}
$HostName = $HostName.Trim()
if ($HostName -notmatch '^[A-Za-z0-9.\-:]+$') {
    Write-Host 'Ungueltige Adresse.' -ForegroundColor Red
    Wait-Exit 1
}
if (-not $UserName) {
    $UserName = Read-Host 'Benutzername [root]'
    if (-not $UserName) { $UserName = 'root' }
}
if ($UserName -notmatch '^[A-Za-z0-9._\-]+$') {
    Write-Host 'Ungueltiger Benutzername.' -ForegroundColor Red
    Wait-Exit 1
}

Write-Host ''
Write-Host "Teste Erreichbarkeit von ${HostName}:$Port ..."
$tcp = New-Object Net.Sockets.TcpClient
try {
    $ok = $tcp.ConnectAsync($HostName, $Port).Wait(5000)
} catch { $ok = $false }
$tcp.Dispose()
if (-not $ok) {
    Write-Host "Port $Port auf $HostName ist nicht erreichbar." -ForegroundColor Red
    Write-Host 'Ist SSH in der OPNsense aktiviert (System > Einstellungen > Verwaltung > Secure Shell)?' -ForegroundColor Red
    Wait-Exit 1
}

Initialize-Connection

Write-Title 'Pruefe OPNsense ...'
$res = Invoke-Remote $RemoteCheck
$fails = 0; $warns = 0; $lines = 0
foreach ($line in $res.Output) {
    if ($line -notmatch '^(OK|WARN|FAIL|INFO)\|(.*)$') { continue }
    $lines++
    switch ($Matches[1]) {
        'OK'   { Write-Host "  [ OK ]  $($Matches[2])" -ForegroundColor Green }
        'WARN' { Write-Host "  [WARN]  $($Matches[2])" -ForegroundColor Yellow; $warns++ }
        'FAIL' { Write-Host "  [FEHL]  $($Matches[2])" -ForegroundColor Red; $fails++ }
        'INFO' { Write-Host "  [INFO]  $($Matches[2])" -ForegroundColor Gray }
    }
}

if ($lines -eq 0) {
    Write-Host 'Keine Antwort von der OPNsense erhalten (falsches Passwort oder SSH-Problem?).' -ForegroundColor Red
    $res.Output | ForEach-Object { Write-Host "  $_" }
    Wait-Exit 1
}

Write-Host ''
if ($fails -gt 0) {
    Write-Host "Ergebnis: $fails Problem(e) gefunden. Das Plugin kann so NICHT installiert werden." -ForegroundColor Red
    Write-Host 'Bitte die rot markierten Punkte beheben und das Skript erneut starten.' -ForegroundColor Red
    Wait-Exit 2
}
if ($warns -gt 0) {
    Write-Host "Ergebnis: installierbar, aber mit $warns Warnung(en) (gelb)." -ForegroundColor Yellow
} else {
    Write-Host 'Ergebnis: Alles in Ordnung, das Plugin ist installierbar.' -ForegroundColor Green
}

if ($CheckOnly) {
    Wait-Exit 0
}

Write-Host ''
$a = Read-Host 'Plugin jetzt installieren? [J/n]'
if (-not ($a -eq '' -or $a -match '^[jJyY]')) {
    Write-Host 'Keine Installation durchgefuehrt.'
    Wait-Exit 0
}

Write-Title 'Installiere Plugin ...'
$res = Invoke-Remote $RemoteInstall
$res.Output | Where-Object { $_ -and $_ -notmatch '^INSTALL_' } | ForEach-Object { Write-Host "  $_" }
$done = $res.Output | Where-Object { $_ -match '^INSTALL_OK (.*)$' } | Select-Object -First 1

Write-Host ''
if ($done) {
    $ver = ($done -replace '^INSTALL_OK ', '')
    Write-Host "Fertig! $ver ist installiert." -ForegroundColor Green
    Write-Host ''
    Write-Host 'Naechste Schritte:'
    Write-Host "  1. Im Browser https://$HostName oeffnen und die Seite neu laden (Strg+F5)."
    Write-Host '  2. Dienste > FRITZ!Box Failover oeffnen.'
    Write-Host '  3. Felder ausfuellen, "Verbindung testen" und dann "Uebernehmen" klicken.'
    Wait-Exit 0
} else {
    Write-Host 'Die Installation ist fehlgeschlagen. Siehe Ausgabe oben.' -ForegroundColor Red
    Wait-Exit 3
}
