# StudyHelper – Phasen

Quelle: `docs/SPEC.md`, Abschnitt „Phasen“. Pro Phase ein Commit nach Verifikation. Checkboxen werden erst nach der Prüfung abgehakt. Geräteprüfungen stehen in `docs/MANUAL_TESTS.md`.

| Phase | Status | Commit |
|---|---|---|
| 0 Gerüst, Test-PDFs, Skripte, Doku | fertig | 27235ba |
| 1 Datenmodell, Import, Digitalisierung, manuelle Strukturierung | fertig (Geräteprüfungen offen) | b8bf773, b3622fd, 1c |
| 2 Anbieter-Protokoll und Anbieter | offen | – |
| 3 Hervorhebungen | offen | – |
| 4 System-Prompts, sortierte Fassung, KI-Strukturierung, Lerneinheiten | offen | – |
| 5 Multiple Choice, Freitext, Karteikarten, Vorrat, Caching | offen | – |
| 6 Tipps und Chat-Modus | offen | – |
| 7 Leitner, Auswertung, Fortschritt | offen | – |
| 8 Design, Barrierefreiheit, Developer-Modus | offen | – |
| 9 Hugging-Face-Download, lokale Ausführung | offen | – |

---

## Phase 0 – Gerüst, Test-PDFs, Skripte, Doku

**Ziel:** Reproduzierbares Projektgerüst (XcodeGen + Core-Package) mit künstlichen Goodnotes-Test-PDFs, lokalen Skripten und vollständiger Projektdoku, auf dem alle weiteren Phasen aufsetzen.

- [x] Künstliche Goodnotes-Test-PDFs inkl. Ground-Truth-JSON (`Fotosynthese_bearbeitbar.pdf`, `Fotosynthese_reduziert.pdf`, `Andere_Notiz_reduziert.pdf`, `Andere_Groesse_reduziert.pdf`)
- [x] `.gitignore` (Xcode, SwiftPM, Secrets, `LocalSamples/`, `*.goodnotes`, generiertes `.xcodeproj`)
- [x] XcodeGen-Projekt (`project.yml`) mit App-, Unit-Test- und UI-Test-Target; altes Xcode-27-Projekt entfernt
- [x] Core-Package `Packages/StudyHelperCore` (`StudyCore`, `TestFixtures`, `make-fixtures`, Testtargets)
- [x] App-Platzhalter (deutsch) und Smoke-Tests (Swift Testing, XCTest-UI-Test)
- [x] Skripte: `bootstrap.sh`, `build.sh`, `test.sh`, `make-fixtures.sh`, `check-secrets.sh`
- [x] `CLAUDE.md` (inkl. Abschnitt „Stand“)
- [x] `docs/SPEC.md`, `docs/PLAN.md`, `docs/DECISIONS.md`, `docs/MANUAL_TESTS.md`, `docs/PHASES.md`

**Abnahmekriterien**
- `scripts/bootstrap.sh` erzeugt das Projekt ohne Fehler; `scripts/build.sh` baut für iPhone- und iPad-Simulator.
- `scripts/test.sh` (inkl. `--ui`) ist grün: Package-Tests auf macOS und iOS-Simulator, App-Unit-Tests, UI-Test.
- Fixture-Tests belegen: Ink mit `/InkList`, `/C`, `/BS /W` in mindestens vier Farben; Textmarker gelb mit Breite ca. 18; FreeText-`/Contents` exakt inkl. Unicode; Stamp vorhanden; Bild + Text im Seiteninhalt; reduziertes PDF ohne `/Annots`, Text mit Positionen lesbar; gleiche Seitenzahl und MediaBox; mitgelieferte Dateien stimmen mit frisch erzeugten überein.
- Jede Fixture-Seite wurde gerendert und visuell geprüft (Linien, Farben, Textmarker, FreeText, Pfeil, Arbeitsblatt sichtbar).
- App startet im Simulator und zeigt den deutschen Platzhalter.
- `git status`: generiertes Projekt ignoriert, Fixtures enthalten; `check-secrets.sh` sauber.

---

