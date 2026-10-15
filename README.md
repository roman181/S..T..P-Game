# NEXUS CLAW Builder AI Weboberfläche

## Start
Öffne `index.html` in einem aktuellen Browser. Für lokale Nutzung kann ein einfacher statischer Webserver verwendet werden.

## Enthalten
- Responsive Dashboard mit sechs Bereichen
- Projektkontext übernehmen
- Simulierter Entwicklungszyklus mit Start/Pause/Stopp
- 20 Gameplay-Testfälle in zwei Phasen
- Live-Logs mit Filter und TXT-Export
- Agentenmodi: Planung, Codierung, Analyse, Reparatur
- Optionaler Verbindungstest zu Ollama `/api/tags`
- Browserlokale Einstellungen
- Sicherheitshinweise für Backend/Sandbox

## Wichtige Grenzen
Diese Version ist ein Frontend-Prototyp. Projektdateien, Git, Builds, APK-Installation, echte Gameplay-Automation, Systemmetriken und autonome Reparaturen sind NICHT implementiert. Die entsprechenden Schaltflächen protokollieren den Aufruf oder zeigen einen Hinweis, statt unbemerkt externe Aktionen auszuführen.

## Nächster Architektur-Schritt
Ein lokales Backend (z. B. Python/FastAPI) sollte über klar definierte Endpunkte mit dem Frontend verbunden werden. Dateioperationen und Codeausführung gehören in eine begrenzte Sandbox/Arbeitskopie; Git-Push, APK-Installation und andere externe oder irreversible Aktionen erfordern ausdrückliche Freigabe.
