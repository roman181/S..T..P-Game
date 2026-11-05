---
name: tokenguard-handoff
version: 1.0.0
description: >
  Überwacht den Token-Verbrauch eines Agenten live und übergibt bei ~90 %
  Auslastung selbstständig einen schema-validierten JSON-Handoff an das
  nächste Modell der Fallback-Kette. Der Nutzer sieht nur das Endergebnis.
author: dein-name
license: MIT
tags: [agent, handoff, token-management, model-routing, json]
---

# TokenGuard Handoff

Ein schlanker Skill-Layer, der den Token-Verbrauch eines Agenten überwacht
und bei Erreichen einer (dynamischen) Schwelle von ~90 % einen strukturierten
JSON-Handoff an das nächste Modell erzeugt und den Modellwechsel vollautomatisch
vollzieht. Nach außen bleibt die interne Kommunikation unsichtbar – der Nutzer
erhält ausschließlich das konsolidierte Endergebnis.

---

## 1. Zweck

- **Überwachung:** Live-Tracking des Token-Verbrauchs pro Modell und Turn.
- **Trigger:** Bei ~90 % (dynamisch angepasst an Restbudget) wird ein Handoff ausgelöst.
- **Übergabe:** Schema-validiertes JSON-Paket mit priorisiertem Kontext an das nächste Modell.
- **Abstraktion:** Der Nutzer sieht nur das Resultat – nicht die interne JSON-Kommunikation.

---

## 2. Architektur

Der Skill besteht aus drei entkoppelten Modulen:

```
[TokenMonitor] ──event──► [HandoffBuilder] ──validate──► [ModelRouter]
       ▲                        │                            │
       │                        ▼                            ▼
       │                   [Journal]                    [ACK/NAK]
       │                                                     │
       └─────────────────── feedback ────────────────────────┘
```

| Modul | Aufgabe |
|---|---|
| **TokenMonitor** | Zählt Token-Events live, berechnet Auslastung, meldet Schwellen-Überschreitung. |
| **HandoffBuilder** | Erzeugt JSON-Envelope, priorisiert Kontext, validiert gegen Schema, komprimiert bei Bedarf. |
| **ModelRouter** | Wählt Zielmodell (Kosten + Verfügbarkeit), versendet JSON, prüft ACK/NAK. |

**Designprinzipien:**
- Event-basiert, nicht polling-basiert.
- Jedes Modul einzeln testbar und austauschbar.
- Fail-safe: Journaling vor Versand, Fallback-Kette bei Fehlern.

---

## 3. Konfiguration (Standard)

Die Konfiguration ist **direkt in diesem Dokument eingebettet** und kann als
`tokenguard.config.json` extrahiert oder inline verwendet werden.

```json
{
  "threshold_pct": 90,
  "warning_pct": 80,
  "dynamic_threshold": true,
  "handoff_schema": "inline",
  "schema_version": "1.0.0",
  "model_chain": ["primary-model", "fallback-model", "emergency-model"],
  "validate_handoff": true,
  "silent_mode": true,
  "audit_mode": true,
  "secret_scrubbing": true,
  "journaling": true,
  "max_handoffs_per_task": 3,
  "compression_levels": ["full", "essential", "goal-only"],
  "cost_guard": {
    "enabled": true,
    "max_cost_per_task_usd": 2.0
  },
  "timeout_ack_seconds": 30
}
```

### Felder im Detail

| Feld | Bedeutung |
|---|---|
| `threshold_pct` | Grundschwelle für Handoff (Default: 90). |
| `warning_pct` | Vorwarnschwelle (Default: 80) – berechnet Restbudget. |
| `dynamic_threshold` | Wenn `true`, wird die Schwelle anhand Restbudget ÷ geschätzte Tokens pro offenem Schritt vorgezogen. |
| `handoff_schema` | `"inline"` bedeutet: Schema ist in Abschnitt 5 dieses Dokuments eingebettet. Alternativ Pfad zu einer externen Datei. |
| `model_chain` | Geordnete Fallback-Kette; bei Trigger wird das nächste Modell gewählt. |
| `silent_mode` | Wenn `true`, sieht der Nutzer nur das Endergebnis. **Default: true.** |
| `audit_mode` | Wenn `true`, wird ein stilles Audit-Log geführt (für dich einsehbar). |
| `max_handoffs_per_task` | Schutz gegen Endlosschleifen (A→B→A→B). |
| `cost_guard` | Verhindert unkontrollierte Kosten beim Modellwechsel. |
| `timeout_ack_seconds` | Timeout für ACK/NAK vom Folge-Modell. |

