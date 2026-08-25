# Homelab Secret UI

Lokale Eingabeoberfläche für die dedizierte Codex-Admin-VM. Sie verwaltet
Passwörter, API-Schlüssel und TOTP-Seeds und ordnet sie Homelab-Systemen zu.

## Sicherheitsmodell

- Der Webdienst bindet ausschließlich an 127.0.0.1:8765.
- Datensätze werden mit Windows DPAPI für den aktuell angemeldeten Benutzer
  verschlüsselt.
- Zusätzlich beschränkt die NTFS-ACL den Speicher auf diesen Benutzer und
  SYSTEM.
- Geheimnisse werden nicht im Browser gespeichert und können nicht im Klartext
  angezeigt werden.
- Kopieren schreibt den Wert kurz in die Windows-Zwischenablage. Diese wird nach
  30 Sekunden geleert, sofern sie inzwischen nicht verändert wurde.
- Mutationen benötigen Sitzungscookie, korrekten Origin und CSRF-Token.
- Es gibt keine externen Skripte, Schriftarten, Telemetrie oder Netzwerkdienste.

Das Windows-Kennwort wird absichtlich nicht in einem Webformular abgefragt.
Die angemeldete Windows-Sitzung ist die Zugriffsgrenze; DPAPI bindet die
verschlüsselten Daten an genau diesen Windows-Benutzer.

## Start

Die Windows-Aufgabe "CodexAdmin - Homelab Secret UI" startet den Dienst beim
Anmelden von CODEX-ADMIN\Admin versteckt im Hintergrund. Danach ist die
Oberfläche jederzeit unter http://127.0.0.1:8765 erreichbar.

Die Datei Start-HomelabSecretUi.cmd öffnet die bereits laufende Oberfläche. Ist
der automatische Dienst ausnahmsweise nicht aktiv, startet sie eine sichtbare
manuelle Instanz. Im automatischen Betriebsmodus ist die Schaltfläche zum
Beenden ausgeblendet.

## Einträge verwalten

Unter einem System können beliebig viele getrennte Werte liegen, beispielsweise
Administrator-Passwort, API-Token und TOTP für denselben Proxmox-Server. Die
Schaltfläche "+ Weiterer Wert" übernimmt den Servernamen in einen neuen Eintrag.
Optional kann jeder Eintrag getrennte verschlüsselte Adressen für die interne
und externe Verbindung enthalten. Vollständige HTTP- und HTTPS-Adressen
erhalten eine sichere "Öffnen"-Verknüpfung; reine IPs und Hostnamen werden als
Text angezeigt. Bei älteren Einträgen wird die bisherige Einzeladresse
automatisch als interne Verbindung behandelt.

"Bearbeiten" lädt System, Bezeichnung, Benutzer, Typ und Hinweis zurück in das
Formular. Dazu gehören auch beide Verbindungsadressen. Das Feld für den
Geheimwert bleibt leer. Bleibt es leer, wird der
bereits verschlüsselte Wert unverändert übernommen; nur eine bewusste neue
Eingabe ersetzt ihn. Bei einem Wechsel des Geheimnistyps ist ein neuer Wert
zwingend erforderlich.

Aufgabenstatus prüfen:

    Get-ScheduledTask -TaskName 'CodexAdmin - Homelab Secret UI'

Automatischen Dienst neu starten:

    Stop-ScheduledTask -TaskName 'CodexAdmin - Homelab Secret UI'
    Start-ScheduledTask -TaskName 'CodexAdmin - Homelab Secret UI'

Autostart entfernen:

    Stop-ScheduledTask -TaskName 'CodexAdmin - Homelab Secret UI'
    Unregister-ScheduledTask -TaskName 'CodexAdmin - Homelab Secret UI'

## Lokale Daten

Die verschlüsselten Datensätze liegen außerhalb des Git-Repositories unter:

    %LOCALAPPDATA%\CodexAdmin\secret-ui

Diese Dateien dürfen nicht in Git, Tickets, Chat oder Dokumentation kopiert
werden. Eine Sicherung kann nur unter dem passenden Windows-Benutzerprofil
entschlüsselt werden; für Notfallzugriff müssen die Originalzugänge separat
gesichert bleiben.

## Entwicklung und Prüfung

Im Ordner apps\secret-ui:

    npm run build
    npm test
