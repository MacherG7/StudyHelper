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

## D-023 Absätze: zusammenhängende Zeilen werden gemeinsam gespeichert

- **Datum:** 2026-11-24
- **Status:** angenommen (Wunsch des Entwicklers)
- **Kontext:** Zeilen, die direkt untereinander stehen und einen Text bilden, sollen nach der Digitalisierung zusammengefügt gespeichert werden, mit Position im PDF.
- **Entscheidung:** Jede Zeile trägt eine `paragraphID` (im vorhandenen JSON der Zeilen, kein neues SwiftData-Schema nötig, alte Daten bleiben lesbar). `ParagraphGrouping.assign` setzt sie bei jeder Digitalisierung; `DigitizationResult.paragraphs` und `Digitization.paragraphs` liefern `TextParagraph` (zusammengefügter Text, Rechteck als Vereinigung der Zeilen, Zeilen-IDs, Listenpunkt ja/nein). Der Text wird aus den gespeicherten Zeilen gebildet, Korrekturen einer Zeile erscheinen also im Absatz. Regeln: Eine Zeile setzt den Absatz fort, unter dessen letzter Reihe sie steht (höchstens eine halbe Zeilenhöhe Abstand; bei Drucktext 1,2 eigene Zeilenhöhen), horizontal überlappend, gleiche Farbe, kein neuer Listenpunkt (-, •, 1., „15 Niger“ …). Nach einer kurzen Reihe (Überschrift, Listeneintrag) nur bei Trennstrich oder Kleinbuchstaben. Teile einer Reihe nebeneinander gehören dazu (Blocksatz-Stücke im Druck auch mit großen Lücken). Hängender Einzug trennt Einträge. Trennstriche am Zeilenende werden aufgelöst, Ergänzungsstriche („Schnee- und“) bleiben. Unleserliches ist ein eigener Absatz.
- **Konsequenzen:** Die Prüfansicht bleibt zeilenweise (Korrektur und Markierung pro Zeile). Der Originaltext-Markdown behält die Zeilenumbrüche der Vorlage. Absätze sind die Grundlage für KI-Aufgaben ab Phase 2. Auf der Testdatei werden aus 348 Zeilen 246 Absätze.

## D-024 Verteilung über eine Source für SideStore, AltStore und StikStore

- **Datum:** 2026-11-24
- **Status:** angenommen (Wunsch des Entwicklers)
- **Kontext:** Bisher nur Installation aus Xcode; Profile des kostenlosen Accounts laufen nach 7 Tagen ab (D-013). SideStore, AltStore (Classic) und StikStore lesen dasselbe JSON-Format („AltSource“, faq.altstore.io „Make a Source“) und signieren Apps mit der Apple-ID des Geräts neu. Source und `.ipa` müssen ohne Anmeldung abrufbar sein; `MacherG7/StudyHelper` ist privat.
- **Entscheidung:**
  1. Eine Source für alle drei: `distribution/source.json` (Hauptkopie im Repo). Format v2 (`versions`, neueste zuerst; `appPermissions` mit `entitlements` und `privacy`), dazu die älteren Felder (`identifier`, `sourceURL`; am App-Eintrag `version`, `versionDate`, `versionDescription`, `downloadURL`, `size`), die die offizielle SideStore-Source ebenfalls führt.
  2. Hosting in einem eigenen **öffentlichen** Repository (Standard `MacherG7/StudyHelper-Source`, änderbar über `SOURCE_REPO`): `source.json` und `icon.png` auf `main` (über raw.githubusercontent.com), jede `.ipa` als Release-Asset mit Tag `v<Version>-<Build>`. Kein Quellcode dort.
  3. Die `.ipa` für die Source ist **unsigniert** (`scripts/build-ipa.sh --unsigned`): Die Store-Apps signieren ohnehin neu; so stehen weder Team-ID noch `get-task-allow` in der Datei, und das Bauen verbraucht keine App-IDs des kostenlosen Accounts.
  4. `scripts/update-source.py` liest alles, was AltStore prüft, aus der `.ipa` selbst: Bundle-ID, `CFBundleShortVersionString`, `CFBundleVersion`, `MinimumOSVersion`, alle `NS…UsageDescription`-Schlüssel und die Entitlements aus der Code-Signatur (auch von App-Erweiterungen). Dazu Größe und SHA-256. AltStore (Code von `VerifyAppOperation` geprüft) lehnt die Installation ab, wenn Bundle-ID, Version, Build oder Hash nicht passen oder ein Entitlement bzw. Datenschutz-Schlüssel der App in der Source fehlt; ignoriert werden nur `application-identifier` und `com.apple.developer.team-identifier`.
  5. `scripts/publish-source.sh` lädt in dieser Reihenfolge hoch: Icon, `.ipa` (Release), zuletzt `source.json`. Eine neue Version erscheint so erst, wenn ihr Download existiert. Jede Version/Build-Kombination nur einmal (sonst `--replace`).