---

## 4. Workflow

### Phase 0: Initialisierung (einmalig)

1. Skill lädt Konfiguration und Schema.
2. Token-Zähler startet bei null.
3. Ledger und Journal werden angelegt.

### Phase 1: Normaler Lauf

4. Agent arbeitet (Antworten, Tool-Nutzung, Reasoning).
5. Monitor empfängt Token-Events und zählt mit.
6. Bei jedem Event: Auslastung = `used / limit * 100`.

### Phase 2: Annäherung an die Schwelle

7. Bei `warning_pct` (80 %): Vorwarnung.
8. Monitor berechnet: `restbudget ÷ geschätzte_tokens_pro_offenem_schritt`.
9. Reicht das Budget **nicht** für alle offenen Schritte → Schwelle wird vorgezogen.
10. Bei `threshold_pct` (90 %) oder vorgezogener Schwelle → **Trigger**.

### Phase 3: Handoff bauen

11. Arbeitszustand einfrieren.
12. Kontext in drei Töpfe sortieren:
    - `must_know` – unverzichtbar (Ziel, Constraints, Fortschritt)
    - `nice_to_know` – nur bei Platz
    - `discarded` – was bereits versucht und verworfen wurde
13. JSON-Envelope erzeugen (siehe Abschnitt 5).
14. Schema-Validierung:
    - OK → weiter zu Schritt 16.
    - FAIL → Stufen-Kompression (`full → essential → goal-only`), dann erneut prüfen.
15. Nach `max_handoffs_per_task` erreicht → harter Abbruch mit Fehlerbericht.

### Phase 4: Übergabe

16. Secret-Scrubbing (API-Keys, PII aus dem Kontext entfernen).
17. Journaling: Handoff **vor** Versand persistieren.
18. Router wählt Zielmodell (nächste in Kette, unter Berücksichtigung von Kosten/Verfügbarkeit).
19. JSON wird an Zielmodell gesendet.
20. ACK/NAK-Prüfung:
    - **ACK** → Folge-Modell hat verstanden, weiter zu Phase 5.
    - **NAK** → Retry mit stärkerer Kompression oder nächstes Modell.
21. Timeout (`timeout_ack_seconds`) → wie NAK behandeln.

### Phase 5: Übernahme

22. Folge-Modell lädt Kontext: liest `must_know`, ignoriert `discarded`, kennt `acceptance_criteria`.
23. Arbeit wird fortgesetzt.
24. `handoff_counter += 1`.

### Phase 6: Abschluss

25. Ergebnis wird gegen `acceptance_criteria` geprüft.
26. Nur das Ergebnis wird ausgegeben (`silent_mode: true`).
27. Audit-Log wird abgeschlossen (wer → wen, warum, Tokenstand, Dauer).

### Workflow-Skizze

```
                    ┌─────────────────────────────┐
                    │   NUTZER stellt Aufgabe     │
                    └──────────────┬──────────────┘
                                   ▼
                    ┌─────────────────────────────┐
                    │   AGENT (primary-model)     │
                    └──────────────┬──────────────┘
                                   ▼
                    ┌─────────────────────────────┐
                    │  🔍 TOKEN-MONITOR           │
                    └──────────────┬──────────────┘
                        ┌──────────┴──────────┐
                   < 90 % ?               ≥ 90 % ?
                        │                     │
                        ▼                     ▼
              ┌──────────────────┐   ┌─────────────────────┐
              │ weiterarbeiten   │   │ ⚡ TRIGGER           │
              └──────────────────┘   └──────────┬──────────┘
                                                ▼
                          ┌──────────────────────────────────┐
                          │  📦 HANDOFF BUILDER              │
                          │  ✅ must_know / 💡 nice / ❌ disc │
                          └──────────────┬───────────────────┘
                                         ▼
                          ┌──────────────────────────────────┐
                          │  ✔ Schema-Validierung            │
                          └──────────────┬───────────────────┘
                              ┌──────────┴──────────┐
                           FAIL                  OK
                              ▼                    ▼
                    ┌──────────────────┐  ┌────────────────────┐
                    │ 🗜 Kompression    │  │ 🔒 Scrubbing       │
                    │                  │  │ 📓 Journaling      │
                    └────────┬─────────┘  └─────────┬──────────┘
                             └──────────┬───────────┘
                                        ▼
                          ┌──────────────────────────────┐
                          │  🚦 MODEL-ROUTER             │
                          └──────────────┬───────────────┘
                                         ▼
                          ┌──────────────────────────────┐
                          │  📨 JSON → fallback-model    │
                          └──────────────┬───────────────┘
                                         ▼
                          ┌──────────────────────────────┐
                          │  🤝 ACK / NAK                │
                          └──────────────┬───────────────┘
                              ┌──────────┴──────────┐
                            NAK                   ACK
                              ▼                    ▼
                    ┌──────────────────┐  ┌────────────────────┐
                    │ 🔁 Retry         │  │ 🧠 Folge-Modell    │
                    └──────────────────┘  └─────────┬──────────┘
                                                    ▼
                          ┌──────────────────────────────┐
                          │  ✅ Ergebnis vs. AC          │
                          └──────────────┬───────────────┘
                                         ▼
                    ┌───────────────────────────────────┐
                    │   🎁 NUTZER sieht NUR Resultat    │
                    └───────────────────────────────────┘
```

