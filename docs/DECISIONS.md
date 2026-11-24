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

## D-018 Themen: Bestätigung, Herkunft und Quellenänderungen (Phase 1c)

- **Datum:** 2026-11-24
- **Status:** angenommen
- **Kontext:** SPEC §5: Ein Thema darf erst nach Bestätigung gelernt werden; jeder Inhalt verweist auf seine Quelle; nach Korrekturen der Digitalisierung bietet die App an, betroffene Themen zu aktualisieren.
- **Entscheidung:** Lernbereit ist ein Thema nur, wenn es bestätigt und seit der Bestätigung nicht geändert wurde (`modifiedAt == nil`). Wird ein unbestätigtes Thema in ein bestätigtes zusammengelegt, ist das Ziel wieder unbestätigt. Wird der Text eines Original-Eintrags bearbeitet, wird er zur „Eigenen Eingabe“, behält aber seinen Quellenverweis; ohne Quellenverweis kann ein Eintrag nicht „Original“ sein. Eine Hervorhebung wird einem übernommenen Eintrag nur zugeordnet, wenn sie mindestens die Hälfte der übernommenen Wörter abdeckt. Ändert sich die Quelle eines Eintrags (Korrektur, Neuerkennung, Version wiederhergestellt, Hervorhebung bearbeitet), markiert die App den Eintrag mit „Quelle geändert“ und bietet „Text aus Quelle übernehmen“ oder „Ignorieren“ an.
- **Konsequenzen:** Lernmodi (ab Phase 5) dürfen nur lernbereite Themen verwenden. Löschen eines Imports nennt die betroffenen Themen; deren Einträge zeigen danach „Quelle nicht mehr vorhanden“.

## D-019 Nachlesen übergangener Handschrift (Befund an echtem Goodnotes-Export)

- **Datum:** 2026-11-24
- **Status:** angenommen
- **Kontext:** Auf einem echten Export (17 Seiten) hat Vision auf der ganzen Seite dichte Handschriftzeilen ausgelassen (z. B. drei Zeilen am Stück) und vereinzelt mehrere Zeilen zu einer Beobachtung mit niedriger Sicherheit und fremden Schriftzeichen verschmolzen. Die Unleserlich-Erkennung fasste die übrige Tinte zu mehrzeiligen Kästen zusammen.
- **Entscheidung:** Nach dem ersten Durchgang wird nicht erklärte Tinte je Stiftfarbe in Textzeilen und Abschnitte zerlegt, einzeln gerendert und noch einmal erkannt (Maßstab 3, sonst 4,5; höchstens `retryCropLimit` = 40 Aufrufe pro Seite). Verdächtige Zeilen (höher als 1,8 Zeilenhöhen und unsicher, fremde Schrift oder mehrere Tintenzeilen) werden verworfen und zeilenweise nachgelesen. Eine Schriftprüfung (`ScriptGuard`) ersetzt Zeilen mit nicht-lateinischen Zeichen durch eine lateinische Alternative oder markiert sie als unsicher. „Unleserlich“ entsteht nur noch je Textzeile.
- **Konsequenzen:** Etwa 5–10 % mehr Rechenzeit pro Seite. Sehr eng gestapelte Listen mit Ziffernspalten werden teilweise noch nicht gelesen. Für Fotos gibt es bisher nur die Schriftprüfung. Die Testdatei bleibt lokal in `LocalSamples/`.

## D-020 Nachgelesene Zeilen sind „unsicher“

- **Datum:** 2026-11-24
- **Status:** angenommen (Entscheidung des Entwicklers)
- **Kontext:** Zeilen aus dem Nachlesen (D-019) behalten Visions Sicherheit, die Textqualität im Ausschnitt ist aber oft nur mittelmäßig („Teilberreichen“, „wusserbauliche“). Ohne Markierung fallen sie in der Prüfansicht nicht auf.
- **Entscheidung:** Jede Zeile, die erst beim Nachlesen erkannt wurde, ist mindestens „unsicher“ mit dem Prüfgrund `reReadSeparately`. Die Wörter behalten ihren eigenen Status, damit innerhalb der Zeile nur zweifelhafte Wörter markiert sind.
- **Konsequenzen:** Mehr offene Stellen in der Prüfansicht (auf der Testdatei 11 von 266 Zeilen). Eine Korrektur oder Bestätigung durch den Nutzer hebt die Markierung wie bei anderen unsicheren Zeilen auf.

## D-021 GitHub-Repository und lokaler Xcode-Checkout

- **Datum:** 2026-11-24
- **Status:** angenommen (Wunsch des Entwicklers)
- **Kontext:** Bisher blieben alle Commits lokal im Worktree; Xcode öffnete einen veralteten Haupt-Checkout.
- **Entscheidung:** Privates Repository `MacherG7/StudyHelper`, Branch `main`. Nach jedem Commit pusht `scripts/publish.sh` (mit Secret-Check) und zieht den Haupt-Checkout per Fast-Forward nach; ein `post-merge`/`post-checkout`-Hook erzeugt dort das Xcode-Projekt neu. Jede fertige Phase bekommt mit `scripts/release.sh` einen Tag `phase-N` (rückwirkend: `phase-0`, `phase-1`). Das Repository `StudyHelper-Test` wird nicht verwendet.
- **Konsequenzen:** Ohne `gh` gibt es nur Tags, keine Release-Seiten; mit installiertem und angemeldetem `gh` legt `release.sh` sie mit an. Lokale Änderungen im Haupt-Checkout (z. B. von Xcode ergänzte Texte im String-Katalog) können das Nachziehen blockieren; das Skript meldet das.