- **Konsequenzen:** Jede Beta braucht eine höhere `MARKETING_VERSION` oder `CURRENT_PROJECT_VERSION` in `project.yml`. Wer die Source-URL kennt, kann die App laden. Neue Berechtigungen (z. B. Mikrofon in einer späteren Phase) gelangen automatisch in die Source. Die App hat noch kein eigenes Icon; `distribution/icon.svg` ist ein Platzhalter. StikStore unterstützt laut Entwickler AltStore-Sources, sein Format ist aber nicht separat dokumentiert (MT-S.3). Skript-Tests (Python, `scripts/tests/`) und `update-source.py --check` laufen in `scripts/test.sh`.

## D-025 Formpfeile in Textzeilen und weitere Erkennungsregeln

- **Datum:** 2026-11-24
- **Status:** angenommen (Wunsch des Entwicklers, gemessen nach D-022)
- **Kontext:** Auf S. 9 der Testdatei fehlte in „Kausalkette (→ B.S.35)“ der Pfeil, und „S.“ wurde als „5.“ gelesen. Auf S. 6 fehlte „Sch“ von „Schädigungen“, und hinter „Globaler Wandel“ stand eine „9“.
- **Entscheidung:**
  1. **Formpfeile:** Pfeile aus dem Goodnotes-Formwerkzeug sind Stamp-Annotationen, keine Tinte; die Texterkennung sieht sie nie. Ihr Erscheinungsbild wird gelesen (Schaft + Spitze als eigener kurzer Pfad, auch beidseitig), die Richtung ergibt „→ ← ↑ ↓ ↔ ↕ ↗ ↘ ↙ ↖“. Liegt ein Pfeil in einer Textzeile (Mitte innerhalb der Zeilenhöhe, höchstens 1,5 Zeilenhöhen hoch, höchstens 1,5 Zeilenhöhen vom Zeilenende), wird das Zeichen an seiner Stelle in den Text eingesetzt (`insertsShapeArrows`, Standard an). Verbindungspfeile zwischen Kästen und Zeilen, Kästen und einfache Linien bleiben Grafik. Korrigierte Zeilen werden nicht verändert.
  2. **„B.5.35“ → „B.S.35“:** „5.“ direkt nach einem einzelnen Großbuchstaben mit Punkt und vor einer Zahl ist die Abkürzung „S.“ (nicht nach „z.B.“). Die alte Lesung bleibt Alternative.
  3. **Nachlesen zeilentreu:** Ein Ausschnitt einer einzelnen Zeile übernimmt angrenzende Striche seiner Zeile (bis 0,6 Zeilenhöhen), auch wenn der zu große Kasten der Zeile darüber sie beansprucht hat. Ein Strich, den Ausschnitte zweier Zeilen beanspruchen (Unterlänge), gehört nur zur näheren Zeile. Hohe Ausschnitte (dichte Listen, die später zeilenweise geteilt werden) bleiben unverändert – sonst gingen die Listennummern auf S. 8 verloren (gemessen, zuerst verworfen).
  4. **Messung:** Pfeile zählen in der Bewertung als Wort („->“, „-->“ gelten als „→“); S. 9 ist jetzt Referenzseite. F1 0,9451 → 0,9613 (Pfeile, S.) → 0,9625 (Nachlesen).
