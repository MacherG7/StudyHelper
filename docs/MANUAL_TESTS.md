# StudyHelper – Manuelle Prüfungen auf dem Gerät

Diese Prüfungen lassen sich nicht automatisieren (echte Goodnotes-Exporte, Gerätehardware, iOS-Verhalten). Echte Exporte bleiben in `LocalSamples/` (gitignored) und werden **nie** committet.

## Ergebnisse festhalten

Pro Prüfpunkt in der Spalte „Ergebnis“ eintragen: `Datum · Gerät · iOS-Version · ✅/❌ · Notiz`, z. B. `2026-12-01 · iPhone 16 Pro · 27.2 · ✅ · –`. Bei ❌ eine kurze Beschreibung und, falls sinnvoll, einen Eintrag in `docs/DECISIONS.md` (offene Punkte) oder ein Issue anlegen. Messwerte (Anzahl Ink-Annotationen, Strichbreiten, `/Producer` usw.) direkt in die Notiz schreiben.

---

## Phase 0 – Gerüst und Fixtures

| ID | Prüfung | Erwartung | Ergebnis |
|---|---|---|---|
| MT-0.1 | `Fotosynthese_bearbeitbar.pdf` in Vorschau (Mac) und Dateien-App (iPhone/iPad) öffnen | Linienpapier, Ink in vier Farben (schwarz, rot, blau, grün), gelber Textmarker transparent (Text darunter lesbar), FreeText mit CO₂-Formel, Pfeil, alle drei Seiten sichtbar | |
| MT-0.2 | Seite 2 (Arbeitsblatt) ansehen | Bild und Text (inkl. fett und farbig) sichtbar, Ink-Antworten, eingekreistes Wort, doppelte Unterstreichung | |
| MT-0.3 | Seite 3 ansehen | Mindmap und Tabelle erkennbar | |
| MT-0.4 | `Fotosynthese_reduziert.pdf` öffnen | Keine Annotationen; Text lässt sich markieren und durchsuchen; Fehlerwörter („grune“, „Chlorophyl“ usw.) auffindbar | |
| MT-0.5 | `Andere_Notiz_reduziert.pdf` öffnen | 1 Seite, anderer Inhalt | |
| MT-0.5b | `Andere_Groesse_reduziert.pdf` öffnen | 3 Seiten im US-Letter-Format, Text markierbar | |
| MT-0.6 | App im Simulator starten (iPhone und iPad) | Deutscher Platzhalter („StudyHelper“ / „Noch keine Fächer“) | |
| MT-0.7 | App auf echtem iPhone und iPad starten | Wie MT-0.6; Signierung mit Team funktioniert | |

---

## Phase 1 – Goodnotes-Exporte, „Öffnen in“, Vision

Voraussetzung: eigene echte Exporte derselben Notiz als „bearbeitbares PDF“ und als „reduziertes PDF“, abgelegt in `LocalSamples/`.

### Bearbeitbares PDF (Struktur)

| ID | Prüfung | Erwartung / Notiz | Ergebnis |
|---|---|---|---|
| MT-1.1 | Anzahl Ink-Annotationen pro Seite zählen | Plausibel: ein Strich = eine Annotation? Abweichungen notieren (z. B. mehrere Striche pro Annotation) | |
| MT-1.2 | Farben (`/C`) der Ink-Annotationen | Wie in Goodnotes gewählt; RGB-Werte der verwendeten Stifte notieren | |
| MT-1.3 | Strichbreiten (`/BS /W`) | Wie erwartet; Werte je Stift notieren | |
| MT-1.4 | Textmarker | Gelb, Breite ca. 18 pt? Wird Transparenz über `/CA` oder einen Blend-Mode (`/BM` im Appearance Stream) erzeugt? Beides notieren | |
| MT-1.5 | FreeText-Annotation (getipptes Textfeld) | `/Contents` exakt wie getippt (inkl. Umlaute, Sonderzeichen) | |
| MT-1.6 | Formwerkzeug (Pfeile, Linien) | Als Stamp-Annotation? Falls anderer Typ, Typ notieren | |
| MT-1.7 | Eingefügte Bilder und Arbeitsblätter | Als Seiteninhalt; bei Arbeitsblättern mit eigenem Text: Text im PDF vorhanden und extrahierbar? | |
| MT-1.8 | `/Producer` und `/Creator` im Dokumentinfo-Dictionary | Werte notieren (Grundlage der Format-Erkennung, siehe DECISIONS) | |

### Reduziertes PDF

| ID | Prüfung | Erwartung / Notiz | Ergebnis |
|---|---|---|---|
| MT-1.9 | Annotationen | Keine vorhanden | |
| MT-1.10 | Textebene | Handschrift-Text mit Positionen vorhanden; grobe Fehlerquote einschätzen (Anteil falscher Wörter) | |
| MT-1.11 | `/Producer` und `/Creator` | Notieren; Unterschied zum bearbeitbaren PDF? | |