## Phase 1 – Datenmodell, Import, Digitalisierung, manuelle Strukturierung

**Ziel:** Lernstoff importieren (Fotos, PDFs, Scans, Goodnotes), einmalig digitalisieren, dauerhaft speichern, prüfen/korrigieren und manuell in Themen strukturieren (Weg a).

- [x] SwiftData-Modell: Fach, Import, Quelle, Digitalisierung (Originaltext, Zeilen mit Bounding Box, Sicherheit, Kandidaten, Methode, Vision-Revision, iOS, Gerät, Zeitpunkt, Versionen, Nutzerkorrekturen), Hervorhebung, Thema und Eintrag mit Herkunft, Quellenverweis, Hervorhebung, Ergänzungsstatus
- [x] Entscheidung zum Ort der Modelle (Package vs. App) in DECISIONS festhalten
- [x] Fächerverwaltung: anlegen, bearbeiten, löschen
- [x] Import: Foto (Kamera, Mediathek), PDF, Dokumentenscanner (VisionKit)
- [x] PDF-Seiten mit PDFKit als Bilder rendern; eingebetteter PDF-Text samt Formatierung (Fett, Farbe, Unterstreichung) direkt übernehmen
- [x] Jede Seite/jedes Bild als Quelle speichern und direkt nach dem Import digitalisieren
- [x] Goodnotes-Parser: Ink (`/InkList`, `/C`, `/BS /W`), Textmarker, FreeText (`/Contents`), Stamp; Seiteninhalt (Bilder/Arbeitsblätter)
- [x] Format-Erkennung (bearbeitbar vs. reduziert) und Zuordnung beider Exporte (gleiche Seitenzahl/-größe, Bestätigung durch den Nutzer); `.goodnotes` abgelehnt
- [x] ~~Share-Extension inkl. App Group~~ → „Öffnen in StudyHelper“ als PDF-Dokumenttyp (kostenloser Developer-Account, D-013)
- [x] Vision-Texterkennung (genauer Modus, Deutsch, Sprachkorrektur, Umlaute getestet); `RecognizeDocumentsRequest` ab iOS 26 für Tabellen, Listen, Absätze
- [x] Goodnotes: nur Ink in hoher Auflösung auf Weiß rendern, je Farbe eine Ebene, jede Ebene erkennen; Textmarker-Flächen per Position den Wörtern zuordnen; FreeText direkt übernehmen
- [x] Unterstreichungen aus der Form erkennen (lange, fast waagerechte Linie unter einer Zeile)
- [x] Sicherheitswerte und Kandidaten speichern, unsichere/unleserliche Stellen markieren
- [x] `customWords` aus bestätigten Fachbegriffen an Vision übergeben; Wirkung testen und dokumentieren
- [x] Abgleich mit dem reduzierten Goodnotes-PDF (übereinstimmend = sicher, abweichend = zur Prüfung)
- [x] Optionale Mehrfacherkennung mit veränderten Renderings (Einstellung, abschaltbar)
- [x] Vision-Revision, iOS-Version und Gerät pro Erkennung speichern
- [x] Prüfen-/Korrigieren-Ansicht: Bild und Text nebeneinander, Zeile ↔ Bildmarkierung, Übersicht offener Stellen, Text und Hervorhebungen von Hand korrigierbar, Korrekturen haben Vorrang
- [x] Erneute Erkennung nur auf Wunsch (einzelne Seite oder Import), mit Hinweis auf erhaltene Korrekturen und Versionierung
- [x] Manuelle Strukturierung: Themen anlegen, Seiten zuordnen, Felder füllen (nur Titel Pflicht), Text mit Hervorhebungen neben dem Editor, Vorschläge aus Hervorhebungen
- [x] Themen zusammenlegen, aufteilen, umbenennen, löschen; Quellen verschieben
- [x] Hinweis auf betroffene Themen bei nachträglicher Korrektur der Digitalisierung
- [x] Thema bestätigen (Voraussetzung zum Lernen)
- [x] Core: Wortzerlegung/Normalisierung als Grundlage für spätere Abgleiche