- **Konsequenzen:** Handgezeichnete Pfeile (Tinte) werden weiter von der Texterkennung gelesen oder als Strich übergangen. Offene Fehler auf S. 6: „f“ wird teils als „t“ gelesen („Eingrifte“, „tasst“), ä teils als a; schließende Anführungszeichen werden mitunter als Buchstabe gelesen („Wandeli“).

## D-026 Unterstreichung ohne vermutete Bedeutung

- **Datum:** 2026-11-24
- **Status:** angenommen (Wunsch des Entwicklers)
- **Kontext:** Bisher wurde eine ganz unterstrichene Zeile als „Überschrift“ vorgeschlagen, ein unterstrichener Teil als „Fachbegriff“. Unterstrichen bedeutet aber nicht immer Überschrift.
- **Entscheidung:** Unterstreichungen (einfach und doppelt) bekommen keine vermutete Bedeutung; sie bleibt „Offen“. Ob es eine Überschrift, ein wichtiger Fachbegriff oder eine Kernaussage ist, entscheidet der Nutzer (Bedeutung in der Prüfansicht, Vorschlag in der Themenansicht mit „Als Titel des Themas“, „Als Begriff“, „Als Kernaussage“) oder ab Phase 3 die KI. Andere Hervorhebungen (Textmarker → „wichtig“, Kreis → Begriff, große Schrift im PDF-Text → Überschrift) bleiben unverändert.
- **Konsequenzen:** Der Originaltext-Markdown macht aus unterstrichenen Zeilen keine `##`-Überschrift mehr, solange niemand „Überschrift“ gewählt hat; die Unterstreichung bleibt als `<u>` sichtbar.

## D-027 App-Version A.B.C.D, letzte Stelle pro Commit

- **Datum:** 2026-11-24
- **Status:** angenommen (Wunsch des Entwicklers)
- **Kontext:** Die Einstellungen sollen die App-Version zeigen. Start bei 0.0.1.0; die letzte Stelle steigt mit jedem Commit. Größere Sprünge (Release, Test-Beta) nur nach Rückfrage. Bisher stand in `Info.plist` fest „1.0“ (Build 1), `MARKETING_VERSION` aus `project.yml` wurde nicht benutzt.
- **Entscheidung:** Die Version hat vier Stellen: A.B.C ist `MARKETING_VERSION` (`CFBundleShortVersionString`, iOS erlaubt dort höchstens drei Zahlen), D ist `CURRENT_PROJECT_VERSION` (Build, `CFBundleVersion`). `Info.plist` übernimmt beide aus `project.yml`. Vor jedem Commit erhöht `scripts/bump-version.sh` den Build (0.0.1.0 → 0.0.1.1) und nimmt `project.yml` in den Commit auf. Eine größere Version setzt `scripts/bump-version.sh --set A.B.C` (Build wieder 0) – nur nach Rückfrage beim Entwickler. `scripts/publish.sh` warnt, wenn ein Push die Version nicht erhöht. Die Einstellungen zeigen unter „Über StudyHelper“ die Version „A.B.C.D“.
- **Konsequenzen:** Jede Version/Build-Kombination ist eindeutig, wie es AltStore für die Source verlangt (D-024). Das Beta-Release v0.1.0-beta.1 trug intern „1.0 (1)“; die neue Zählung beginnt bewusst niedriger bei 0.0.1.0. Die Source enthält noch keine Version, es gibt also keinen Konflikt.

## D-028 Jeder Commit wird als Beta auf GitHub veröffentlicht

