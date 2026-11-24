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
SKIP_VISION_TESTS=1 scripts/test.sh   # ohne Tests mit echter Vision-Texterkennung
scripts/make-fixtures.sh    # synthetische Goodnotes-Test-PDFs neu erzeugen
scripts/check-secrets.sh    # nach API-Keys in Dateien suchen
scripts/bench-recognition.sh v2 --baseline v1   # Erkennung auf LocalSamples/ messen und vergleichen (D-022)
scripts/publish.sh          # nach jedem Commit: Secret-Check, Push nach GitHub, Xcode-Checkout nachziehen
scripts/release.sh phase-N "Phase N: …"   # bei Phasenabschluss: publish + Release-Tag
scripts/build-ipa.sh        # signierte Development-.ipa nach build/ipa/ (für Beta-Releases auf GitHub)
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

- Signieren immer mit dem Xcode-Account <Apple-ID> (Team RL9PPXX5GV, kostenlos); alle App-IDs
  enden auf 1 (`MiloG.StudyHelper1`, `…Tests1`, `…UITests1`). Andere installierte Teams nicht verwenden.
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
- Ein Commit pro abgeschlossener Phase (bei großen Phasen pro Teilschritt). Nach **jedem** Commit
  `scripts/publish.sh` (GitHub `MacherG7/StudyHelper`, privat; Branch `main`), nach jeder fertigen Phase
  `scripts/release.sh`. Das Repository `StudyHelper-Test` nie anfassen. Der Haupt-Checkout
  `/Users/milogotz/Documents/StudyHelper` (für Xcode) wird per Fast-Forward nachgezogen; der Hook
  `scripts/git-hooks/post-merge` erzeugt dort das Xcode-Projekt neu (`git config core.hooksPath scripts/git-hooks`).

## Stand

Vor Sitzungsende oder bei knappem Kontext hier aktualisieren.

- **Fertig:** Phase 0 und Phase 1 (1a Datenmodell/Import/Erkennung, 1b Fächer/Import-UI/Prüfansicht/
  „Öffnen in“, 1c manuelle Strukturierung mit Quellenverweisen, „Quelle geändert“, Bestätigung).
  Kostenloser Developer-Account: keine Share-Extension/App Groups (D-013).
  Nach Gerätetest: übergangene Handschrift wird zeilenweise nachgelesen, Schriftprüfung (D-019),
  nachgelesene Zeilen sind „unsicher“ (D-020). Erkennung an der echten Testdatei gemessen und verbessert
  (D-022: Text in Bildern/Stamps, unterstrichene Zeilen, dichte Zeilen; F1 0,78 → 0,97). Bekannte Grenze:
  einzelne Ziffern neben Strichen bleiben unleserlich; Fotos nur mit Schriftprüfung.
  Zusammenhängende Zeilen werden als Absätze gespeichert (`paragraphID` je Zeile, D-023).
- **Offen aus Phase 1:** Geräteprüfungen MT-1.1–1.44 in `docs/MANUAL_TESTS.md` (macht der Entwickler).
- **Nächster Schritt:** Phase 2 planen (Anbieter-Protokoll mit Metadaten, Reasoning, Streaming,
  Mock-Modell, Apple Foundation Model, OpenAI-kompatibel, Claude- und OpenAI-API, Anfrage-Logs).
  API-Parameter aus der aktuellen offiziellen Doku. Agenten nacheinander starten und danach auf
  zurückgelassene Prozesse/Simulatoren prüfen.