**Abnahmekriterien**
- Alle vier Fixture-PDFs lassen sich importieren; Format-Erkennung und Zuordnung beider Exporte funktionieren (negative Fälle: `Andere_Notiz_reduziert.pdf` mit anderer Seitenzahl und `Andere_Groesse_reduziert.pdf` mit anderer Seitengröße werden nicht zugeordnet).
- Farbe jedes erkannten Worts der bearbeitbaren Fixture stimmt mit der Ground Truth überein; Textmarker-Zuordnung und Unterstreichungserkennung gegen Ground Truth getestet.
- Eingebetteter PDF-Text wird ohne Texterkennung übernommen; Fehlerwörter im reduzierten PDF werden als „zur Prüfung“ markiert.
- Digitalisierung läuft einmalig; spätere Schritte lösen keine erneute Erkennung aus (Test).
- Korrekturen überleben eine erneute Erkennung; alter Stand ist als Version wiederherstellbar.
- Ein manuell angelegtes Thema mit Quellenverweisen lässt sich speichern, bearbeiten, bestätigen; Tippen auf einen Eintrag markiert die Stelle im Bild.
- Geräteprüfungen MT-1.x (Goodnotes-Exporte, Vision, „Öffnen in“) durchgeführt und protokolliert. **Offen – vom Entwickler auf dem Gerät durchzuführen.**

---

## Phase 2 – Anbieter-Protokoll und Anbieter

**Ziel:** Alle KI-Anbieter hinter einem gemeinsamen Protokoll mit Metadaten, Reasoning, Streaming und Tool-Aufrufen; Anfrage-Logs werden gespeichert.

- [x] Anbieter-Protokoll: Fähigkeiten (Bilder, Tools, Streaming, Reasoning-Stufen, Kontextgröße), Anfrage, Antwort, Metadaten-Objekt, Streaming per `AsyncThrowingStream`
- [x] Aktuelle offizielle Doku von Anthropic und OpenAI gelesen (Modellliste, Reasoning, Usage, Streaming); Quellen in DECISIONS vermerkt
- [x] Mock-Modell mit festen Antworten (inkl. Streaming, Tool-Aufrufen, Fehlerfällen)
- [x] Robustes JSON-Parsing in `StudyCore` (fehlerhafte Ausgaben stürzen nie ab, Parsing-Fehler in den Metadaten)
- [x] Apple Foundation Models hinter `#available(iOS 26, *)` und `SystemLanguageModel.default.availability`; Guided Generation und Tools folgen mit den ersten strukturierten Aufgaben in Phase 4 (D-036)
- [x] OpenAI-kompatibler Anbieter (URL, Modellname, optionaler Key; Bildfähigkeit bei Ollama per API erkannt, sonst Einstellung; Reasoning ein/aus)
- [x] Claude-API: Key, Modellliste per API, Modellauswahl, Reasoning-Stufen nur falls vom Modell unterstützt
- [x] OpenAI-API: dasselbe
- [x] Keychain-Speicher für Keys; nie UserDefaults, Code oder Logs
- [x] Einstellungen: mehrere Anbieter-Konfigurationen, eigener Anbieter für Digitalisierung, Reasoning pro Aufgabe überschreibbar
- [x] Anfrage-Logs in SwiftData (Header maskiert), Reasoning-Inhalte nur im Developer-Modus verfügbar
- [x] Preisberechnung in `StudyCore` (Preistabelle, Reasoning wie Output, „unbekannt“ ohne Preis, 0 € bei kostenlosen Anbietern)

**Abnahmekriterien**
- Rest der App spricht nur das Protokoll an; ein Anbieterwechsel braucht keine Änderung außerhalb der Konfiguration (Test mit Mock).
- Kein Test ruft echte APIs auf (Mock-Nachweis, `check-secrets.sh` sauber).
- Fehlerhafte/abgeschnittene JSON-Antworten führen zu Parsing-Fehler statt Absturz (Tests mit kaputten Fixtures).
- Metadaten enthalten Anbieter, Modell, Reasoning-Stufe, Tokens, Dauer, Zeit bis zum ersten Token, gesendete Inhalte, Kontext-IDs, rohe Prompt/Antwort.
- Auf Geräten ohne Apple Intelligence oder mit älterem iOS erscheint das Apple-Modell nicht in der Auswahl (MT-2.x).
- Keys liegen nachweislich nur in der Keychain.