---

## 5. JSON-Handoff-Schema (v1, inline)

Dieses Schema ist die **Single Source of Truth** und wird über
`"handoff_schema": "inline"` referenziert.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "TokenGuardHandoff",
  "type": "object",
  "required": ["handoff_id", "from_model", "to_model", "trigger", "task", "meta"],
  "properties": {
    "handoff_id": { "type": "string", "format": "uuid" },
    "from_model": { "type": "string" },
    "to_model": { "type": "string" },
    "trigger": {
      "type": "object",
      "required": ["token_usage_pct", "threshold", "reason"],
      "properties": {
        "token_usage_pct": { "type": "number", "minimum": 0, "maximum": 100 },
        "threshold": { "type": "number" },
        "reason": { "enum": ["threshold", "error", "model_limit", "cost_guard"] }
      }
    },
    "task": {
      "type": "object",
      "required": ["goal", "acceptance_criteria", "context", "progress"],
      "properties": {
        "goal": { "type": "string" },
        "constraints": { "type": "array", "items": { "type": "string" } },
        "progress": { "type": "string" },
        "next_steps": { "type": "array", "items": { "type": "string" } },
        "acceptance_criteria": { "type": "array", "items": { "type": "string" } },
        "context": {
          "type": "object",
          "required": ["must_know", "discarded"],
          "properties": {
            "must_know": { "type": "array", "items": { "type": "string" } },
            "nice_to_know": { "type": "array", "items": { "type": "string" } },
            "discarded": { "type": "array", "items": { "type": "string" } },
            "open_questions": { "type": "array", "items": { "type": "string" } }
          }
        },
        "partial_results": { "type": "array", "items": { "type": "string" } },
        "confidence": { "type": "number", "minimum": 0, "maximum": 1 },
        "token_budget_remaining": { "type": "integer", "minimum": 0 }
      }
    },
    "meta": {
      "type": "object",
      "required": ["created_at", "schema_version"],
      "properties": {
        "created_at": { "type": "string", "format": "date-time" },
        "schema_version": { "type": "string" },
        "compression_level": { "enum": ["full", "essential", "goal-only"] }
      }
    }
  }
}
```

### Beispiel-Envelope

```json
{
  "handoff_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "from_model": "primary-model",
  "to_model": "fallback-model",
  "trigger": {
    "token_usage_pct": 91.2,
    "threshold": 90,
    "reason": "threshold"
  },
  "task": {
    "goal": "Analysiere die 500 Logfiles und erstelle einen Bericht.",
    "constraints": ["Nur lesen, nichts löschen", "Max. 10 Minuten Laufzeit"],
    "progress": "120 von 500 Dateien analysiert, Muster bei Zeitstempeln erkannt.",
    "next_steps": [
      "Restliche 380 Dateien analysieren",
      "Anomalien kategorisieren",
      "Bericht erstellen"
    ],
    "acceptance_criteria": [
      "Alle 500 Dateien geprüft",
      "Mindestens 3 Anomalie-Klassen identifiziert",
      "Bericht als Markdown"
    ],
    "context": {
      "must_know": [
        "Logs liegen unter /var/log/app/",
        "Format: ISO-8601 Timestamps",
        "Bekannter Fehler: 'timeout' bei Nachtstunden"
      ],
      "nice_to_know": [
        "Server-IDs beginnen mit 'srv-'",
        "Zwei verschiedene App-Versionen im Log"
      ],
      "discarded": [
        "Regex-Ansatz mit 'error.*timeout' hat zu viele False Positives ergeben",
        "Versuch, alle Dateien gleichzeitig zu laden, ist am Speicher gescheitert"
      ],
      "open_questions": [
        "Sollen Anomalien nach Schweregrad sortiert werden?"
      ]
    },
    "partial_results": [
      "Muster: 40 % der Timeouts zwischen 02:00-04:00"
    ],
    "confidence": 0.7,
    "token_budget_remaining": 2400
  },
  "meta": {
    "created_at": "2026-11-03T14:22:00Z",
    "schema_version": "1.0.0",
    "compression_level": "full"
  }
}
```

---

## 6. Fehlerbehandlung & Fallbacks

| Risiko | Maßnahme |
|---|---|
| Folge-Modell lehnt ab (NAK) | Retry mit stärkerer Kompression, dann nächstes Modell. |
| JSON zu groß für Kontextfenster | Stufen-Kompression: `full → essential → goal-only`. |
| Schema-Drift zwischen Versionen | `schema_version` im Meta; Migrations-Hook vor Validierung. |
| Endlosschleife A→B→A | `handoff_counter` + harter Abbruch nach `max_handoffs_per_task`. |
| Crash während Handoff | Journal persistiert Handoff **vor** Versand. |
| Timeout beim ACK | Wie NAK behandeln, Retry einleiten. |
| Kosten überschritten | `cost_guard` bricht ab, bevor teurer Wechsel erfolgt. |

---

## 7. Sicherheit

- **Secret-Scrubbing:** Vor jedem Handoff werden API-Keys, Tokens und PII aus dem `context`-Feld entfernt.
- **Prompt-Injection-Filter:** Fremde Inhalte im `context` werden auf eingebettete Anweisungen geprüft.
- **Kein Klartext-Speichern von Secrets** im Journal – Journal speichert nur Metadaten, nicht den vollständigen Kontext.
- **Kosten-Guard:** Modellwechsel werden nur durchgeführt, wenn das Budget es zulässt.

---

## 8. Observability

- **Handoff-Log** (append-only): wer → wen, warum, Tokenstand, Dauer, Ergebnis (ACK/NAK).
- **Metriken:**
  - Handoffs pro Task
  - Durchschnittliche Recovery-Zeit im Folge-Modell
  - Verlorene Arbeit (Retries, NAKs)
  - Kosten pro Task
- **Dry-Run-Modus:** Handoff bauen, aber **nicht** senden – zum Debuggen der JSON-Qualität.
- **Audit-Modus:** Stilles Laufen, lautes Logging. Für dich einsehbar, für den Agenten unsichtbar.

---

## 9. Nutzer-Sicht vs. System-Sicht

```
NUTZER (außen)                     SYSTEM (innen, unsichtbar)
──────────────                     ──────────────────────────
"Mach mir X"                       Agent arbeitet...
   │                               Token: 40 % → 70 % → 90 %
   │                                    │
   │                               ⚡ Handoff → JSON
   │                                    │
   │                               🔄 Modellwechsel A → B
   │                                    │
   │                               🤝 ACK
   │                                    │
   ▼                               Modell B arbeitet weiter
