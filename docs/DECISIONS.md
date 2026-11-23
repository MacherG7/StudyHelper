# StudyHelper – Entscheidungsprotokoll

Format: Datum · Status (angenommen / offen) · Kontext · Entscheidung · Konsequenzen. Neue Einträge am Ende anhängen, bestehende nicht löschen, sondern Status ändern bzw. durch einen neuen Eintrag ersetzen.

## D-001 XcodeGen ersetzt das Xcode-27-Projektformat

- **Datum:** 2026-11-23
- **Status:** angenommen
- **Kontext:** Das Xcode-Template (Xcode 27) nutzt das neue `project.xcproj`-Format; es ist schwer diffbar und für Skripte/Agenten schlecht pflegbar.
- **Entscheidung:** Das Projekt wird in `project.yml` beschrieben und mit XcodeGen erzeugt. Das generierte `.xcodeproj` wird nicht committet (`.gitignore`); `scripts/bootstrap.sh` erzeugt es. Das alte Projekt wird per `git rm` entfernt.
- **Konsequenzen:** Jede Projektänderung läuft über `project.yml`. Vor Build/Test ist `scripts/bootstrap.sh` nötig. Xcode-Einstellungen, die nur in der IDE geändert werden, gehen beim nächsten Generieren verloren.

## D-002 XcodeGen-Installation

- **Datum:** 2026-11-23
- **Status:** angenommen
- **Kontext:** `brew install xcodegen` scheitert: Die Homebrew-Installation unter `/usr/local` läuft unter Rosetta (x86_64), für macOS 27 gibt es kein Bottle, und die Command Line Tools sind für ein Bauen aus dem Quellcode zu alt. Alternativen waren ein Tool-Package im Repo, ein selbst gebautes oder ein vorgebautes Binary.
- **Entscheidung:** Der Entwickler aktualisiert die Command Line Tools für macOS 27 selbst und installiert XcodeGen danach per `brew install xcodegen`. XcodeGen wird global im `PATH` erwartet.
- **Konsequenzen:** `scripts/common.sh` (`require_xcodegen`) prüft, ob `xcodegen` vorhanden ist, und bricht sonst mit einem Hinweis auf diesen Eintrag ab. Die Package-Tests (`scripts/test.sh --core`) laufen auch ohne XcodeGen.

## D-003 Plattform: iOS 18 Minimum, iPhone + iPad

- **Datum:** 2026-11-23
- **Status:** angenommen
- **Kontext:** Das Template zielte auf iOS 27.2 sowie Mac und visionOS; die Spezifikation verlangt iOS 18 als Mindestversion.
- **Entscheidung:** `deploymentTarget` iOS 18.0, `TARGETED_DEVICE_FAMILY "1,2"` (iPhone + iPad). Kein Mac-, kein visionOS-Ziel.
- **Konsequenzen:** Neuere APIs (Foundation Models ab iOS 26, `RecognizeDocumentsRequest` ab iOS 26, Bilder im On-Device-Modell ab iOS 27) nur hinter `#available`.

## D-004 Swift 6 und Actor-Isolation

- **Datum:** 2026-11-23
- **Status:** angenommen
- **Kontext:** Das Template nutzte Swift 5; Xcode 27 bietet Default-Actor-Isolation und Approachable Concurrency.
- **Entscheidung:** Swift-6-Sprachmodus überall. App-Target mit `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` und `SWIFT_APPROACHABLE_CONCURRENCY`. Package-Code ist nicht MainActor-gebunden.
- **Konsequenzen:** Package-Typen sind explizit `Sendable` bzw. nutzen eigene Isolation und bleiben auf dem Mac testbar. Brücken zwischen App und Package müssen Isolation bewusst deklarieren.

## D-005 Modulschnitt des Core-Packages, macOS als Zusatzplattform

- **Datum:** 2026-11-23
- **Status:** angenommen
- **Kontext:** Fachlogik soll schnell und ohne Simulator testbar sein.
- **Entscheidung:** `Packages/StudyHelperCore` mit `StudyCore` (nur Foundation), `TestFixtures` (nur Tests), `make-fixtures`; später `StudyData`, `StudyImport`, `StudyAI` (siehe `docs/PLAN.md`). Das Package führt zusätzlich `.macOS(.v15)`, **nur** damit `swift test` direkt auf dem Mac läuft; die App selbst ist iOS-only.
- **Konsequenzen:** Code in `StudyCore` darf keine iOS-only-APIs nutzen. Plattformabhängige Module (Vision, VisionKit, UIKit) werden mit `#if canImport` bzw. passenden Plattformbedingungen gehalten.

## D-006 Synthetische Goodnotes-Fixtures mit eigenem PDF-Writer

- **Datum:** 2026-11-23
- **Status:** angenommen
- **Kontext:** PDFKit/CGPDFContext erlauben keine volle Kontrolle über `/InkList`, `/C`, `/BS /W` und `/AP`. Echte Goodnotes-Dateien dürfen nicht ins Repo.
- **Entscheidung:** Eigener minimaler PDF-Writer (`TestFixtures/PDFWriter.swift`), deterministisch (keine Zeitstempel) und unkomprimiert. Pro PDF ein Ground-Truth-JSON (Wort, Farbe, Strichbreite, Bounding Box, Hervorhebungsart, bewusste Erkennungsfehler).
- **Konsequenzen:** Reproduzierbare, diffbare Fixtures; Tests lesen die PDFs roh über `CGPDFDocument`. Der Writer muss gepflegt werden; ein Drift-Test vergleicht mitgelieferte mit frisch erzeugten Dateien.

