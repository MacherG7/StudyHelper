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
scripts/bump-version.sh     # vor jedem Commit: letzte Stelle der Version +1 (--set A.B.C nur nach Rückfrage, D-027)
scripts/publish.sh          # nach jedem Commit: Secret-Check, Push, Xcode-Checkout nachziehen, Beta-Release mit .ipa – nur wenn sich die App geändert hat (D-028, D-033)
scripts/beta-release.sh     # Beta v<Version> mit .ipa für den aktuellen Commit (läuft in publish.sh; zum Nachholen; --force)
scripts/publish.sh --final  # Vollversion statt Beta (nur nach Zusage des Entwicklers, D-032; vorher --dry-run)
scripts/release.sh phase-N "Phase N: …"   # bei Phasenabschluss: publish + Release-Tag
scripts/build-ipa.sh        # unsignierte .ipa nach build/ipa/ (eine signierte gibt es nicht, D-030)
scripts/beta-release.sh --source-only --tag=vA.B.C.D   # Release in distribution/source.json nachtragen (D-034)
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
scripts/                        Build-, Test- und Hilfsskripte (Python-Tests in scripts/tests/)
distribution/                   Source für SideStore/AltStore/StikStore (source.json, Icon, README)
docs/                           Spezifikation, Plan, Phasen, Entscheidungen, manuelle Tests
```

## Konventionen

- Alle App-IDs enden auf 1 (`MiloG.StudyHelper1`, `…Tests1`, `…UITests1`). Das Team RL9PPXX5GV in
  `project.yml` nutzt nur Xcode, wenn die App direkt aus Xcode auf dem eigenen Gerät läuft; andere installierte
  Teams nicht verwenden.
- Eine .ipa wird nie signiert, auch nicht lokal: Eine signierte .ipa enthält die Apple-ID (E-Mail) des
  Entwicklerzertifikats. `scripts/build-ipa.sh` baut immer unsigniert; installiert wird mit SideStore, AltStore,
  StikStore oder Sideloadly. Auf dem eigenen Gerät ohne diese Apps: aus Xcode starten (D-030).
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
- Keine E-Mail-Adressen in Dateien, Commits, Tags oder Releases (auch nicht die des Entwicklers, D-030).
- Neue Entscheidungen in `docs/DECISIONS.md`, neue Geräte-Prüfpunkte in `docs/MANUAL_TESTS.md`.
- App-Version A.B.C.D (`project.yml`, Anzeige in den Einstellungen): vor **jedem** Commit
  `scripts/bump-version.sh` (D +1). Wäre ein Commit ein größeres Release oder eine Test-Beta, dem Entwickler
  vorschlagen, ihn als größere Version (`--set A.B.C`) zu veröffentlichen, und erst nach Zustimmung setzen.
- Beta oder Vollversion (D-032): Jedes automatische Release ist eine Beta („StudyHelper 1.0 Beta N“, App zeigt „(Beta)“).
  Eine Vollversion ist dieselbe Version mit dem nächsten Build (nie Build 0), veröffentlicht mit
  `scripts/publish.sh --final` als normales Release „StudyHelper 1.0“ plus Tag `v1.0.0` – nur wenn der
  Entwickler es sagt. Danach `--set 1.0.1` (Fehlerkorrekturen) bzw. `--set 1.1.0` (neue Funktionen), nach Rückfrage.
- Ein Commit pro abgeschlossener Phase (bei großen Phasen pro Teilschritt). Nach **jedem** Commit
  `scripts/publish.sh` (GitHub `MacherG7/StudyHelper`, öffentlich; Branch `main`; danach automatisch Beta-Release
  `v<Version>` mit der auf dem Mac gebauten, unsignierten .ipa, sofern sich die App geändert hat), nach jeder
  fertigen Phase
  `scripts/release.sh`. Das Repository `StudyHelper-Test` nie anfassen. Der Haupt-Checkout
  (für Xcode; erster Eintrag von `git worktree list`) wird per Fast-Forward nachgezogen; der Hook
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
  Verteilung über eine Source für SideStore, AltStore und StikStore vorbereitet (D-024,
  `distribution/README.md`). Das Repository ist öffentlich; die Source liegt in `distribution/source.json`, jedes
  Release trägt sich dort selbst ein (D-034).
  Formpfeile in Zeilen werden als „→“ eingesetzt, Nachlesen zeilentreu (D-025, F1 0,9625 mit S. 9 als
  Referenz). Unterstreichungen ohne vermutete Bedeutung, Nutzer oder KI entscheidet (D-026).
  App-Version 0.0.1.x in den Einstellungen, letzte Stelle pro Commit (D-027); jeder Commit mit
  Änderungen an der App wird als Beta-Release v<Version> mit .ipa auf GitHub veröffentlicht (D-028, D-033); die Einstellungen zeigen auch den
  Commit (D-029). Beta/Vollversion als Markierung, `publish.sh --final` (D-032).
- **Offen aus Phase 1:** Geräteprüfungen MT-1.1–1.48 und MT-S.1–S.7 in `docs/MANUAL_TESTS.md` (macht der Entwickler).
- **Nächster Schritt:** Phase 2 planen (Anbieter-Protokoll mit Metadaten, Reasoning, Streaming,
  Mock-Modell, Apple Foundation Model, OpenAI-kompatibel, Claude- und OpenAI-API, Anfrage-Logs).
  API-Parameter aus der aktuellen offiziellen Doku. Agenten nacheinander starten und danach auf
  zurückgelassene Prozesse/Simulatoren prüfen.