---

## Phase 3 – Hervorhebungen

**Ziel:** Hervorhebungen zuverlässig erkennen, darstellen und bearbeiten; erneute Erkennung versioniert.

- [ ] KI-Transkription mit bildfähigen Modellen (Struktur und Hervorhebungen strukturiert zurück; Vision-Ergebnis wird mitgeschickt; Reihenfolge der Vorlage bleibt)
- [ ] Optional zwei Durchläufe bei KI-Transkription (abschaltbar, Kostenhinweis)
- [ ] Bildanalyse als Fallback ohne bildfähiges Modell (Schrift-/Hintergrundfarbe in Textzeilen, Linien unter Zeilen); Ergebnisse als unsicher markiert
- [ ] Hervorhebungsarten: unterstrichen, doppelt unterstrichen, fett, farbiger Stift, Textmarker, umrandet, eingekreist, Großbuchstaben
- [ ] Vermutete Bedeutung (Überschrift, Fachbegriff, Definition, Merksatz, Formel, „wichtig“), vom Nutzer änderbar
- [ ] Farblegende pro Fach; Legende ersetzt Vermutung
- [ ] Darstellung im erkannten Text (fett, farbig, unterstrichen) und als Overlay im Originalbild
- [ ] Bearbeiten der Hervorhebungen (Text, Art, Farbe, Bedeutung, Position)
- [ ] Versionierung bei erneuter Erkennung (Vorher-Hinweis, alter Stand wiederherstellbar)

**Abnahmekriterien**
- Mit Mock-Modell wird eine strukturierte Antwort mit Hervorhebungen korrekt gespeichert und dargestellt.
- Bildanalyse erkennt auf synthetischen Bildern gefärbte Schrift und Unterstreichungen; Ergebnisse tragen das Merkmal „unsicher“.
- Bei Goodnotes-Fixtures bleiben Farb-/Textmarker-Hervorhebungen als „sicher“ erhalten.
- Eine hinterlegte Farblegende bestimmt die Bedeutung statt der Vermutung.
- Erneute Erkennung erhält manuelle Korrekturen, der alte Stand ist wiederherstellbar.
- Geräteprüfungen MT-3.x durchgeführt.

---

## Phase 4 – System-Prompts, sortierte Fassung, KI-Strukturierung, Lerneinheiten

**Ziel:** Alle Prompts bearbeitbar mit fester Grundregel; sortierte Fassung; Strukturierung per KI und gemischt mit Lückenerkennung; Lerneinheiten, Suche und Kontext-Zusammenstellung.

