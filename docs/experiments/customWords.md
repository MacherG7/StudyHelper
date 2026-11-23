# Experiment: Wirkung von `customWords` bei Vision

Auftrag (SPEC §2, "Absicherung der Erkennung"): Bereits bestätigte Fachbegriffe des Fachs als `customWords` an Vision
übergeben, Wirkung testen und dokumentieren.

## Aufbau

- Test: `Packages/StudyHelperCore/Tests/StudyImportTests/RecognitionCustomWordsExperiment.swift`
  (läuft nur mit `CUSTOMWORDS_EXPERIMENT=1 swift test --filter RecognitionCustomWordsExperiment`, gibt die Tabelle aus
  und prüft nichts am Verhalten von Vision, weil das vom System abhängt).
- Erkennung: `VisionTextRecognizer` (`VNRecognizeTextRequest`, genau, Revision 3, `de-DE`), 5 Kandidaten je Zeile.
- Testbild: dieselbe synthetische "Handschrift" wie in den Goodnotes-Fixtures (Umrisse von Noteworthy-Light, 1,6 pt
  gezeichnete Linie, schwarz auf weiß), Wort für Wort bzw. als Satz "Die <Begriff> ist wichtig".
- Fachbegriffe (8): Thylakoidmembran, Chlorophyllmolekül, Mitochondrienmatrix, Plastochinon, Ribulosebisphosphat,
  Stromathylakoid, Calvin-Zyklus, Photosystem.
- Umgebung: macOS 27.0 (Mac, `Mac16,12`), Xcode 27.2 SDK, Vision-Revision 3. Auf dem Gerät unter iOS 27 kann das Ergebnis
  anders ausfallen (siehe SPEC: Vision-Verschlechterung nur auf echter Hardware), daher in `docs/MANUAL_TESTS.md` prüfen.

## Varianten

1. ohne `customWords`, Sprachkorrektur an (Referenz)
2. ohne `customWords`, Sprachkorrektur aus
3. `customWords = [Begriff]`, Sprachkorrektur an
4. `customWords = [Begriff]`, Sprachkorrektur aus
5. `customWords` = alle 8 Begriffe, Sprachkorrektur an
6. `customWords = [Begriff, begriff]` (zusätzlich klein geschrieben), Sprachkorrektur an

## Ergebnisse

Einzelne Wörter, 8 Begriffe x Schriftgröße 12/16/22 pt = 24 Fälle je Variante, 3 Pixel pro Punkt:

| Variante | exakt | Summe Editierabstand zum richtigen Wort |
|---|---|---|
| 1 ohne, Korrektur an | 16/24 | 10 |
| 2 ohne, Korrektur aus | 15/24 | 12 |
| 3 [Begriff], Korrektur an | 16/24 | 9 |
| 4 [Begriff], Korrektur aus | 15/24 | 12 |
| 5 alle 8, Korrektur an | 16/24 | 9 |
| 6 Begriff + klein, Korrektur an | 16/24 | 9 |

Sehr kleine Schrift (9/10/11 pt), 24 Fälle:

| Auflösung | Variante | exakt | Summe Editierabstand |
|---|---|---|---|
| 2 px/pt | 1 ohne | 9/24 | 30 |
| 2 px/pt | 3 [Begriff] | 11/24 | 26 |
| 2 px/pt | 5 alle 8 | 11/24 | 26 |
| 3 px/pt | 1 ohne | 10/24 | 34 |
| 3 px/pt | 3 [Begriff] | 10/24 | 29 |
| 3 px/pt | 5 alle 8 | 10/24 | 29 |

Begriff in einem Satz (Größe 16 pt): ohne `customWords` 5/8 Begriffe exakt, mit `[Begriff]` 6/8 (Ribulosebisphosphat
wird dann richtig gelesen, ohne "Ribulosebiephosphat").

Nebenwirkungen: 10 gewöhnliche Wörter (Membran, Photosynthese, Stroma, Zellkern, ...) in 3 Größen (30 Fälle) mit und ohne die 8
`customWords`: 0 abweichende Lesungen, die Begriffe ziehen andere Wörter also nicht an sich.

## Fazit

- Die Wirkung ist klein, aber positiv: `customWords` korrigiert einzelne Buchstabenfehler in Fachwörtern, wenn Vision
  ohnehin fast richtig liegt (Editierabstand sinkt um etwa 10 bis 15 Prozent, bei sehr kleiner Schrift bis zu 2 zusätzliche
  exakte Treffer von 24). Bei gut lesbarer Schrift ändert sich praktisch nichts.
- Fehler durch Zeichen, die Vision verwechselt (hier immer **ü → a**: "Chlorophyllmolekal"), werden **nicht** behoben, auch nicht,
  wenn das richtige Wort in `customWords` steht. Die Wörter werden nicht ersetzt, sondern nur bei der Sprachkorrektur
  bevorzugt.
- `customWords` wirkt nur mit eingeschalteter Sprachkorrektur (Varianten 2 und 4 sind gleich). Die Sprachkorrektur selbst
  hilft hier kaum (16 gegen 15 exakte Treffer).
- Mehrere Begriffe gleichzeitig (Variante 5) schaden nicht und helfen genauso wie der einzelne Begriff. Zusätzliche
  Kleinschreibung (Variante 6) bringt nichts.
- Keine erkennbaren Nebenwirkungen auf andere Wörter.

Entscheidung für die App: Bestätigte Fachbegriffe des Fachs immer als `customWords` mitgeben (kostet nichts, schadet nicht,
hilft bei kleiner Schrift). Man darf sich nicht darauf verlassen: Vision-Fehler bei Umlauten bleiben, deshalb bleiben
Konfidenz, Kandidaten, Abgleich mit dem reduzierten Goodnotes-PDF und die manuelle Korrektur nötig. Die Anzahl der
übergebenen Wörter steht in `RecognitionMetadata.customWordsCount`.

## Nebenbefund: `RecognizeDocumentsRequest` (iOS/macOS 26+)

- Die Anfrage liefert Wortrechtecke (`RecognizedText.boundingBox(for:)`), Titel, Absätze, Listenpunkte und Tabellenzellen.
  Auf dem gedruckten Arbeitsblatt (`Arbeitsblatt_digital.pdf` gerendert) erkennt sie Listen (5 Punkte) und eine
  Tabelle (9 Zellen) korrekt. Die Titel-Eigenschaft (`isTitle`) war dort nicht gesetzt.
- Ihre Konfidenzwerte liegen deutlich niedriger als bei `VNRecognizeTextRequest` (0,3 bis 0,7 für richtig gelesene Zeilen,
  die klassische Anfrage liefert hier meist 1,0), und auf der synthetischen Handschrift hat sie kurze Zeilen
  zusammengefasst ("c) Zellwand") oder ausgelassen ("a)"). Auf Handschrift erkennt sie keine Tabellen (die handgezeichnete
  Tabelle bleibt Absätze).
- Daher: Text, Konfidenz und Wortrechtecke kommen immer aus der klassischen Anfrage; die Dokumentanfrage ergänzt nur die
  Zeilenart (`blockKind`) und läuft nicht auf den Goodnotes-Tintenebenen.