### Zuordnung und Import

| ID | Prüfung | Erwartung / Notiz | Ergebnis |
|---|---|---|---|
| MT-1.12 | Beide Exporte derselben Notiz importieren | App erkennt beide Formate, schlägt Zuordnung vor (gleiche Seitenzahl/-größe), Bestätigungsdialog erscheint | |
| MT-1.13 | Exporte verschiedener Notizen importieren | Keine automatische Zuordnung ohne Bestätigung; Ablehnen möglich | |
| MT-1.14 | „Öffnen in“: Goodnotes → „Teilen → Exportieren → PDF“ → „In StudyHelper öffnen“ (keine Share-Extension, siehe D-013) | StudyHelper erscheint im Teilen-Menü; PDF wird übernommen, Fach-Auswahl erscheint, Import startet | |
| MT-1.15 | Notiz mit mehreren Seitengrößen | Import und Zuordnung verhalten sich nachvollziehbar (Warnung statt Absturz) | |
| MT-1.16 | Sehr lange Notiz (z. B. 50+ Seiten) | Import und Digitalisierung laufen ohne Absturz; Fortschritt sichtbar; Zeit und Speicher notieren | |
| MT-1.17 | `.goodnotes`-Datei teilen/öffnen | Wird sauber abgelehnt mit verständlicher Meldung | |

### Vision und Digitalisierung

| ID | Prüfung | Erwartung / Notiz | Ergebnis |
|---|---|---|---|
| MT-1.18 | Umlaute und ß in echter Handschrift (Ä Ö Ü ä ö ü ß) | Erkennungsqualität notieren; Fehlerarten (z. B. ü → u) | |
| MT-1.19 | Genauer Modus auf **echtem Gerät unter iOS 27** vs. Simulator | Berichtete Regression nur auf Geräten: pro Lauf Vision-Revision, iOS-Version und Gerät notieren; Vergleich mit Simulatorergebnis | |
| MT-1.20 | `customWords`-Wirkung | Gleiche Seite mit und ohne bestätigte Fachbegriffe erkennen; Unterschied dokumentieren (DECISIONS) | |
| MT-1.21 | `RecognizeDocumentsRequest` (ab iOS 26) bei Tabellen und Listen | Struktur (Zeilen/Zellen, Listenpunkte) wird erkannt; Vergleich mit reiner Textzeilen-Erkennung | |
| MT-1.22 | Kamera-Import (Foto) | Funktioniert nur auf Gerät; Berechtigungsdialog deutsch | |
| MT-1.23 | Dokumentenscanner (VisionKit) | Mehrseitiger Scan wird als Quellen importiert; nur auf Gerät | |
| MT-1.24 | Fotomediathek-Import | Auswahl mehrerer Fotos, Reihenfolge bleibt erhalten | |
| MT-1.25 | App per Xcode neu installieren (z. B. nach Ablauf des 7-Tage-Profils) | Fächer, Importe, Digitalisierungen, Korrekturen und Themen sind noch vorhanden | |
| MT-1.26 | Reduziertes PDF allein importieren | Wird als reduziertes Goodnotes-PDF erkannt (unsichtbare Textebene, Render-Modus 3?) und nicht als normales PDF | |
| MT-1.27 | Textmarker an echten Exporten | Markierte Wörter korrekt zugeordnet, nur gestreifte Nachbarwörter nicht; runde Strichenden oder andere Deckkraft ändern das Ergebnis nicht | |
| MT-1.28 | Unterstreichungen, doppelte Unterstreichungen, Kreise in echter Handschrift | Werden erkannt; kurze Unterstreichungen als „unsicher“; aus mehreren Strichen zusammengesetzte Linien und Zickzack notieren | |
| MT-1.29 | Gedrehte Seiten (`/Rotate`) in Goodnotes-Exporten | Verhalten notieren (Drehung wird derzeit nicht berücksichtigt) | |
| MT-1.30 | PDF über „Dateien“ importieren, dazu das reduzierte Goodnotes-PDF als zweite Datei | Zuordnungsdialog nennt beide Seitenzahlen; bei Abweichung Erklärung und Import ohne Zuordnung | |
| MT-1.31 | Import während der Erkennung abbrechen, App neu öffnen | Bereits erkannte Seiten bleiben; offene Seiten zeigen „Jetzt erkennen“ | |
| MT-1.32 | Prüfansicht auf iPhone und iPad, hell und dunkel | Markierungen liegen exakt auf den Zeilen (auch gezoomt); Textmarker, Unterstreichung, unsicher/unleserlich in beiden Modi gut erkennbar | |
| MT-1.33 | VoiceOver in der Prüfansicht | Zeilen werden mit Status („unsicher“, „korrigiert“) und Hervorhebung („Textmarker“, „Überschrift“) angesagt | |
| MT-1.34 | „Neu erkennen“ für eine Seite und für den ganzen Import | Hinweis auf erhaltene Korrekturen; alte Version unter „Versionen“ wiederherstellbar; nicht zuordenbare Korrekturen werden angezeigt | |
| MT-1.35 | Zwei PDFs nacheinander per „Öffnen in“ teilen (bearbeitbar, dann reduziert) | Beide erscheinen nacheinander im Import-Blatt; keine Datei geht verloren | |
| MT-1.36 | Dokumentenscanner abbrechen bzw. Fehler provozieren | Verständliche deutsche Meldung, App bleibt bedienbar | |
| MT-1.37 | VoiceOver während eines Imports | Start, Fortschritt (25/50/75 %) und Ende werden angesagt | |
| MT-1.38 | Thema anlegen und Einträge aus der Quelle übernehmen (iPad nebeneinander, iPhone umschaltbar) | Übernahme per Zeilen- und Wortauswahl; Vorschläge aus Hervorhebungen erscheinen; Layout auch bei großer Schrift bedienbar | |
| MT-1.39 | VoiceOver im Themen-Editor und in der Themenprüfung | Herkunft (Original/Eigene Eingabe) und Hervorhebung werden angesagt; Übernahme wird angesagt | |
| MT-1.40 | Zeile korrigieren, die in einem Thema verwendet wird | Hinweis „Betroffene Themen“; im Thema „Quelle geändert“ mit „Text aus Quelle übernehmen“ | |
| MT-1.41 | Tabellen-Eintrag auf iPhone und iPad bearbeiten | Zeilen/Spalten hinzufügen und entfernen funktioniert, nichts abgeschnitten | |
| MT-1.42 | Dichten Goodnotes-Export mit Handschrift importieren (z. B. `LocalSamples/GPG_bearbeitbar.pdf`) | Keine ganzen Zeilen fehlen, keine Zeile mit kyrillischen Zeichen, „unleserlich“ nie über mehrere Zeilen; nachgelesene Zeilen erscheinen als „unsicher“ | |