"Hier ist X"  ◄──────────────────────────┘
(nur Resultat)                     Audit-Log bleibt für dich
```

---

## 10. Beispiel-Aufrufe

```bash
# Skill manuell ausführen (z. B. für Tests)
tokenguard-handoff run --config ./tokenguard.config.json --task "Analysiere /var/log/app"

# Dry-Run: Handoff bauen, aber nicht senden
tokenguard-handoff run --dry-run --verbose

# Audit-Log anzeigen
tokenguard-handoff audit --task-id abc-123
```

---

## 11. MVP-Roadmap

**Phase 1 – Kern (Woche 1):**
- TokenMonitor (event-basiert)
- HandoffBuilder mit JSON-Envelope
- ModelRouter (simple Kette)
- Journaling

**Phase 2 – Robustheit:**
- Schema-Validierung
- ACK/NAK + Retry
- Stufen-Kompression

**Phase 3 – Sicherheit & Ops:**
- Secret-Scrubbing
- Kosten-Guard
- Metriken & Audit-Log
- Dry-Run-Modus

---

## 12. Designprinzipien (Kurzfassung)

1. **Der Wert liegt im Handoff-Schema**, nicht im Trigger.
2. **`must_know` vs. `discarded`** ist der eigentliche Kern – Priorisierung bei Platznot.
3. **Rückkanal ist Pflicht** – ohne ACK/NAK ist der Handoff blind.
4. **Stille nach außen, Lautstärke nach innen** – `silent_mode: true`, `audit_mode: true`.
5. **Fail-safe vor Optimierung** – Journaling und Fallbacks vor Feature-Breite.

---

## Lizenz

MIT – frei verwendbar, veränderbar, weitergebbar.