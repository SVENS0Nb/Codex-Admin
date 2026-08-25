$homelab-admin

Arbeite ausschließlich im lokalen Projekt `C:\Codex-Admin`.
Lies zu Beginn `AGENTS.md`, `inventory/services.json`,
`config/admin-policy.json` und `config/knowledge-policy.json` und rufe danach
`homelab_admin.context_bootstrap` auf. Verwende denselben global konfigurierten
`homelab_admin`-Server und dieselbe secret-free lokale SQLite-Wissensdatenbank
`%LOCALAPPDATA%\CodexAdmin\homelab\homelab-ops.sqlite3` wie der interaktive
System-Admin-Agent.

Dieser 18:10-Heartbeat liefert den bereits um 18:00 von der lokalen Job Engine
erzeugten Tagesreport in den bestehenden Codex-Task. Starte
`scripts/Invoke-HomelabDailyLogReview.ps1` nicht erneut. Prüfe read-only den
heutigen Auditlauf von `Homelab daily log review`, lies anschließend
`%LOCALAPPDATA%\CodexAdmin\homelab\reports\latest.md` und akzeptiere den Report
nur, wenn Run-ID, Datum und Audit einen erfolgreichen heutigen Lauf belegen.
Läuft der Job noch, prüfe in kurzen Abständen weiter, höchstens bis 18:30 Uhr.

Nutze für die Analyse die gemeinsamen read-only Werkzeuge
`knowledge_statistics`, `knowledge_search`, `incident_search`,
`system_context_get`, `inventory_get`, `admin_policy_get`,
`service_tcp_check` sowie Shell-Lesezugriffe auf Projekt, Reports und
Job-Engine-State. Suche bei relevanten Findings nach früheren Symptomen und
Lösungen. Verifiziere zeitkritische Zustände trotzdem live.

Veröffentliche alle benutzerrelevanten Ergebnisse vollständig im bestehenden
Task. Beginne mit Gesamtstatus und Anzahl der Findings; die Systemübersicht ist
die erste Sektion. Danach folgen Kurzfazit, Handlungsbedarf, interne Beobachtung,
erfolgreich geprüfte Ereignisse, Abdeckung und Laufdetails. Melde Fehlläufe,
fehlende Quellen und veraltete oder unvollständige Reports ausdrücklich als
Abdeckungs- beziehungsweise Zustellungslücke.

Strikte Sicherheitsgrenze: gegenüber der Infrastruktur ausschließlich lesen,
bereinigen, korrelieren, analysieren und berichten. Keine Reparatur, kein
Neustart, kein Update, keine Konfigurationsänderung, keine Alarmbestätigung,
keine Loglöschung und keine andere bestätigungspflichtige Mutation. Jede
vorgeschlagene Maßnahme wartet auf separate ausdrückliche Bestätigung in einem
interaktiven Task. Niemals Passwörter, Tokens, Cookies, OTP-Werte,
Recovery-Codes, private Schlüssel oder Authorization-Header ausgeben oder
speichern.
