# StudyHelper – Hinweise für Claude

iOS-App für Schüler: Lernstoff (Fotos, PDFs, Goodnotes-Exporte) wird einmalig
digitalisiert, dauerhaft als Text mit Hervorhebungen gespeichert, in Themen
strukturiert und mit KI-Abfragen, Chat und Karteikarten gelernt.

- Anforderungen (Quelle der Wahrheit): `docs/SPEC.md`
- Architektur: `docs/PLAN.md` · Phasen und Abnahme: `docs/PHASES.md`
- Entscheidungen: `docs/DECISIONS.md` · Geräte-Prüfungen: `docs/MANUAL_TESTS.md`

## Oberste Regel

**Nur Inhalte aus dem Lernstoff.** Jede KI-Aufgabe nutzt ausschließlich den
importierten Lernstoff; Lücken füllt die KI nur als markierte, vom Nutzer
einzeln zu bestätigende „KI-Ergänzung“. Diese Regel ist fester, nicht
editierbarer Teil jedes System-Prompts und wird technisch geprüft
(Quellenverweise). Details: `docs/SPEC.md`, Abschnitt „Grundregel“.

## Befehle

```bash
scripts/bootstrap.sh        # StudyHelper.xcodeproj aus project.yml erzeugen (XcodeGen)
scripts/build.sh            # App für den iOS-Simulator bauen (--ipad: iPad-Ziel)
scripts/test.sh             # Secret-Check, Package-Tests (Mac + Simulator), App-Unit-Tests
scripts/test.sh --core      # nur Secret-Check + Package-Tests auf dem Mac (schnell, ohne XcodeGen)
scripts/test.sh --ui        # zusätzlich XCTest-UI-Tests
scripts/make-fixtures.sh    # synthetische Goodnotes-Test-PDFs neu erzeugen
scripts/check-secrets.sh    # nach API-Keys in Dateien suchen
```

Simulator: `SIM_DEVICE` (Standard „iPhone 17“), iPad: `IPAD_DEVICE`.
Das `.xcodeproj` ist generiert und nicht im Repo – nach Änderungen an
`project.yml` oder neuen Dateien `scripts/bootstrap.sh` ausführen.

## Struktur

```
project.yml                     XcodeGen-Spezifikation
StudyHelper/                    App-Target (SwiftUI, nur UI und Navigation)
StudyHelperTests/               App-Unit-Tests (Swift Testing)
StudyHelperUITests/             UI-Tests (XCTest)
Packages/StudyHelperCore/       Swift-Package
  Sources/StudyCore/            Kernlogik, nur Foundation
  Sources/TestFixtures/         synthetische Goodnotes-PDFs + Ground Truth (nur Tests)
  Sources/make-fixtures/        Generator für die Fixtures
scripts/                        Build-, Test- und Hilfsskripte
docs/                           Spezifikation, Plan, Phasen, Entscheidungen, manuelle Tests
```

## Konventionen

- iOS 18 Minimum, iPhone + iPad, SwiftUI, SwiftData. Swift 6 Sprachmodus;
  App-Target mit Default-Isolation `MainActor`, Package-Code nicht.
- Unit-Tests mit Swift Testing, XCTest nur für UI-Tests. Testnamen (`@Test("…")`) auf Deutsch.
- Tests rufen nie echte Modelle oder APIs auf – nur das Mock-Modell.
- API-Keys nur in der Keychain; nie in UserDefaults, Code, Logs oder im Repo.
  `scripts/check-secrets.sh` läuft in `scripts/test.sh`.
- Keine echten Goodnotes-Dateien im Repo. Eigene Exporte nur in `LocalSamples/` (ignoriert).
- App-Sprache und Doku Deutsch; Code-Bezeichner und Code-Kommentare Englisch.
- Apple Foundation Models nur hinter `#available(iOS 26, *)` und nach Prüfung von
  `SystemLanguageModel.default.availability`.
- KI-Ausgaben strukturiert anfordern und robust parsen; fehlerhafte Ausgaben dürfen nie abstürzen.
- API-Parameter (Modelle, Reasoning, Usage, Streaming) aus der aktuellen offiziellen
  Doku von Anthropic und OpenAI, nicht aus dem Gedächtnis.
- Neue Entscheidungen in `docs/DECISIONS.md`, neue Geräte-Prüfpunkte in `docs/MANUAL_TESTS.md`.
- Ein Commit pro abgeschlossener Phase (bei großen Phasen pro Teilschritt), nur lokal.

## Stand

Vor Sitzungsende oder bei knappem Kontext hier aktualisieren.

- **Fertig:** Phase 0 – XcodeGen-Projekt (iOS 18, iPhone + iPad), Core-Package
  (`StudyCore`, `TestFixtures`, `make-fixtures`), 4 synthetische Goodnotes-PDFs mit
  Ground Truth und 36 Strukturtests, Skripte, Doku. `scripts/test.sh --ui` grün.
- **In Arbeit:** –
- **Nächster Schritt:** Phase 1 planen (Datenmodell, Import, Vision-Digitalisierung,
  Prüfansicht, manuelle Strukturierung). Offene Spec-Unklarheiten sammeln, bevor geplant wird.