- [ ] Standard-System-Prompts (Deutsch) für alle Aufgaben: Digitalisierung, Sortieren, Strukturierung, Zuordnung zu vorgegebenen Themen, Korrektur eines Themas, Lücken erkennen/füllen, MC, Freitext, Bewerten, Tipps, Chat, Karteikarten
- [ ] Feste, nicht entfernbare Teile (Grundregel inkl. Lücken-Regel, Ausgabeformat) in der Prompt-Komposition; im Editor schreibgeschützt
- [ ] Platzhalter (`{fach}`, `{thema}`, `{anzahl}`, `{schwierigkeit}`, `{tippstufe}`, `{farblegende}`) mit Anzeige im Editor
- [ ] Prompt-Editor, Zurücksetzen pro Prompt, Fach-Zusätze, Export/Import als JSON
- [ ] Kurze Prompt-Varianten für das Apple-Modell, Grundregel ungekürzt
- [ ] Sortierte Fassung: Erzeugung, Abschnittsverweise auf Originalstellen, Version bei Neuerzeugung
- [ ] Vollständigkeitsprüfung (Wortabgleich Original ↔ sortierte Fassung) in `StudyCore`, Bestätigung/Korrektur abweichender Stellen
- [ ] Ansicht: Original/sortiert umschaltbar oder nebeneinander, Sprung zur Bildstelle; Hinweis und Aktualisierung bei Korrektur des Originals; Bearbeitung von Hand oder per KI-Anweisung
- [ ] Strukturierung per KI (Weg b) und gemischt (Weg c) inkl. „Nicht zugeordnet“ und leerer vorgegebener Themen; Nutzung von Hervorhebungen
- [ ] Lückenerkennung und -füllung mit Status vorgeschlagen/angenommen/abgelehnt, Begründung, Markierung (Farbe + Symbol); Schalter „nur Hinweis“
- [ ] Quellenprüfung (gültige IDs; Warnung bei fehlender Quelle ohne KI-Ergänzung)
- [ ] Überprüfung und Korrektur (Übersicht offener Ergänzungen, Feldbearbeitung, KI-Anweisung, „Lücken suchen“, Themen verwalten); Lernen erst nach Bestätigung
- [ ] Lerneinheiten mit stabilen IDs (z. B. `T3-B2`), Token-Anzahl, Kurzfassung je Thema, automatische Aktualisierung bei Änderungen
- [ ] Kompaktes Kontextformat (Markdown mit IDs) in `StudyCore`
- [ ] Suchindex (Stichwort) und Embeddings (NLEmbedding Deutsch prüfen, Ergebnis in DECISIONS), kombinierte Suche gefiltert nach Fach/Thema
- [ ] Kontext-Zusammenstellung mit Token-Budget je Modell und Priorität; Kurzfassungen bei Platzmangel; nur bestätigte Ergänzungen

**Abnahmekriterien**
- Grundregel und Ausgabeformat sind in jedem komponierten Prompt enthalten und nicht per Nutzertext entfernbar (Test; auch für gekürzte Apple-Variante).
- Wortabgleich meldet hinzugefügte und fehlende Wörter korrekt (Tests inkl. Umlaute, Groß-/Kleinschreibung, Satzzeichen).
- Mit Mock-Modell: Strukturierung füllt die feste Struktur; Inhalte ohne gültige Quelle und ohne KI-Markierung erzeugen eine Warnung.
- Nicht bestätigte Ergänzungen tauchen in keinem Kontext auf (Test).
- Der Kontext hält das Token-Budget ein und priorisiert wie spezifiziert.
- Tools/Suche liefern nur Inhalte des aktuellen Fachs.
- Entscheidung zu NLEmbedding Deutsch in DECISIONS dokumentiert.

---

## Phase 5 – Multiple Choice, Freitext, Karteikarten, Vorrat, Caching

**Ziel:** Fragen und Karten aus bestätigter Themenstruktur erzeugen, vorab erzeugen und wiederverwenden.

- [ ] Lern-Start: Fach, Themen, Modus, Anzahl (und Schwierigkeit bei MC) wählen
- [ ] Multiple Choice mit Schwierigkeiten leicht/mittel/schwer/gemischt (Schwierigkeit pro Frage gespeichert; schwer: Verknüpfung, Anwendung, Verneinung, optional Mehrfachauswahl, angekündigt)
- [ ] Falsche Optionen nur laut Lernstoff eindeutig falsch
- [ ] Freitext: eine Frage pro Bildschirm, Bewertung anhand des Lernstoffs, Teilkorrektheit, Hinweis „Nicht im Lernstoff enthalten“
- [ ] Karteikarten: Karte umdrehen, Gewusst/Halb gewusst/Nicht gewusst; Begriffe/Definitionen bevorzugt
- [ ] Gewichtung hervorgehobener Inhalte
- [ ] Herkunfts-IDs je Frage/Karte, Anzeige der Stelle (Text und Bild), dezente Markierung bei KI-Ergänzungen
- [ ] Vorab- und Hintergrund-Erzeugung gebündelt, Vorrat speichern und wiederverwenden, Nachgenerierung bei Bedarf
- [ ] Prompt-Caching der Anbieter (stabile Teile am Prompt-Anfang)