- **Datum:** 2026-11-24
- **Status:** angenommen (Wunsch des Entwicklers)
- **Kontext:** Version 0.0.1.0 erschien nicht unter den Releases: `scripts/publish.sh` hat nur gepusht, eine `.ipa` als Release gab es bisher nur von Hand (v0.1.0-beta.1). Gewünscht ist, dass nach jedem Commit die auf dem Mac gebaute `.ipa` automatisch als Beta unter der vereinbarten Versionsnummer erscheint.
- **Entscheidung:** `scripts/publish.sh` ruft am Ende `scripts/beta-release.sh` auf (seit D-033 nur bei Änderungen an der .ipa). Es baut die `.ipa` (seit D-030 unsigniert, `scripts/build-ipa.sh --unsigned`) und legt das Pre-Release `v<A.B.C.D>` (Version aus `project.yml`, D-027) mit `StudyHelper-<A.B.C.D>.ipa` auf dem Commit an. Die Notizen enthalten die Commit-Nachricht und Installationshinweise. Gibt es das Release zu einer Version schon (Version nicht erhöht), wird übersprungen. Uncommittete App-Änderungen brechen ab, damit die `.ipa` immer dem Commit entspricht. Phasen-Tags (`scripts/release.sh`) bleiben zusätzlich.
- **Konsequenzen:** Jeder Commit dauert durch den Release-Build einige Minuten länger und braucht den angemeldeten Xcode-Account und `gh`. Schlägt der Build fehl, ist der Push schon erfolgt; das Release lässt sich mit `scripts/beta-release.sh` nachholen. 0.0.1.0 wurde nachträglich veröffentlicht. Die Source für SideStore/AltStore/StikStore (D-024) bleibt ein eigener, bewusster Schritt.

## D-029 Commit in der App sichtbar

- **Datum:** 2026-11-24
- **Status:** angenommen (Wunsch des Entwicklers)
- **Kontext:** Neben der Version soll man in der App sehen, aus welchem Commit sie gebaut wurde.
- **Entscheidung:** Eine Build-Phase des App-Targets (`scripts/embed-commit.sh`, in `project.yml`) schreibt bei jedem Build den kurzen Hash von `HEAD` als `StudyHelperCommit` in die gebaute `Info.plist` – in Xcode, bei Tests und bei der Release-`.ipa`. Hat der Build uncommittete Änderungen an `StudyHelper/`, `Packages/` oder `project.yml`, bekommt der Hash ein „+“; die Einstellungen zeigen dann „ec2c94b*“ mit dem Hinweis „Mit lokalen, noch nicht committeten Änderungen gebaut“. Weil die Phase das Git-Repository liest, ist `ENABLE_USER_SCRIPT_SANDBOXING` im App-Target aus.
- **Konsequenzen:** Die Beta-Releases (D-028) werden nach dem Commit gebaut und zeigen dessen Hash ohne Stern. Ohne Git (z. B. Quellcode-Archiv) steht „unbekannt“.

## D-030 Keine E-Mail-Adressen, nur unsignierte .ipa auf GitHub

- **Datum:** 2026-11-24
- **Status:** angenommen (Wunsch des Entwicklers)
- **Kontext:** Die E-Mail des Entwicklers stand in Dateien, einer Commit-Nachricht, als Autor alter Commits und Tags und – über das Entwicklerzertifikat – in jeder signierten .ipa der Beta-Releases.
- **Entscheidung:** Alle Releases wurden gelöscht, die Git-Historie umgeschrieben (Autor/Committer auf die GitHub-noreply-Adresse, die E-Mail in alten Dateiständen und Nachrichten durch „<Apple-ID>“ ersetzt, Tags neu gesetzt) und per Force-Push ersetzt; der offene PR #2 wurde mit umgeschrieben. Beta-Releases (D-028) enthalten ab jetzt eine unsignierte .ipa (`scripts/build-ipa.sh --unsigned`); installiert wird sie mit SideStore, AltStore, StikStore oder Sideloadly, die mit der eigenen Apple-ID signieren. Es gibt überhaupt keine signierte .ipa mehr, auch nicht lokal: `scripts/build-ipa.sh` baut nur noch unsigniert (`--unsigned` wird nur noch angenommen). Keine E-Mail-Adressen mehr in Dateien, Commits, Tags oder Release-Texten.
- **Konsequenzen:** Alle Commit-Hashes haben sich geändert; Hashes in älteren Texten (z. B. „Commit ec2c94b“) gelten nicht mehr. GitHub hält die alten Commits des gemergten PR #1 (`refs/pull/1/head`) weiter vor – endgültig entfernen kann sie nur der GitHub-Support. Direkt über die Xcode-Geräteliste lässt sich die Release-.ipa nicht mehr installieren; dafür aus Xcode bauen.

## D-032 Beta und Vollversion: Markierung statt eigener Nummer