## D-022 Erkennung an echten Notizen messen und nur Verbesserungen übernehmen

- **Datum:** 2026-11-24
- **Status:** angenommen (Wunsch des Entwicklers)
- **Kontext:** Auf dem echten Export `LocalSamples/GPG_bearbeitbar.pdf` fehlten Wörter („Geosphären“), unterstrichene Wörter wurden falsch gelesen („ikhdrom“ statt „Syndrom“), eingefügte Bilder und eingescannte Arbeitsblätter wurden gar nicht erkannt, und die dichte Länderliste auf S. 8 blieb lückenhaft.
- **Entscheidung:** Jede Änderung der Erkennung wird mit `scripts/bench-recognition.sh <name> --baseline <vorher>` gemessen: echte Pipeline mit Vision auf der lokalen Datei, Vergleich mit einem lokal abgelesenen Referenztext (`*.reference.json`, nie im Repo) per unscharfem Wortabgleich (F1). Übernommen wird nur, was keine Referenzseite verschlechtert und F1 erhöht, oder bei gleichem F1 weniger unmarkierte Fremdzeichen, „unleserlich“- oder „unsicher“-Markierungen bringt; Seiten ohne Referenz werden auf verlorenen Text geprüft. So übernommen (F1 0,777 → 0,969):
  1. **Text in Bildern:** Rasterbilder des Seiteninhalts und Stamp-Annotationen mit Rasterbild (so legt Goodnotes eingefügte Bilder ab; Pfeile sind Stamps ohne Bild) werden ohne Handschrift gerendert, einzeln ausgeschnitten und als Drucktext erkannt (`recognizesImageText`, Standard an). Gilt auch für PDFs mit Textebene.
  2. **Erklärte Tinte:** Ein Strich gilt nur dann als von einem Wort/einer Zeile erklärt, wenn mindestens die Hälfte seiner Höhe im Kasten liegt (flache Striche: Nähe genügt). Sonst „verschluckt“ eine dichte Zeile ein übersprungenes Wort der Zeile darüber.
  3. **Unterstrichene Zeilen** (langer, flacher, gerader Strich in der unteren Zeilenhälfte) werden im Ausschnitt ohne Unterstrich nachgelesen (`rereadsUnderlinedLines`). Unterscheidet sich die Lesung um höchstens einen Buchstaben, bleibt die erste Lesung unverändert und sicher.
  4. **Schriftprüfung** auch für lateinische Buchstaben jenseits von Latin-1 (ą, ę, ś, ạ …; erlaubt bleiben Œ, Š, Ž, ẞ).
  5. **Dichte Zeilen:** Liefert ein Ausschnitt eine zu hohe Zeile, wird er vergrößert erneut gelesen; bleibt ein hoher Ausschnitt leer, wird er an der dünnsten Stelle geteilt und jede Hälfte einzeln gelesen.
  6. **„z.ß“/„2.ß.“ → „z.B.“** (die alte Lesung bleibt als Alternative).
  Verworfen (nicht besser): zweiter Leseversuch ohne Sprachkorrektur.
- **Konsequenzen:** Einzelne Ziffern neben Strichen (S. 8) bleiben „unleserlich“ – so gewollt: was sich nicht lesen lässt, wird nicht geraten. Die Referenz deckt nur vier Seiten ab; die Regeln sind deshalb allgemein gehalten und durch Unit-Tests abgesichert.

## Offene Punkte (spätere Phasen)

- **NLEmbedding für Deutsch verfügbar?** Prüfen und Ergebnis hier festhalten; sonst kleines lokales Embedding-Modell (Phase 4).
- **Vision-Verhalten unter iOS 27 auf echten Geräten:** berichtete Verschlechterung des genauen Modus nur auf Geräten; Messung und Dokumentation (Phase 1, später Qualitätstest Phase 8).
- **Apple Foundation Models:** Bilder erst ab iOS 27; `tokenCount(for:)` und `contextSize` ab iOS 26.4; Verhalten auf iOS 26.0–26.3 klären (Phase 2, Phase 8).
- **Format-Erkennung echter Goodnotes-Exporte:** Reicht `/Producer` bzw. `/Creator`, oder sind strukturelle Merkmale nötig? (Phase 1; Daten aus `docs/MANUAL_TESTS.md`). Die Fixtures tragen bewusst einen synthetischen `/Producer`; die Erkennung muss daher primär strukturell arbeiten (Ink-/FreeText-/Stamp-Annotationen vs. Textebene ohne Annotationen).