**Abnahmekriterien**
- Mit Mock-Modell entstehen Fragen und Karten mit gültigen Herkunfts-IDs; Fragen ohne gültige ID werden verworfen oder gewarnt.
- Fragen entstehen nur aus Original-, Nutzer- und angenommenen Einträgen (Test).
- Schwierigkeit wird gespeichert; „gemischt“ liefert die geforderte Verteilung.
- Eine Session erzeugt keine Wartezeit zwischen Fragen (Vorab-Erzeugung getestet mit Mock-Latenz).
- Bereits erzeugte Fragen werden wiederverwendet, statt neu erzeugt zu werden.
- Prompt-Aufbau stellt gleichbleibende Teile an den Anfang (Test der Komposition).

---

## Phase 6 – Tipps und Chat-Modus

**Ziel:** Gestufte Tipps bei Fehlern und ein Chat-Modus mit Streaming und Tool-Zugriff auf den Lernstoff.

- [ ] Tipp-Stufen 1–3 (Standard), anpassbar oder abschaltbar; Stufen verraten nie mehr als vorgesehen
- [ ] Bei MC: Stufe 2 und 3 grauen je eine falsche Option aus
- [ ] Tipps gehen auf die konkrete falsche Antwort ein; Tipp-Button ohne Fehlversuch; Lösung direkt anzeigen
- [ ] Lösung mit kurzer Erklärung und Verweis auf die Stelle im Lernstoff
- [ ] Vorab-Erzeugung der Tipps zusammen mit MC-Fragen
- [ ] Anzahl benötigter Tipps pro Frage gespeichert
- [ ] Chat-Modus: Frage der KI, Antwort, Nachhaken, Folgefragen, eigene Fragen des Nutzers, Fortschrittsanzeige, Streaming, Verlauf mit der Session gespeichert
- [ ] Gekürzter Verlauf und gezielter Kontext
- [ ] Tools für Modelle mit Tool-Aufrufen (`suche_im_lernstoff`, `hole_thema`, `hole_einheit`, `hole_quelle`); Modelle ohne Tools bekommen den vorab zusammengestellten Kontext
- [ ] Offene Auskunft, wenn etwas nicht im Lernstoff steht

**Abnahmekriterien**
- Tipp-Stufen werden mit Mock-Antworten korrekt angezeigt; Stufe 1 enthält die Lösung nicht (Test mit Prüfung gegen Lösungstext).
- Tipp-Anzahl wird gespeichert; Abschalten und Anpassen der Stufen wirkt.
- Chat streamt schrittweise (Test mit Mock-Stream); Verlauf wird mit der Session gespeichert und gekürzt an die KI gegeben.
- Tools liefern nur Inhalte des aktuellen Fachs und nur bestätigte Einträge (Test).
- Außerhalb des Lernstoffs antwortet der Chat offen „steht nicht im Lernstoff“ (Mock-Szenario).
- Geräteprüfungen MT-6.x (Tastatur im Chat) durchgeführt.

---

## Phase 7 – Leitner, Auswertung, Fortschrittsübersicht

**Ziel:** Lernstand pro Frage/Karte, Verknüpfung mit Tipps, Auswertung nach jeder Session und Fortschrittsübersicht.

- [ ] Leitner-Logik in `StudyCore` (5 Fächer; Gewusst +1, Halb gewusst bleibt, Nicht gewusst → Fach 1)
- [ ] Verknüpfung mit Tipps (erster Versuch ohne Tipp = Gewusst; nach Tipps = Halb gewusst; Lösung gezeigt/alle Stufen falsch = Nicht gewusst)
- [ ] Auswahl der nächsten Fragen: niedrige Fächer häufiger; zusätzliche neue Fragen bei schwachen Themen
- [ ] „Gemischt“: Schwierigkeit passt sich an (gute Themen bekommen mehr schwere Fragen)
- [ ] Auswertung nach jeder Session: gesamt, pro Thema, falsche Fragen, Tipp-Anzahl, Ergebnis je Schwierigkeit
- [ ] Fortschrittsübersicht pro Fach/Thema (Balken, farbliche Markierung)