- **Datum:** 2026-11-24
- **Status:** angenommen (Entscheidung des Entwicklers)
- **Kontext:** Bisher war jeder Commit eine Beta (D-027, D-028). Es braucht ein Schema für Vollversionen, das AltStore/SideStore richtig sortieren (Version und Build müssen steigen).
- **Entscheidung:**
  - **Betas:** Version A.B.C plus Build pro Commit wie bisher (z. B. 1.0.0.1 … 1.0.0.7), GitHub-Pre-Release `v1.0.0.N`, Titel „StudyHelper 1.0 Beta N“ (N = Build). Die App zeigt „1.0.0.3 (Beta)“.
  - **Vollversion:** dieselbe Version mit dem nächsten Build (z. B. 1.0.0.8, nie Build 0 – sonst wäre sie für AltStore/SideStore älter als die Betas), normales Release `v1.0.0.8` (kein Pre-Release, „Latest“), Titel „StudyHelper 1.0“, zusätzlich Tag `v1.0.0` auf demselben Commit. Die App zeigt „1.0.0.8“ ohne „(Beta)“. Veröffentlichen mit `scripts/publish.sh --final` (ruft `scripts/beta-release.sh --final`), nur wenn der Entwickler es sagt.
  - Beta/Final ist eine Markierung, keine Stelle der Nummer: Build-Einstellung `STUDYHELPER_CHANNEL` (Standard `Beta`, `scripts/build-ipa.sh --final` setzt `Final`), in der App als `StudyHelperChannel` in der `Info.plist`.
  - Titel: „1.0.0“ heißt „1.0“, „1.0.1“ bleibt „1.0.1“.
  - Danach weiter mit `scripts/bump-version.sh --set 1.0.1` (Fehlerkorrekturen) bzw. `--set 1.1.0` (neue Funktionen); `--set` weiterhin nur nach Rückfrage.
- **Konsequenzen:** `scripts/beta-release.sh --final` bricht ab, wenn der Build schon veröffentlicht ist oder es `v<A.B.C>` schon gibt; `--dry-run` zeigt vorher Tag, Titel und Art. Xcode-Builds gelten immer als Beta.

## D-033 Release nur bei Änderungen an der .ipa

- **Datum:** 2026-11-24
- **Status:** angenommen (Wunsch des Entwicklers)
- **Kontext:** Bisher wurde jeder Commit als Beta veröffentlicht (D-028), auch wenn sich nur Doku, Tests oder Skripte geändert hatten – die .ipa war dann bis auf den eingetragenen Commit dieselbe.
- **Entscheidung:** `scripts/beta-release.sh` (aus `scripts/publish.sh`) veröffentlicht eine Beta nur, wenn sich seit dem letzten Release (neuester Tag `vA.B.C.D` vor dem Commit) etwas geändert hat, das in die .ipa gehört: `StudyHelper/`, die verlinkten Bibliotheken `Packages/StudyHelperCore/Sources/StudyCore`, `StudyImport`, `StudyData`, `StudyAI` (seit Phase 2) und `Package.swift`, `project.yml` ohne die Versionszeilen sowie `scripts/build-ipa.sh` und `scripts/embed-commit.sh`. Sonst meldet es „kein neues Release“. `--force` erzwingt eine Beta; eine Vollversion (`--final`, D-032) wird immer gebaut.
- **Konsequenzen:** Die Version steigt weiter mit jedem Commit (D-027); zwischen zwei Releases können deshalb Build-Nummern fehlen (z. B. 0.0.1.7 → 0.0.1.9). AltStore/SideStore stört das nicht, sie vergleichen nur auf größer.

## D-034 Öffentliches Repository mit der Source darin

