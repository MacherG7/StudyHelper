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

## D-012 SwiftData-Modelle im Package (`StudyData`), versioniertes Schema

- **Datum:** 2026-11-23
- **Status:** angenommen
- **Kontext:** Persistenz soll ohne Simulator testbar sein; die App wird per Sideloading regelmäßig neu installiert und später aktualisiert.
- **Entscheidung:** Alle `@Model`-Typen liegen im Package-Target `StudyData` (`SchemaV1` als `VersionedSchema`, leerer `StudyMigrationPlan`). Zeilen, Hervorhebungen, Metadaten, Quellenverweise und Tabellen werden als JSON-`Data` mit typisierten Accessoren gespeichert. Bilder und PDFs per `.externalStorage`. Store in `Application Support/StudyHelper/` im normalen App-Container.
- **Konsequenzen:** `swift test` prüft Persistenz auf dem Mac. JSON-Felder sind nicht in Predicates filterbar (Filtern im Speicher). Schemaänderungen nur über neue Schema-Versionen.

## D-013 Kein Share-Extension, stattdessen „Öffnen in StudyHelper“

- **Datum:** 2026-11-23
- **Status:** angenommen (Abweichung von SPEC §1)
- **Kontext:** Nur kostenloser Apple-Developer-Account (Personal Team), Installation ausschließlich per Sideloading aus Xcode. App Groups lassen sich damit nicht signieren; eine Share-Extension könnte Dateien nicht an die App übergeben.
- **Entscheidung:** Die App meldet PDF als Dokumenttyp an und übernimmt Dateien per `onOpenURL` (sofort in den eigenen Container kopiert). In Goodnotes: „Teilen → Exportieren → PDF“ → „In StudyHelper öffnen“. Keine Capabilities, die ein Personal Team nicht signieren kann (App Groups, iCloud, Push, Associated Domains).
- **Konsequenzen:** Profile laufen nach 7 Tagen ab; Daten müssen eine Neuinstallation mit gleicher Bundle-ID überstehen (MANUAL_TESTS). Mit einem bezahlten Account kann die Share-Extension später ergänzt werden.

## D-014 Erkennung: Vision-Textzeilen als Quelle, Dokument-API nur für Struktur

- **Datum:** 2026-11-23
- **Status:** angenommen
- **Kontext:** `RecognizeDocumentsRequest` (ab iOS 26) liefert Absätze, Listen und Tabellen, aber auf Handschrift niedrigere Sicherheitswerte und verschluckte Kurzzeilen.
- **Entscheidung:** Text, Sicherheit, Kandidaten und Wortboxen kommen immer aus `VNRecognizeTextRequest` (genau, Revision 3, de-DE, Sprachkorrektur an). Die Dokument-API ergänzt ab iOS 26 nur die Blockart (Liste, Tabelle, Titel); bei Goodnotes-Farbebenen wird sie übersprungen. Unsicher heißt: Sicherheit < 0,5.
- **Konsequenzen:** Unter iOS 18–25 fehlt nur die Blockart. Metadaten speichern Methode, Revision, OS-Version und Gerät pro Erkennung.

## D-015 `customWords`: immer übergeben, aber nicht darauf verlassen

- **Datum:** 2026-11-23
- **Status:** angenommen
- **Kontext:** SPEC verlangt, die Wirkung zu testen. Experiment: `docs/experiments/customWords.md`.
- **Entscheidung:** Bestätigte Fachbegriffe des Fachs werden immer als `customWords` übergeben (wirkt nur mit Sprachkorrektur). Wirkung auf dem Mac klein, aber positiv, ohne Nebenwirkungen; Umlautfehler (ü→a) werden nicht behoben.
- **Konsequenzen:** Unsichere Stellen bleiben über Sicherheitswerte und den Abgleich mit dem reduzierten PDF markiert. Auf dem Gerät erneut prüfen (MANUAL_TESTS).

## D-016 Phase-1-Umfang bei Hervorhebungen und Mehrfacherkennung

- **Datum:** 2026-11-23
- **Status:** angenommen
- **Kontext:** SPEC teilt Hervorhebungen auf Phase 1 und 3 auf und lässt den Standard der Mehrfacherkennung offen.
- **Entscheidung:** In Phase 1 erkennt die App bei Goodnotes Farbe, Textmarker, Unterstreichung, doppelte Unterstreichung und Kreis an Annotationen bzw. Strichform; bei eingebettetem PDF-Text Fett, Farbe und Unterstreichung. Hervorhebungen lassen sich in Phase 1 grundlegend bearbeiten (Art, Farbe, Bedeutung, löschen, neu anlegen); Farblegende, KI-Transkription und Bildanalyse folgen in Phase 3. Vision-Mehrfacherkennung (zweiter Durchlauf mit 0,7-facher Auflösung) ist standardmäßig **aus**.
- **Konsequenzen:** Umrandungen (Rechtecke) werden noch nicht erkannt. Schwellen der Formerkennung sind an synthetischen Strichen kalibriert und an echten Exporten zu prüfen.

## D-017 Eingang für „Öffnen in“ und App-Oberfläche Phase 1b

- **Datum:** 2026-11-23
- **Status:** angenommen
- **Kontext:** Per „Öffnen in“ übergebene PDFs dürfen weder verloren gehen noch Speicher belegen; die Prüfansicht muss bei großen Importen flüssig bleiben.
- **Entscheidung:** Eingehende PDFs werden in `Application Support/StudyHelper/Inbox` übernommen (aus dem eigenen `Documents/Inbox` verschoben, sonst kopiert). Beim Start wird der App-Eingang geleert; in `Documents/Inbox` bleiben nur Dateien jünger als 60 s (Kaltstart über „Öffnen in“). Das Import-Blatt für eingehende Dateien lässt sich nicht wegwischen; Verwerfen fragt nach. Ein Fach mit laufendem Import kann nicht gelöscht werden. Dekodierte Zeilen/Hervorhebungen werden in der UI zwischengespeichert (`DerivedValue`) statt bei jedem Rendern neu gelesen. Die Pipeline steckt in der App hinter dem Protokoll `DigitizingPipeline`, damit `ImportCoordinator` mit einem Mock getestet werden kann.
- **Konsequenzen:** Wird die App während eines offenen Imports beendet, ist die eingehende Datei beim nächsten Start weg und muss erneut geteilt werden. `TestFixtures` lässt sich in App-Tests nicht linken (Ressourcen-Bundle scheitert an der Signierung); App-Tests bauen Testdaten selbst.

## Offene Punkte (spätere Phasen)

- **NLEmbedding für Deutsch verfügbar?** Prüfen und Ergebnis hier festhalten; sonst kleines lokales Embedding-Modell (Phase 4).
- **Vision-Verhalten unter iOS 27 auf echten Geräten:** berichtete Verschlechterung des genauen Modus nur auf Geräten; Messung und Dokumentation (Phase 1, später Qualitätstest Phase 8).
- **Apple Foundation Models:** Bilder erst ab iOS 27; `tokenCount(for:)` und `contextSize` ab iOS 26.4; Verhalten auf iOS 26.0–26.3 klären (Phase 2, Phase 8).
- **Format-Erkennung echter Goodnotes-Exporte:** Reicht `/Producer` bzw. `/Creator`, oder sind strukturelle Merkmale nötig? (Phase 1; Daten aus `docs/MANUAL_TESTS.md`). Die Fixtures tragen bewusst einen synthetischen `/Producer`; die Erkennung muss daher primär strukturell arbeiten (Ink-/FreeText-/Stamp-Annotationen vs. Textebene ohne Annotationen).