**Abnahmekriterien**
- Leitner-Übergänge in allen Fällen getestet (inkl. Grenzen Fach 1 und Fach 5).
- Gewichtung der Auswahl getestet (niedrige Fächer häufiger, deterministisch mit festem Seed).
- Auswertung stimmt mit den gespeicherten Antworten überein (Test mit Beispielsession).
- Mischmodus erhöht den Anteil schwerer Fragen bei gut sitzenden Themen (Test).

---

## Phase 8 – Design, Barrierefreiheit, Developer-Modus, Feinschliff

**Ziel:** Farbschemata, Barrierefreiheit und vollständiger Developer-Modus.

- [ ] Farbschemata: Hell, Dunkel, mindestens zwei weitere; in den Einstellungen wählbar
- [ ] Markierung von KI-Ergänzungen und farbige Hervorhebungen in jedem Schema gut erkennbar (Kontrastprüfung)
- [ ] Chat-Optik (Sprechblasen, Eingabefeld unten, Tastatur verdeckt nichts)
- [ ] Dynamic Type; VoiceOver sagt KI-Ergänzungen und Hervorhebungen als solche an
- [ ] Developer-Modus (Schalter, standardmäßig aus): Info pro Anfrage (Anbieter, Modell, Reasoning, Tokens inkl. Cache/Reasoning, Kosten €/$, Dauer, Zeit bis zum ersten Token, Tokens/s, Apple-Tokens zur Kontextgröße ab iOS 26.4, gesendete Inhalte, Kontext-IDs, Tools, System-Prompt, Prompt, rohe Antwort kopierbar, Reasoning-Inhalte, Parsing-Fehler, Quellenprüfungs-Warnungen)
- [ ] Übersicht: Kosten/Tokens pro Session, Tag, Monat nach Anbieter, Modell, Aufgabe; Liste letzter Anfragen
- [ ] Vergleich der Digitalisierung pro Quelle (Vision, KI, manuell) mit Overlay
- [ ] Statistik pro Modell: Anteil Inhalte ohne gültige Quelle, manuelle Korrekturen
- [ ] Qualitätstest der Texterkennung (Referenztext, Zeichen-/Wortfehlerquote pro Methode, mehrere KI-Durchläufe, iOS-Version und Gerät)
- [ ] Preistabelle bearbeitbar, Standardwerte, „geschätzt“-Kennzeichnung
- [ ] Export des Anfrage-Logs als JSON, Logs löschen
- [ ] Feinschliff (Fehlerzustände, leere Zustände, Performance, Lokalisierung)

**Abnahmekriterien**
- Fehlerquoten (CER/WER) werden gegen Referenztexte korrekt berechnet (Unit-Tests mit bekannten Werten).
- Kostenberechnung stimmt für bekannte, unbekannte und kostenlose Modelle (Tests).
- Log-Export ist gültiges JSON und enthält keine Keys oder Header-Secrets (Test).
- UI-Tests laufen in allen Farbschemata; Geräteprüfungen MT-8.x (VoiceOver, Dynamic Type, Kontrast) durchgeführt.

---

## Phase 9 – Hugging-Face-Download und lokale Ausführung

**Ziel:** Hugging-Face-Modelle in der App herunterladen und lokal mit MLX Swift ausführen.

- [ ] Modellsuche/-auswahl mit Anzeige von Größe und Speicherbedarf vor dem Download
- [ ] Download mit Fortschritt, Abbruch, Fortsetzen, Löschen
- [ ] MLX-Swift-Anbieter hinter dem gemeinsamen Protokoll (Streaming, Metadaten, 0 €)
- [ ] Fähigkeiten (Bilder, Tools, Kontextgröße) aus Modellmetadaten bzw. Einstellung
- [ ] Speicher-/Abbruchbehandlung bei zu wenig Arbeitsspeicher

**Abnahmekriterien**
- Der Anbieter erfüllt dieselben Protokolltests wie das Mock-Modell (Streaming, Metadaten, Fehlerfälle).
- Größe und Speicherbedarf erscheinen vor dem Download; Abbruch hinterlässt keine halben Dateien.
- Geräteprüfungen MT-9.x (Download, Speicher, Laufzeit) durchgeführt.