---

## Mindestversion iOS 18

| ID | Prüfung | Erwartung | Ergebnis |
|---|---|---|---|
| MT-M.1 | App auf iOS-18-Gerät oder iOS-18-Simulator-Runtime installieren und starten (lokal nicht installiert, siehe D-010) | Start ohne Absturz; alle Phase-1-Abläufe funktionieren (ohne `RecognizeDocumentsRequest`) | |
| MT-M.2 | Anbieter-Einstellungen unter iOS 18 | Anbieterliste ohne Apple Foundation Model; kein Hinweis auf nicht verfügbare Funktionen, der verwirrt | |
| MT-M.3 | Gerät mit iOS 26.0–26.3 | Apple-Modell nur mit korrekter Verfügbarkeitsprüfung; kein Zugriff auf `tokenCount(for:)`/`contextSize` (ab 26.4) | |

---

## Phase 2 – Anbieter

| ID | Prüfung | Erwartung | Ergebnis |
|---|---|---|---|
| MT-2.1 | Gerät **mit** Apple Intelligence | Apple Foundation Model wählbar, Antwort kommt | |
| MT-2.2 | Gerät **ohne** Apple Intelligence bzw. mit deaktivierter Funktion | Modell nicht wählbar oder mit klarem Hinweis; App stürzt nicht | |
| MT-2.3 | Modell zeitweise nicht verfügbar (z. B. wird geladen) | Verständliche Meldung, Fallback auf anderen Anbieter möglich | |
| MT-2.4 | Echte API-Keys (Claude, OpenAI) nur auf dem Gerät in den Einstellungen eingeben | Key liegt in der Keychain; nach App-Neustart verfügbar; nirgends im Klartext sichtbar (Logs, Export) | |
| MT-2.5 | Modellliste per API abrufen | Verfügbare Modelle erscheinen; Reasoning-Stufen nur wenn vom Modell unterstützt | |
| MT-2.6 | Selbst gehostetes Modell (z. B. Ollama im lokalen Netz) | Verbindung, Bildfähigkeit automatisch erkannt, Streaming sichtbar | |

---

## Phase 3 – Hervorhebungen (Platzhalter)