## D-007 Synthetische Handschrift aus Glyphen-Umrissen

- **Datum:** 2026-11-23
- **Status:** angenommen
- **Kontext:** Für Vision-/Parser-Tests wird handschriftähnlicher Ink gebraucht.
- **Entscheidung:** Glyphen-Umrisse einer Handschrift-Systemschrift (Noteworthy, Fallback Helvetica) per CoreText, Kurven zu Punktlisten abgeflacht; jeder Teilpfad (Kontur) wird eine eigene Ink-Annotation mit genau einem `/InkList`-Eintrag (siehe D-008).
- **Konsequenzen:** **Risiko:** Umriss-Schrift ist keine echte Handschrift (keine Strichreihenfolge, andere Geometrie, Erkennungsraten nicht übertragbar). Parser-Struktur ist testbar, die Erkennungsqualität nicht. Echte Exporte werden manuell geprüft (`docs/MANUAL_TESTS.md`).

## D-008 Ink- und Textmarker-Modell der Fixtures

- **Datum:** 2026-11-23
- **Status:** angenommen
- **Kontext:** Annahmen zur Goodnotes-Struktur stammen aus der Analyse des Nutzers (siehe SPEC, Abschnitt Goodnotes-Import).
- **Entscheidung:** Ein Strich = eine Ink-Annotation. Textmarker = gelbe Ink-Annotation, Breite ca. 18 pt, Blend-Modus Multiply im Appearance Stream.
- **Konsequenzen:** Ob echte Goodnotes-Exporte stattdessen `/CA` (Transparenz) oder einen Blend-Mode setzen, ist ungeklärt; der Parser darf sich nicht auf eine Variante festlegen. Prüfung: `docs/MANUAL_TESTS.md`.

## D-009 Sprachregelung

- **Datum:** 2026-11-23
- **Status:** angenommen
- **Kontext:** Deutsche Schüler als Nutzer, englischsprachige Tooling-Umgebung.
- **Entscheidung:** UI und Dokumentation auf Deutsch; Code-Bezeichner und Code-Kommentare auf Englisch; Testnamen (Swift Testing `displayName`) auf Deutsch.
- **Konsequenzen:** String Catalog mit Quellsprache `de`; `developmentLanguage: de` in `project.yml`.

## D-010 Kein iOS-18-Simulator lokal

- **Datum:** 2026-11-23
- **Status:** angenommen
- **Kontext:** Installiert sind nur Simulatoren mit iOS 27.2; die Mindestversion iOS 18 lässt sich lokal nicht in einer Runtime ausführen.
- **Entscheidung:** Die Mindestversion wird über `#available`-Pfade (Compiler prüft Verfügbarkeit gegen das Deployment-Target 18.0) und eine manuelle Prüfung auf einem iOS-18-Gerät oder einer nachinstallierten Runtime abgesichert.
- **Konsequenzen:** Laufzeitfehler, die nur unter iOS 18 auftreten, werden erst in der manuellen Prüfung entdeckt (`docs/MANUAL_TESTS.md`, Abschnitt Mindestversion).

## D-011 Secrets und lokale Beispiele

- **Datum:** 2026-11-23
- **Status:** angenommen
- **Kontext:** Keine API-Keys, Tokens oder persönlichen Daten im Repo; echte Goodnotes-Exporte sollen lokal prüfbar bleiben.
- **Entscheidung:** Keys nur in der Keychain. `scripts/check-secrets.sh` (Key-Muster in getrackten Dateien) läuft in `scripts/test.sh`. `LocalSamples/` (gitignored) für eigene echte Exporte; ebenfalls ignoriert: `*.goodnotes`, `*.env`, `Secrets*.xcconfig`, Zertifikate.
- **Konsequenzen:** Das Muster-Grep ist eine Heuristik, kein Ersatz für Sorgfalt. Tests nutzen nur Mock-Modelle.

## Offene Punkte (spätere Phasen)

- **NLEmbedding für Deutsch verfügbar?** Prüfen und Ergebnis hier festhalten; sonst kleines lokales Embedding-Modell (Phase 4).
- **Wirkung von `customWords` bei Vision:** testen und dokumentieren (Phase 1).
- **Vision-Verhalten unter iOS 27 auf echten Geräten:** berichtete Verschlechterung des genauen Modus nur auf Geräten; Messung und Dokumentation (Phase 1, später Qualitätstest Phase 8).
- **Apple Foundation Models:** Bilder erst ab iOS 27; `tokenCount(for:)` und `contextSize` ab iOS 26.4; Verhalten auf iOS 26.0–26.3 klären (Phase 2, Phase 8).
- **Ort der SwiftData-Modelle (Package `StudyData` vs. App-Target):** final in Phase 1 entscheiden, inkl. Auswirkung auf Share-Extension und Tests.
- **Format-Erkennung echter Goodnotes-Exporte:** Reicht `/Producer` bzw. `/Creator`, oder sind strukturelle Merkmale nötig? (Phase 1; Daten aus `docs/MANUAL_TESTS.md`). Die Fixtures tragen bewusst einen synthetischen `/Producer`; die Erkennung muss daher primär strukturell arbeiten (Ink-/FreeText-/Stamp-Annotationen vs. Textebene ohne Annotationen).