- **Datum:** 2026-11-24
- **Status:** angenommen (Wunsch des Entwicklers)
- **Kontext:** Die Source-Datei soll im StudyHelper-Repository liegen. Das Repository war privat; ohne Anmeldung (so rufen StikStore, SideStore und AltStore ab) lieferte GitHub für Source und .ipa nur 404. Zudem zeigten die geschlossenen PRs #1 und #2 des alten Repositorys noch Commits mit der E-Mail des Entwicklers (D-030), die nur der GitHub-Support entfernen kann.
- **Entscheidung:** Das alte Repository wurde in `StudyHelper-alt` umbenannt; ein neues, **öffentliches** `MacherG7/StudyHelper` enthält die bereinigte Historie (Branch `main`, Tags, Branch von PR #3), die Releases v0.0.1.3–v0.0.1.7 wurden mit ihren unsignierten .ipa neu angelegt; danach wird das alte Repository gelöscht. Die Source ist `distribution/source.json` (URL `https://raw.githubusercontent.com/MacherG7/StudyHelper/main/distribution/source.json`), die Downloads zeigen auf die Releases `v<A.B.C.D>`. Nach jedem Release trägt `scripts/beta-release.sh` die Version ein und committet/pusht das als „Source: …“ (einziger Commit ohne Versionserhöhung); `--source-only --tag=…` trägt ein vorhandenes Release nach. `scripts/publish-source.sh` und das separate Repository `MacherG7/StudyHelper-Source` werden nicht mehr gebraucht.
- **Konsequenzen:** Quellcode, Historie und Doku sind öffentlich; Prüfung vor dem Umzug: keine Schlüssel, keine echten Notizen, nur noreply-Adressen. PR #3 (D-031, Workflow für das separate Source-Repository) ist damit überholt. Wer die Source-URL kennt, kann die App installieren.

## D-035 Source ohne SHA-256

- **Datum:** 2026-11-24
- **Status:** angenommen (Fehler in StikStore)
- **Kontext:** StikStore brach die Installation mit „The download doesn't match the checksum its source published“ ab, obwohl die heruntergeladene .ipa genau die SHA-256 der Source hatte (ohne Anmeldung nachgeprüft, auch über die Weiterleitung von GitHub). Wie StikStore die Prüfsumme bildet, ist nicht dokumentiert und der Code nicht öffentlich.
- **Entscheidung:** `scripts/update-source.py` schreibt kein `sha256` mehr in die Versionen (das Feld ist im AltSource-Format optional). Größe, Version, Build, Mindest-iOS, Entitlements und Datenschutz-Texte bleiben.
- **Konsequenzen:** Die Store-Apps prüfen die .ipa nicht mehr gegen eine Prüfsumme; die Datei kommt über HTTPS direkt aus dem Release. Funktioniert StikStore damit, bleibt es so (MT-S.3); sonst liegt der Fehler woanders und das Feld kann zurückkommen.

## D-036 KI-Anbieter (Phase 2)

- **Datum:** 2026-11-25
- **Status:** angenommen
- **Kontext:** Phase 2 legt alle KI-Anbieter hinter ein gemeinsames Protokoll (SPEC „Technische Vorgaben“, §3, §10). API-Parameter stammen aus der am 2026-11-24 gelesenen offiziellen Doku (`docs/API-REFERENZ.md`).
- **Entscheidung:**
  - Eigenes Package-Target `StudyAI` (abhängig nur von `StudyCore`): `ModelProvider` mit einheitlichem `ResponseMetadata`, Streaming (`AsyncThrowingStream`), Tool-Aufrufen; Anbieter Claude (Messages API), OpenAI (Responses API), OpenAI-kompatibel (Chat Completions, Ollama-Erkennung über `/api/tags` + `/api/show`), Apple Foundation Models (`#available(iOS 26)`, Verfügbarkeitsprüfung), Mock.
  - Konfigurationen ohne Geheimnisse als JSON in UserDefaults; API-Keys nur in der Keychain (`WhenUnlockedThisDeviceOnly`, Dienst `MiloG.StudyHelper1.apikeys`); Löschen eines Anbieters löscht seinen Key. UI-Tests nutzen nur einen Speicher im Arbeitsspeicher.
  - Denktiefe: Claude-Stufen kommen je Modell aus `/v1/models` (adaptives Denken + `effort`; „Aus“ nur bei `disabled` oder `between_tools`). OpenAI liefert keine Fähigkeiten → Tabelle nach Modellfamilie (`OpenAIModelTable`), Fakten aus der Doku markiert, Stufenlisten pro Modell sind **Annahmen** (MT-2.7). Ollama: Fähigkeit `thinking`.
  - Wiederholung nur vor dem ersten Byte eines Streams (429 mit `Retry-After`, 5xx, 529); Spend-/Guthabenlimits werden nicht wiederholt.
  - Preise: Tabelle in `StudyCore/Pricing.swift` mit Standardpreisen aus der Doku, in den Einstellungen überschreibbar; Claude zählt Cache-Tokens getrennt von `input_tokens`, OpenAI enthält sie; Reasoning steckt bei beiden in den Output-Tokens. Wechselkurs USD→EUR einstellbar (Standard 0,86, kein Live-Kurs). Kosten immer „geschätzt“.
  - Anfrage-Log in SwiftData (`SchemaV2.RequestLog`, leichte Migration V1→V2, an einem echten V1-Store geprüft); jede Anfrage wird geloggt, auch Fehler; Header und Keys nie im Log oder Export, Bilder nur als Platzhalter.
  - Nach dem Review: Denkblöcke (Claude, mit Signatur) und Reasoning-Items (OpenAI) werden als `MessageContent.reasoning` unverändert zurückgegeben, damit Tool-Schleifen mit Denken funktionieren; fehlgeschlagene Anfragen werden mit Teil-Metadaten (Tokens, Kosten, gesendete Anfrage) geloggt; unlesbare Einstellungen einer neueren Version werden nur übersprungen und gesichert, nie überschrieben; die Denktiefe bietet „Modell-Standard“; ein beim Bearbeiten getesteter Key wird erst beim Sichern gespeichert; Bilder an Modelle ohne Bildfähigkeit werden abgelehnt; Zugangsdaten in URLs werden in Logs entfernt.
- **Konsequenzen:** Der Rest der App spricht nur `ModelProvider`/`AIService` an (`AIService.respond(_:decoding:)` setzt Parsing-Fehler in Metadaten und Log). Guided Generation/Tools beim Apple-Modell und Bilder ab iOS 27 folgen mit den ersten KI-Aufgaben (Phase 4). Ollama `reasoning_effort: "none"` für „Aus“ ist eine Annahme (MT-2.6).

## D-037 Digitale Seite: PDF mit unsichtbarer Textebene (Phase 3)

- **Datum:** 2026-11-25
- **Status:** angenommen (Wunsch des Entwicklers)
- **Kontext:** Die erkannten Texte sollen in einem neuen PDF mit ihrer Position und den zugehörigen Skizzen und Bildern gespeichert werden, als Ansichtsmodus in der App und für die spätere Verwendung durch die KI. Zur Wahl standen eine getippte Neusetzung der Seite (Handschrift ersetzt) und das Original mit unsichtbarer Textebene; der Entwickler hat das Original mit Textebene gewählt.
- **Entscheidung:**
  - Pro Seite ein PDF in Originalgröße: PDF-/Goodnotes-Seiten werden unverändert übernommen (Seiteninhalt und Annotationen), Fotos/Scans als Bild. Skizzen, Bilder, Formen und Textmarker bleiben dadurch exakt erhalten, ohne sie vom Text trennen zu müssen.
  - Darüber eine unsichtbare Textebene aus dem gespeicherten Originaltext samt Korrekturen, je Wort (sonst je Zeile) an der Bounding Box; eine fremde Textebene (reduziertes Goodnotes-PDF) wird nicht übernommen.
  - Die digitale Seite ist abgeleitet und nie Quelle der Wahrheit (die bleibt die Digitalisierung in SwiftData). Sie wird zwischengespeichert und nach Korrektur, Neuerkennung oder Wiederherstellung neu erzeugt.
  - KI: Aufgaben, die die Seite selbst brauchen, senden das PDF an Modelle mit PDF-Eingabe (Fähigkeit pro Anbieter/Modell, Parameter vor der Umsetzung aus der aktuellen offiziellen Doku), sonst Bild + gespeicherter Text. Alle anderen Aufgaben bekommen weiterhin nur den gespeicherten Text (spart Tokens).
  - Nachtrag (Wunsch des Entwicklers): In der Ansicht schaltet „Handschrift | Text“ um. Im Modus „Text“ wird die Handschrift ausgeblendet und die Textebene sichtbar gezeichnet; Skizzen, Bilder, Formen und Textmarker bleiben. Bei Goodnotes werden dafür die Ink-Striche ausgelassen, die zu erkannten Zeilen gehören (Zuordnung über Zeilenboxen, wie bei der Ink-Erkennung); bei Fotos/Scans werden die Zeilenbereiche mit der umgebenden Papierfarbe überdeckt. Gespeichert wird weiterhin nur die Fassung mit unsichtbarer Textebene; der Modus „Text“ entsteht beim Anzeigen.
- **Konsequenzen:** Die Erzeugung liegt in `StudyImport` (PDFKit/CoreGraphics). Striche, die eine Zeile und eine Skizze berühren, können falsch zugeordnet werden (MT-3.14). Ein Export/Teilen des PDFs ist damit leicht möglich, ist aber nicht beauftragt. Bei Fotos ist die Seite so groß wie das Bild; die Qualität der Textebene hängt direkt an der Erkennung (Verbesserung Phase 8).

## D-038 Plan-Erweiterungen nach Phase 2

- **Datum:** 2026-11-25
- **Status:** angenommen (Auswahl des Entwicklers)
- **Kontext:** Nach Phase 2 wurden Ergänzungen und eine bessere Gliederung des Plans vorgeschlagen; der Entwickler hat ausgewählt. Nicht gewählt: Karteikarten ohne KI schon nach Phase 3 und ein fester Gerätetest-Meilenstein vor Phase 4 (Gerätetests laufen nebenbei).
- **Entscheidung:**
  - **Datensicherung** als 3b, direkt nach der digitalen Seite: Ohne iCloud (kostenloser Account) und bei sideloadeten Apps wären sonst alle Daten mit der App weg. Eine Datei mit Formatversion, ohne Keys; jede spätere Phase erweitert das Format um ihre Daten.
  - **Formeln** in 3c (Darstellung) und 3f (KI liefert sie): gespeichert als LaTeX-Teil im Markdown, der Darstellungsweg wird bei der Umsetzung entschieden.
  - **Warteschlange, Kostenschutz, Datenschutz** als 3e, vor der ersten echten KI-Aufgabe (Transkription in 3f), damit schon die erste teure Massenaufgabe geschützt ist.
  - **Phase 4 in 4a/4b/4c** aufgeteilt; **Rückgängig für KI-Änderungen** in 4b. **Suchindex und Embeddings** wandern nach Phase 6, weil erst die Chat-Tools sie brauchen; dort zusätzlich als Suche für den Nutzer.
  - **Diktieren und Vorlesen** in Phase 5 (Chat-Diktat in 6), **Prüfungstermin, Erinnerungen, Probeklausur, Fehlerheft** in Phase 7, weil sie auf Leitner und Auswertung aufbauen.
- **Konsequenzen:** Phase 3 wird größer (sechs Teilschritte, je ein Commit und eine Beta). Lokale Mitteilungen und Spracherkennung brauchen Berechtigungen (Info.plist-Texte); beide funktionieren mit dem kostenlosen Account. Widgets und iCloud bleiben ausgeschlossen (D-013).

## Offene Punkte (spätere Phasen)

- **NLEmbedding für Deutsch verfügbar?** Prüfen und Ergebnis hier festhalten; sonst kleines lokales Embedding-Modell (Phase 4).
- **Vision-Verhalten unter iOS 27 auf echten Geräten:** berichtete Verschlechterung des genauen Modus nur auf Geräten; Messung und Dokumentation (Phase 1, später Qualitätstest Phase 8).
- **Apple Foundation Models:** Bilder erst ab iOS 27; `tokenCount(for:)` und `contextSize` ab iOS 26.4; Verhalten auf iOS 26.0–26.3 klären (Phase 2, Phase 8).
- **Format-Erkennung echter Goodnotes-Exporte:** Reicht `/Producer` bzw. `/Creator`, oder sind strukturelle Merkmale nötig? (Phase 1; Daten aus `docs/MANUAL_TESTS.md`). Die Fixtures tragen bewusst einen synthetischen `/Producer`; die Erkennung muss daher primär strukturell arbeiten (Ink-/FreeText-/Stamp-Annotationen vs. Textebene ohne Annotationen).