| ID | Prüfung | Erwartung | Ergebnis |
|---|---|---|---|
| MT-3.1 | Echtes Foto einer Buchseite mit Unterstreichung, Textmarker, farbiger Schrift | Bildanalyse-Fallback erkennt Hervorhebungen, als „unsicher“ markiert | |
| MT-3.2 | Handschrift-Foto mit bildfähigem KI-Modell transkribieren | Hervorhebungen und Struktur plausibel; Qualität im Vergleich zu Vision notieren | |
| MT-3.3 | Overlay der Hervorhebungen auf dem Originalbild | Positionen stimmen auf Foto und auf iPad-Querformat | |

## Phase 4 – Prompts, sortierte Fassung, Strukturierung (Platzhalter)

| ID | Prüfung | Erwartung | Ergebnis |
|---|---|---|---|
| MT-4.1 | Echtes Modell: Strukturierung eines eigenen Lernstoffs | Keine Inhalte außerhalb des Lernstoffs; Lücken als KI-Ergänzung markiert | |
| MT-4.2 | Apple On-Device-Modell mit gekürztem Prompt | Grundregel wirkt trotz kleinem Kontext; Kontextgröße reicht | |
| MT-4.3 | Sortierte Fassung einer echten Mindmap | Wortabgleich meldet plausible Abweichungen; Sprung zur Bildstelle funktioniert | |

## Phase 5 – Fragen und Karten (Platzhalter)

| ID | Prüfung | Erwartung | Ergebnis |
|---|---|---|---|
| MT-5.1 | Session mit echtem Modell | Keine spürbare Wartezeit zwischen Fragen (Vorab-Erzeugung) | |
| MT-5.2 | Schwere MC-Fragen | Alle vollständig mit dem Lernstoff beantwortbar; Verneinungsfragen korrekt | |
| MT-5.3 | Karteikarten-Umdrehen auf iPhone und iPad | Geste und Animation flüssig | |

## Phase 6 – Tipps und Chat (Platzhalter)

| ID | Prüfung | Erwartung | Ergebnis |
|---|---|---|---|
| MT-6.1 | Chat: Tastatur öffnen | Eingabefeld bleibt sichtbar, letzte Nachricht wird nicht verdeckt | |
| MT-6.2 | Streaming im Chat bei langsamer Verbindung | Text erscheint schrittweise, Abbruch möglich | |
| MT-6.3 | Frage außerhalb des Lernstoffs im Chat | KI sagt offen, dass es nicht im Lernstoff steht | |
| MT-6.4 | Tipp-Stufe 1 bei echtem Modell | Verrät die Antwort nicht | |

## Phase 7 – Leitner und Auswertung (Platzhalter)

| ID | Prüfung | Erwartung | Ergebnis |
|---|---|---|---|
| MT-7.1 | Mehrere Sessions an verschiedenen Tagen | Niedrige Fächer kommen häufiger; Fortschrittsbalken plausibel | |
| MT-7.2 | Auswertung nach Session | Zahlen stimmen mit eigenem Mitzählen überein | |

## Phase 8 – Design, Barrierefreiheit, Developer-Modus (Platzhalter)

| ID | Prüfung | Erwartung | Ergebnis |
|---|---|---|---|
| MT-8.1 | VoiceOver: KI-Ergänzungen und Hervorhebungen | Werden als „KI-Ergänzung“ bzw. „Hervorhebung (Art)“ angesagt | |
| MT-8.2 | Dynamic Type bis größte Stufe | Kein abgeschnittener Text, Layout bricht nicht (iPhone und iPad) | |
| MT-8.3 | Alle Farbschemata: Kontrast von KI-Ergänzungs-Markierung und farbigen Hervorhebungen | In jedem Schema klar erkennbar, auch bei Helligkeit niedrig/hoch | |
| MT-8.4 | Developer-Modus: Kosten und Tokens bei echten Anfragen | Werte stimmen größenordnungsmäßig mit dem Anbieter-Dashboard überein | |
| MT-8.5 | Qualitätstest der Texterkennung nach einem iOS-Update | Fehlerquoten pro Methode, iOS-Version und Gerät werden gespeichert und verglichen | |
| MT-8.6 | Apple-Modell: Tokens zu Kontextgröße (ab iOS 26.4) | Anzeige plausibel; unter älteren Versionen ausgeblendet | |

## Phase 9 – Hugging Face lokal (Platzhalter)

| ID | Prüfung | Erwartung | Ergebnis |
|---|---|---|---|
| MT-9.1 | Anzeige von Größe und Speicherbedarf vor dem Download | Werte plausibel zur tatsächlichen Dateigröße; Warnung bei zu wenig freiem Speicher | |
| MT-9.2 | Modell laden und Antworten erzeugen | Läuft ohne Absturz; Arbeitsspeicherverbrauch und Tempo notieren (iPhone vs. iPad) | |
| MT-9.3 | Download abbrechen und fortsetzen | Keine halben Dateien; Fortsetzen funktioniert | |
| MT-9.4 | Modell löschen | Speicher wird freigegeben | |
