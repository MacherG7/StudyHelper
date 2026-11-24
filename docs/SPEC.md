# StudyHelper – Spezifikation

> Wortgetreue Ablage der Anforderungen, wie sie zum Projektstart geliefert wurden
> (23.11.2026). Der Anfang des ersten Satzes fehlt in der Vorlage und ist mit […]
> gekennzeichnet. Änderungen an den Anforderungen bitte hier und in
> `docs/DECISIONS.md` nachvollziehbar festhalten.

[…] Lernstoff ein (Fotos von Buchseiten, handschriftliche PDFs, Mindmaps, Tabellen),
der einmalig digitalisiert und dauerhaft als Text gespeichert wird, inklusive
Hervorhebungen wie Unterstreichungen, Fettschrift und Farben. Den Lernstoff
strukturieren die Schüler selbst oder lassen ihn von einer KI in Themen
strukturieren und lernen ihn dann mit KI-Abfragen, einem Chat-Modus oder
Karteikarten. Bei falschen Antworten gibt es gestufte Tipps. Die App merkt sich,
was man kann, und fragt Schwächen häufiger ab.

## Grundregel: Nur Inhalte aus dem Lernstoff
Diese Regel gilt für alle KI-Aufgaben der App und hat Vorrang vor allem anderen:
- Die KI verwendet ausschließlich Informationen, die im importierten Lernstoff
  enthalten sind. Kein Allgemeinwissen, keine Zusatzinformationen, keine
  weiterführenden Erklärungen, keine eigenen Beispiele, die nicht im Lernstoff stehen.
- Jeder Inhalt eines Themas verweist auf die Quelle (Seite/Bild), aus der er stammt.
- Ausnahme Lücken: Ist der Lernstoff erkennbar unvollständig (z. B. abgeschnittener
  Satz, Begriff ohne Definition, Formel wird erwähnt, fehlt aber, Tabelle mit
  leeren Zellen, Aufzählung bricht ab), darf die KI die Lücke füllen. Dabei gilt:
  - Ergänzungen werden immer als "KI-Ergänzung" gespeichert und in der App
    deutlich sichtbar markiert (eigene Farbe und Symbol), getrennt vom Original
  - Die KI nennt zu jeder Ergänzung, welche Lücke sie gefüllt hat und warum
  - Ergänzungen sind zunächst nur Vorschläge. Der Nutzer muss jede einzeln
    annehmen, bearbeiten oder ablehnen.
  - Nicht bestätigte Ergänzungen werden nie für Fragen, Karteikarten, Tipps oder
    Chat-Antworten verwendet
  - Auch angenommene Ergänzungen bleiben dauerhaft als KI-Ergänzung markiert
- Keine Lücke ist es, wenn ein Thema einfach kurz ist. Die KI ergänzt nur, was
  im Lernstoff selbst erkennbar fehlt, nicht was "noch dazu passen würde".
- Unleserliche Stellen bei der Digitalisierung sind keine Lücken. Sie werden als
  "unleserlich" markiert und vom Nutzer korrigiert, nicht von der KI erraten.
- In den Einstellungen kann das Füllen von Lücken ganz abgeschaltet werden. Dann
  meldet die KI erkannte Lücken nur als Hinweis, ohne sie zu füllen.
- Beim Erstellen von Fragen und Karteikarten: Fragen und richtige Antworten
  stammen nur aus dem Lernstoff (bzw. bestätigten Ergänzungen). Falsche
  Antwortoptionen bei Multiple Choice dürfen neu formuliert sein, müssen aber
  laut Lernstoff eindeutig falsch sein.
- Beim Bewerten von Antworten gilt der Lernstoff als Maßstab. Eine Antwort, die
  inhaltlich richtig ist, aber über den Lernstoff hinausgeht, wird nicht als
  falsch gewertet, sondern mit dem Hinweis "Nicht im Lernstoff enthalten" versehen.
- Tipps, Erklärungen und Chat-Antworten verwenden ebenfalls nur den Lernstoff.
  Fragt der Nutzer im Chat etwas, das nicht im Lernstoff steht, sagt die KI das
  offen, statt mit eigenem Wissen zu antworten.
- Diese Regel steht fest in den System-Prompts und ist nicht vom Nutzer
  entfernbar (siehe Abschnitt 4).
- Wo möglich, prüft die App die Antworten der KI zusätzlich technisch, z. B. ob
  jeder Inhalt eine gültige Quellenangabe hat. Inhalte ohne Quelle, die nicht als
  KI-Ergänzung markiert sind, werden als Warnung zur Überprüfung angezeigt.

## Technische Vorgaben
- Mindestversion iOS 18, SwiftUI, SwiftData für die Persistenz
- Swift Testing für Unit-Tests, XCTest nur für UI-Tests
- API-Keys ausschließlich in der Keychain speichern, niemals in UserDefaults,
  im Code oder in Logs
- Alle KI-Anbieter hinter einem gemeinsamen Protokoll, damit die restliche App
  nicht weiß, welches Modell antwortet. Zu jeder Antwort gibt das Protokoll ein
  Metadaten-Objekt zurück (Anbieter, Modell, Reasoning-Stufe, Tokens, Dauer usw.),
  damit alle Anbieter einheitlich erfasst werden.
- Das Protokoll unterstützt Streaming, damit Antworten im Chat-Modus
  schrittweise erscheinen, und Tool-Aufrufe (Function Calling) für Modelle, die
  das können (siehe "Zugriff der KI auf den Lernstoff")
- Für Tests ein Mock-Modell mit festen Antworten. Unit-Tests rufen niemals echte
  Modelle oder APIs auf.
- Apple Foundation Models nur hinter `#available(iOS 26, *)` und nach Prüfung von
  `SystemLanguageModel.default.availability`. Auf Geräten ohne Apple Intelligence
  oder mit älterem iOS stehen nur die anderen Anbieter zur Auswahl.
- Die Modellausgaben möglichst strukturiert anfordern (Guided Generation bei Apple,
  JSON bei den anderen) und robust parsen. Fehlerhafte Ausgaben dürfen die App
  nicht abstürzen lassen.
- Für API-Parameter (Modellliste, Reasoning, Usage-Angaben, Streaming) die aktuelle
  offizielle Dokumentation von Anthropic und OpenAI verwenden, nicht Annahmen
  aus dem Gedächtnis.
- Die App-Sprache ist Deutsch.


## Funktionen

### 1. Lernstoff importieren
- Fotos (Kamera und Fotomediathek), PDFs, Dokumentenscanner (VisionKit)
- Goodnotes-Exporte als PDF (siehe "Goodnotes-Import" unten), auch per
  Share-Extension: In Goodnotes "Teilen → Exportieren → PDF" und direkt
  StudyHelper auswählen
- Lernstoff wird einem Fach zugeordnet (z. B. Mathe, Deutsch, Englisch), Fächer
  können angelegt und bearbeitet werden
- PDF-Seiten mit PDFKit als Bilder rendern. Bei PDFs mit eingebettetem Text
  (z. B. digitale Arbeitsblätter) diesen Text direkt übernehmen, inkl.
  Formatierung, statt ihn per Texterkennung zu lesen.
- Jede importierte Seite bzw. jedes Bild bleibt als Quelle gespeichert und wird
  direkt nach dem Import digitalisiert (siehe Abschnitt 2)
- Nach dem Import wählt der Nutzer, wie der Lernstoff strukturiert wird
  (siehe Abschnitt 5)

Goodnotes-Import:
- Hauptformat ist das "bearbeitbare" PDF. Nach meiner Analyse ist dort jeder
  Strich eine PDF-Ink-Annotation mit Punkten (/InkList), Farbe (/C) und
  Strichbreite (/BS /W). Textmarker sind gelbe Ink-Annotationen mit großer
  Breite (ca. 18 pt). Getippte Textfelder sind FreeText-Annotationen mit exaktem
  Text (/Contents). Mit dem Formwerkzeug gezeichnete Pfeile und Linien sind
  Stamp-Annotationen. Eingefügte Bilder und Arbeitsblätter sind Seiteninhalt,
  teils mit eigenem Text.
- Optional zusätzlich das "reduzierte" (unveränderliche) PDF derselben Notiz:
  Es enthält den von Goodnotes erkannten Handschrift-Text als Textebene mit
  Positionen, aber keine Annotationen. Dieser Text ist fehlerhaft und wird nur
  zum Abgleich genutzt (siehe Abschnitt 2).
- Die App erkennt, welches Format vorliegt, und ordnet beide Exporte derselben
  Notiz einander zu (gleiche Seitenzahl und Seitengröße, Bestätigung durch den
  Nutzer).
- .goodnotes-Dateien werden nicht unterstützt (proprietäres, undokumentiertes
  Format).
- Es gibt keine echten Goodnotes-Dateien im Repository, und es sollen auch keine
  hinzugefügt werden. Für die automatischen Tests erzeugst du künstliche
  Test-PDFs mit der oben beschriebenen Struktur (Ink-Annotationen in mehreren
  Farben, Textmarker, FreeText, Stamp) sowie ein passendes reduziertes PDF mit
  Textebene. Den Import mit echten Goodnotes-Exporten teste ich selbst auf dem
  Gerät, nimm dafür Prüfpunkte in docs/MANUAL_TESTS.md auf.

### 2. Digitalisierung und gespeicherter Text
Jede Quelle wird einmalig in Text umgewandelt, und das Ergebnis wird dauerhaft
gespeichert. Alle späteren Schritte (Strukturierung, Fragen, Tipps, Chat,
Bewertung, Fehlersuche) verwenden diesen gespeicherten Text und lösen keine
erneute Texterkennung aus.

Was pro Quelle gespeichert wird:
- Der Originaltext: der erkannte Text so, wie er im importierten PDF bzw. Bild
  steht, wortgetreu und in der Reihenfolge und Anordnung der Vorlage, als
  Markdown mit Formatierung (Überschriften, Listen, Tabellen, Hervorhebungen)
- Die sortierte Fassung (siehe "Originaltext und sortierte Fassung" unten),
  getrennt vom Originaltext
- Die Position jeder Textzeile im Bild (Bounding Boxes), damit Inhalte später im
  Originalbild hervorgehoben werden können
- Die Hervorhebungen (siehe unten) als eigene Einträge mit Position
- Erkennungssicherheit pro Zeile bzw. Abschnitt, unsichere und unleserliche
  Stellen markiert
- Womit digitalisiert wurde (Vision-Framework, eingebetteter PDF-Text oder
  welches KI-Modell) und wann
- Änderungen durch den Nutzer

Ablauf:
1. Sofort beim Import: Texterkennung mit dem Vision-Framework (genauer Modus,
   Deutsch, Sprachkorrektur an, Umlaute gezielt testen). Das funktioniert
   offline und auf allen Geräten. Ab iOS 26 zusätzlich RecognizeDocumentsRequest
   für Tabellen, Listen und Absätze.
   Bei Goodnotes-PDFs: Nur die Ink-Annotationen in hoher Auflösung auf weißem
   Hintergrund rendern (ohne Linienpapier, Bilder, Formen und Textmarker), und
   zwar je Farbe als eigene Ebene, und jede Ebene erkennen lassen. So ist die
   Farbe jedes erkannten Worts bekannt. Textmarker-Flächen werden über die
   Positionen den Wörtern zugeordnet. FreeText-Inhalte werden direkt übernommen.
2. Wenn ein bildfähiges KI-Modell eingerichtet ist: zusätzlich eine
   KI-Transkription mit Erkennung von Struktur und Hervorhebungen. Die Ergebnisse
   aus Schritt 1 (Text und Positionen) werden dabei mitgeschickt, damit die KI
   sie verbessert, statt bei null anzufangen. Die Transkription behält die
   Reihenfolge der Vorlage bei. Umsortiert wird erst in der sortierten Fassung.
3. Ohne bildfähiges Modell: Hervorhebungen per Bildanalyse erkennen (siehe unten)

Absicherung der Erkennung:
- Sicherheitswerte und mehrere Kandidaten pro Zeile aus Vision speichern,
  unsichere Stellen zur Prüfung markieren
- Bereits bestätigte Fachbegriffe des Fachs als `customWords` an Vision
  übergeben (Wirkung testen und dokumentieren)
- Liegt das reduzierte Goodnotes-PDF vor: dessen Text mit der eigenen Erkennung
  abgleichen. Übereinstimmende Wörter gelten als sicher, abweichende werden zur
  Prüfung markiert.
- Optional Mehrfacherkennung mit leicht veränderten Renderings (z. B. zwei
  Auflösungen). Wörter, die zwischen den Durchläufen variieren, gelten als
  unsicher. Bei KI-Transkription entsprechend zwei Durchläufe (kostet doppelt,
  daher in den Einstellungen abschaltbar).
- Vision ist versionsabhängig: Für iOS 27 gibt es Berichte über eine
  Verschlechterung des genauen Modus, die nur auf echten Geräten auftritt, nicht
  im Simulator. Vision-Revision, iOS-Version und Gerät pro Erkennung speichern.

Originaltext und sortierte Fassung:
Jede Quelle hat zwei dauerhaft gespeicherte Textfassungen:
- Originaltext: so, wie er in der Vorlage steht (siehe oben). Er wird nie von
  der KI verändert, nur durch Korrekturen des Nutzers an der Erkennung.
- Sortierte Fassung: Die KI ordnet den Text in eine logische, gut lesbare
  Reihenfolge und Struktur, z. B. Mindmaps und Diagramme in Listen auflösen,
  Randnotizen und Pfeil-Beschriftungen an der passenden Stelle einordnen,
  über Seiten verteilte Absätze zusammenführen, Überschriften-Hierarchie
  herstellen, Tabellen sauber aufbauen.
Regeln für die sortierte Fassung:
- Es wird nur umsortiert und strukturiert, nichts hinzugefügt, weggelassen oder
  umformuliert. Die Grundregel gilt uneingeschränkt.
- Jeder Abschnitt der sortierten Fassung verweist auf die Stellen im
  Originaltext (und damit auf Position im Bild), aus denen er stammt.
- Die App prüft technisch (im Core-Package), ob alle Wörter des Originaltexts
  in der sortierten Fassung vorkommen und keine neuen hinzugekommen sind.
  Abweichungen werden angezeigt und müssen vom Nutzer bestätigt oder
  korrigiert werden.
- Hervorhebungen werden in die sortierte Fassung übernommen.
- Der Nutzer kann die sortierte Fassung von Hand bearbeiten oder per Anweisung
  an die KI ändern lassen. Änderungen werden gespeichert. Sie kann jederzeit
  neu aus dem Originaltext erzeugt werden (alte Fassung bleibt als Version).
- Ansicht: Originaltext und sortierte Fassung umschaltbar oder nebeneinander,
  jeweils mit Sprung zur Stelle im Originalbild.
- Ohne KI-Anbieter gibt es nur den Originaltext. Die sortierte Fassung ist dann
  leer und kann später erzeugt werden.
- Wird der Originaltext korrigiert, markiert die App die betroffenen Abschnitte
  der sortierten Fassung und bietet an, sie zu aktualisieren.

Prüfen und korrigieren:
- Ansicht mit Originalbild und erkanntem Text nebeneinander. Tippt man auf eine
  Zeile, wird sie im Bild hervorgehoben (und umgekehrt).
- Unsichere und unleserliche Stellen sind markiert. Eine Übersicht zeigt, wie
  viele noch offen sind.
- Text und Hervorhebungen können von Hand korrigiert werden. Korrekturen werden
  gespeichert und haben Vorrang vor jeder automatischen Erkennung.
- Erneute Erkennung nur auf ausdrücklichen Wunsch des Nutzers (z. B. "Mit
  anderem Modell neu erkennen"), für einzelne Seiten oder ganze Importe.
  Vorher anzeigen, dass manuelle Korrekturen dabei erhalten bleiben, und den
  alten Stand als Version behalten, damit man ihn wiederherstellen kann.

Hervorhebungen:
Unterstrichene, fett geschriebene, farbige, mit Textmarker markierte, umrandete
oder eingekreiste Wörter und Sätze sind meist Überschriften, Fachbegriffe oder
besonders wichtige Inhalte und werden gezielt erkannt.
- Pro Hervorhebung gespeichert: der hervorgehobene Text, die Art (unterstrichen,
  doppelt unterstrichen, fett, farbiger Stift, Textmarker, umrandet, eingekreist,
  Großbuchstaben), die Farbe (falls farbig), die Position im Bild und wie sicher
  die Erkennung ist
- Vermutete Bedeutung als Vorschlag: Überschrift, Fachbegriff, Definition,
  Merksatz, Formel oder "wichtig". Der Nutzer kann die Bedeutung ändern.
- Unterstrichen bedeutet nicht immer Überschrift: Bei Unterstreichungen wird
  keine Bedeutung vermutet. Ob es eine Überschrift oder ein wichtiger
  Fachbegriff ist, entscheidet der Nutzer oder die KI.
- Mit bildfähigem KI-Modell: Die KI erkennt die Hervorhebungen bei der
  Transkription und gibt sie strukturiert zurück
- Ohne bildfähiges Modell: Die App analysiert das Bild selbst, z. B. die Farbe
  der Schrift und des Hintergrunds innerhalb der erkannten Textzeilen
  (farbige Stifte, Textmarker) und Linien direkt unter Textzeilen
  (Unterstreichungen). Diese Ergebnisse gelten als unsicher und werden so markiert.
- Bei eingebettetem PDF-Text werden Fett, Farbe und Unterstreichung direkt aus
  der PDF-Formatierung übernommen
- Bei Goodnotes-PDFs sind Farben und Textmarker exakt aus den Annotationen
  bekannt und gelten als sicher. Unterstreichungen werden an der Form erkannt
  (lange, fast waagerechte Linie direkt unter einer Textzeile). Die Bildanalyse
  ist nur für Fotos und Scans nötig.
- Optionale Farblegende pro Fach, z. B. "Rot = Definition, Grün = Beispiel,
  Gelber Textmarker = wichtig". Ist eine Legende hinterlegt, verwendet die App
  sie statt einer Vermutung.
- Hervorhebungen werden im erkannten Text sichtbar dargestellt (fett, farbig,
  unterstrichen) und bleiben auch im Original nachvollziehbar

Verwendung der Hervorhebungen:
- Bei der Strukturierung werden hervorgehobene Inhalte bevorzugt als
  Themen-Überschriften, Begriffe oder Kernaussagen übernommen
- Hervorgehobene Inhalte werden beim Erstellen von Fragen und Karteikarten
  stärker gewichtet, d. h. es gibt mehr Fragen dazu
- In der Themenansicht ist erkennbar, welche Einträge im Original
  hervorgehoben waren

Die gespeicherte Digitalisierung wird an die KI geschickt statt der Bilder, wo
das reicht. Das spart Tokens und Zeit. Das Originalbild wird zusätzlich nur
mitgeschickt, wenn die Aufgabe es braucht (z. B. Strukturierung von Mindmaps
und Tabellen) und das Modell bildfähig ist.

### 3. KI-Anbieter
In den Einstellungen wählbar und mehrere gleichzeitig speicherbar:
- Apple Foundation Model (On-Device)
- Selbst gehostetes LLM über eine OpenAI-kompatible Schnittstelle (URL,
  Modellname, optionaler Key), z. B. Ollama, LM Studio, llama.cpp, vLLM
- Claude-API und OpenAI-API: Key eingeben, dann die verfügbaren Modelle über die
  API abrufen und eines auswählen (keine fest eingebaute Modellliste)
- Hugging-Face-Modelle in der App herunterladen und lokal auf dem Gerät
  ausführen (MLX Swift), mit Anzeige von Größe und Speicherbedarf vor dem Download
- Für die Digitalisierung kann ein eigener Anbieter gewählt werden (z. B. ein
  starkes bildfähiges Modell für die Handschrift, ein günstiges für die Abfragen)

Reasoning:
- Bei Claude- und OpenAI-API kann pro Anbieter-Konfiguration neben dem Modell
  auch die Reasoning-Stufe gewählt werden (z. B. aus, niedrig, mittel, hoch)
- Nur Stufen anzeigen, die das gewählte Modell unterstützt. Modelle ohne
  Reasoning zeigen die Option nicht an.
- Bei selbst gehosteten Modellen, die Reasoning unterstützen (z. B. über Ollama),
  Reasoning ein- und ausschaltbar machen
- Optional pro Aufgabe überschreibbar (z. B. Bewerten von Freitext mit höherem
  Reasoning als das Erstellen von Karteikarten, Chat mit niedrigem Reasoning
  für schnelle Antworten)
- Reasoning-Inhalte nicht als Antwort anzeigen, nur im Developer-Modus

Bildverarbeitung:
- Bei Ollama die Bildfähigkeit automatisch über die API erkennen, bei Claude/OpenAI
  anhand des gewählten Modells, sonst per Einstellung "Modell kann Bilder verarbeiten"
- Das Apple-On-Device-Modell bekommt erst ab iOS 27 Bilder, davor nur den
  gespeicherten Text
- Reine Textmodelle bekommen immer nur den gespeicherten Text inkl. Hervorhebungen

### 4. System-Prompts
- Für jede KI-Aufgabe gibt es einen eigenen System-Prompt:
  Digitalisierung (Transkription inkl. Hervorhebungen), Sortieren des Texts
  (sortierte Fassung), Strukturierung des Lernstoffs, Zuordnung zu
  vorgegebenen Themen, Korrektur eines Themas,
  Erkennen und Füllen von Lücken, Erstellen von Multiple-Choice-Fragen,
  Erstellen von Freitext-Fragen, Bewerten von Antworten, Erstellen von Tipps,
  Chat-Modus, Erstellen von Karteikarten
- Jeder Prompt hat einen sinnvollen Standardtext (auf Deutsch, für Schüler geeignet)
- Der Digitalisierungs-Prompt verlangt eine wortgetreue Transkription: nichts
  umformulieren, nichts korrigieren außer offensichtlichen Erkennungsfehlern,
  unleserliche Stellen markieren statt raten
- Alle Prompts sind in den Einstellungen bearbeitbar und einzeln auf den
  Standard zurücksetzbar
- Optional pro Fach ein Zusatz, der an den System-Prompt angehängt wird
  (z. B. für Englisch: "Fragen auf Englisch stellen")
- Platzhalter, die die App automatisch füllt, z. B. {fach}, {thema},
  {anzahl}, {schwierigkeit}, {tippstufe}, {farblegende}. Verfügbare Platzhalter
  im Editor anzeigen.
- Zwei Teile hängt die App selbst an, und sie sind nicht vom Nutzer bearbeitbar:
  - die Grundregel "Nur Inhalte aus dem Lernstoff" inkl. Lücken-Regel
  - die Vorgaben zum Ausgabeformat (JSON-Schema bzw. Guided Generation),
    damit das Parsing nicht kaputtgeht
  Im Editor werden diese Teile schreibgeschützt angezeigt.
- Kurze System-Prompts für das Apple-On-Device-Modell wegen des kleinen
  Kontextfensters (eigene Variante pro Aufgabe oder automatisch gekürzt). Die
  Grundregel darf dabei nicht gekürzt werden.
- System-Prompts als Export/Import (JSON), um sie zu sichern oder zu teilen

### 5. Strukturierung des Lernstoffs
Grundlage ist immer die gespeicherte Digitalisierung aus Abschnitt 2: die
sortierte Fassung, falls vorhanden, sonst der Originaltext. Quellenverweise
führen immer bis zum Originaltext und zur Position im Bild.

Jedes Thema wird in einer festen Struktur gespeichert, egal ob es manuell oder
von der KI erstellt wurde:
- Titel
- Kurze Zusammenfassung
- Kernaussagen bzw. wichtige Fakten (Liste)
- Begriffe mit Definitionen
- Formeln, Regeln oder Merksätze (falls vorhanden)
- Beispiele (falls vorhanden)
- Tabellen (als strukturierte Daten, nicht nur als Text)
- Zugeordnete Quellen (welche Seiten/Bilder zu diesem Thema gehören)
- Herkunft des Themas: manuell, KI oder gemischt
- Für jeden einzelnen Eintrag (jede Kernaussage, jeden Begriff usw.):
  - Quellenverweis (Seite/Bild und Position im Bild)
  - Herkunft: Original aus dem Lernstoff, vom Nutzer eingegeben oder KI-Ergänzung
  - Ob der Inhalt im Original hervorgehoben war (und wie)
  - Bei KI-Ergänzungen: Status (vorgeschlagen, angenommen, abgelehnt) und
    Begründung, welche Lücke gefüllt wurde

Nach dem Import wählt der Nutzer einen von drei Wegen:

a) Manuell:
- Der Nutzer legt Themen selbst an, ordnet ihnen Seiten/Bilder zu und füllt die
  Felder der Struktur von Hand aus
- Der gespeicherte Text der zugeordneten Seiten wird neben dem Editor angezeigt
  (mit Hervorhebungen) und kann in die Felder übernommen werden
- Hervorgehobene Begriffe werden als Vorschläge für Begriffe und Überschriften
  angeboten
- Felder sind optional, nur der Titel ist Pflicht

b) Per KI:
- Die KI analysiert den gesamten Lernstoff, teilt ihn in Themen auf, ordnet die
  Quellen zu und speichert alles in der Struktur oben
- Hervorgehobene Überschriften dienen als Hinweis auf Themengrenzen,
  hervorgehobene Begriffe werden als Begriffe übernommen
- Sie hält sich dabei strikt an die Grundregel und meldet erkannte Lücken

c) Gemischt:
- Der Nutzer gibt nur die Themennamen vor (z. B. die Themen der Schulaufgabe)
- Die KI ordnet den Lernstoff diesen Themen zu und füllt die Struktur aus
- Inhalte, die zu keinem Thema passen, werden als "Nicht zugeordnet" angezeigt
- Vorgegebene Themen, zu denen kein Lernstoff gefunden wurde, werden als leer
  markiert und nicht von der KI mit eigenem Wissen gefüllt

Überprüfung und Korrektur (für alle drei Wege):
- Der Nutzer sieht jedes Thema in seiner Struktur neben den Originalquellen.
  Tippt man auf einen Eintrag, wird die zugehörige Stelle im Bild hervorgehoben.
- KI-Ergänzungen sind deutlich markiert und müssen einzeln angenommen,
  bearbeitet oder abgelehnt werden
- Eine Übersicht zeigt pro Thema, wie viele Ergänzungen noch offen sind
- Jedes Feld kann von Hand bearbeitet werden
- Oder per Anweisung an die KI ändern lassen (z. B. "In Thema 2 fehlt die Formel ...")
- Themen können zusammengelegt, aufgeteilt, umbenannt und gelöscht werden,
  Quellen können verschoben werden
- Auch manuell erstellte Themen können nachträglich von der KI geprüft werden,
  z. B. "Fehlende Inhalte aus den Quellen übernehmen" oder "Lücken suchen"
- Wird die Digitalisierung einer Quelle nachträglich korrigiert, zeigt die App
  an, welche Themen davon betroffen sind, und bietet an, sie zu aktualisieren
- Erst nach der Bestätigung durch den Nutzer kann ein Thema gelernt werden

### 5a. Zugriff der KI auf den Lernstoff
Der Lernstoff wird nach dem Import so gespeichert und aufbereitet, dass die KI in
Lernsessions schnell, günstig und gezielt darauf zugreifen kann, ohne jedes Mal
den gesamten Stoff mitzuschicken.

Speicherung:
- Jeder Eintrag eines Themas (Kernaussage, Begriff, Formel, Beispiel,
  Tabellenzeile usw.) ist eine eigene Lerneinheit mit kurzer, stabiler ID
  (z. B. "T3-B2" für Thema 3, Begriff 2). Die KI verweist in ihren Antworten nur
  auf diese IDs statt Text zu zitieren. Das spart Tokens und macht die
  Quellenprüfung einfach.
- Pro Lerneinheit gespeichert: Text, Thema, Fach, Herkunft, Hervorhebung,
  Quellenverweis, Lernstand (Leitner-Fach) und vorberechnete Token-Anzahl
- Pro Thema eine kompakte Kurzfassung (wenige Sätze, nur aus dem Lernstoff),
  die als Übersicht dient, wenn nicht der ganze Inhalt nötig ist
- Ein kompaktes Textformat für den Kontext (Markdown mit IDs, kein ausführliches
  JSON), definiert im Core-Package
- Alles wird beim Bestätigen eines Themas erzeugt und bei jeder Änderung
  automatisch aktualisiert, nicht erst beim Start einer Lernsession

Suche (lokal, offline, ohne Kosten):
- Stichwortsuche über alle Lerneinheiten (Volltextindex)
- Zusätzlich semantische Suche mit lokalen Satz-Embeddings (z. B.
  NLEmbedding aus dem NaturalLanguage-Framework, falls für Deutsch verfügbar,
  sonst ein kleines lokales Embedding-Modell). Die Embeddings werden beim
  Speichern berechnet und mit abgelegt. Verfügbarkeit für Deutsch prüfen und in
  docs/DECISIONS.md festhalten.
- Kombinierte Suche (Stichwort und semantisch), gefiltert nach Fach und Thema

Kontext-Zusammenstellung (Core-Package):
- Ein Kontext-Baustein wählt für jede KI-Aufgabe nur die nötigen Lerneinheiten
  aus und hält dabei ein Token-Budget ein, das zum Modell passt (klein beim
  Apple-On-Device-Modell, größer bei Cloud-Modellen)
- Priorität: ausgewählte Themen, Einheiten aus niedrigen Leitner-Fächern,
  hervorgehobene Inhalte, bei Tipps und Bewertung genau die Einheiten, aus denen
  die Frage erstellt wurde
- Passt nicht alles ins Budget, werden Kurzfassungen statt vollständiger
  Themen verwendet

Zugriff per Tools (für Modelle mit Tool-Aufrufen, z. B. Claude, OpenAI, Apple
Foundation Models mit dem Tool-Protokoll):
- Die KI bekommt im Chat-Modus und bei Erklärungen Werkzeuge statt des ganzen
  Stoffs, z. B. "suche_im_lernstoff(suchbegriff)", "hole_thema(id)",
  "hole_einheit(id)", "hole_quelle(id)" (Originaltext der Stelle)
- Die Werkzeuge liefern nur Inhalte aus dem Lernstoff des aktuellen Fachs
- Modelle ohne Tool-Aufrufe bekommen stattdessen den vorab zusammengestellten
  Kontext

Kosten und Geschwindigkeit:
- Prompt-Caching der Anbieter nutzen, wo verfügbar: Gleichbleibende Teile
  (System-Prompt, Kontext der Session) stehen am Anfang des Prompts, damit sie
  bei mehreren Fragen einer Session aus dem Cache kommen
- Fragen und Tipps für eine Session gebündelt und vorab im Hintergrund erzeugen,
  damit beim Lernen keine Wartezeit entsteht. Die nächsten Fragen werden
  generiert, während der Nutzer noch antwortet.
- Bereits erzeugte Fragen, Karten und Tipps werden gespeichert und
  wiederverwendet, statt sie jedes Mal neu zu erzeugen. Neue werden nur bei
  Bedarf erzeugt (z. B. zu schwachen Themen oder wenn der Vorrat erschöpft ist).

### 6. Lernen
Vor dem Start: Fach, ein oder mehrere Themen, Modus und Anzahl der Fragen bzw.
Karten auswählen. Fragen und Karten werden ausschließlich aus der gespeicherten
Themenstruktur erzeugt (Original-Inhalte und bestätigte Ergänzungen).
Hervorgehobene Inhalte werden dabei stärker gewichtet.

Modi:

a) Multiple Choice
- Schwierigkeit vor dem Start wählbar: leicht, mittel, schwer oder gemischt
- Leicht: direkte Wissensfragen, falsche Optionen klar unterscheidbar
- Mittel: Verständnisfragen, falsche Optionen plausibel
- Schwer: Fragen, die mehrere Inhalte des Lernstoffs verknüpfen, Anwendung von
  Regeln/Formeln aus dem Lernstoff auf neue Aufgaben, sehr ähnliche falsche
  Optionen, typische Verwechslungen, Fragen mit Verneinung ("Welche Aussage
  trifft NICHT zu?"), optional Mehrfachauswahl (mehrere richtige Antworten,
  in der Frage angekündigt)
- Auch schwere Fragen müssen sich vollständig mit dem Lernstoff beantworten lassen
- Jede Frage speichert ihre Schwierigkeit

b) Freitext
- Eine Frage pro Bildschirm, Antwort eintippen, die KI bewertet anhand des
  Lernstoffs mit kurzem Feedback, was richtig und was falsch war
- Teilweise richtige Antworten werden als solche erkannt

c) Chat-Modus
- Unterhaltung wie in einer Chat-App: Die KI stellt eine Frage, der Nutzer
  tippt die Antwort, die KI reagiert darauf
- Die KI kann bei unvollständigen Antworten nachhaken ("Was gehört noch dazu?")
  oder Folgefragen stellen ("Und warum ist das so?")
- Der Nutzer kann auch selbst Fragen zum Lernstoff stellen ("Ich verstehe
  Thema 3 nicht"). Die KI erklärt dann nur mit Inhalten aus dem Lernstoff.
- Die vorher gewählte Anzahl Fragen gilt auch hier. Eine Fortschrittsanzeige
  zeigt, wie viele Fragen schon dran waren.
- Antworten erscheinen per Streaming schrittweise
- Der Chat-Verlauf wird mit der Lernsession gespeichert
- Damit der Kontext nicht zu groß wird (besonders beim Apple-On-Device-Modell),
  bekommt die KI nur die nötigen Themen und einen gekürzten Verlauf, bzw. greift
  per Tools gezielt auf den Lernstoff zu (siehe Abschnitt 5a)

d) Karteikarten
- Von der KI aus den Themen erstellt, Karte umdrehen, dann "Gewusst",
  "Halb gewusst" oder "Nicht gewusst" auswählen
- Hervorgehobene Begriffe und Definitionen bekommen bevorzugt eigene Karten

Für alle Modi:
- Jede Frage und Karte speichert, aus welchen Einträgen des Themas sie erstellt
  wurde. Beim Auflösen kann man sich die Stelle im Lernstoff (Text und
  Originalbild) anzeigen lassen.
- Fragen, die auf KI-Ergänzungen beruhen, sind dezent markiert

### 7. Tipps und Hilfestellungen
Bei falschen Antworten in Multiple Choice, Freitext und Chat gibt es gestufte
Tipps, die mit jedem weiteren Fehlversuch mehr verraten:
- Stufe 1: sehr allgemein, z. B. in welchem Thema oder Abschnitt die Antwort
  steht oder worauf man achten soll
- Stufe 2: konkreter, z. B. ein Schlüsselbegriff, ein Zusammenhang, ein
  Teil der Antwort. Bei Multiple Choice wird zusätzlich eine falsche Option
  ausgegraut.
- Stufe 3: fast die Lösung, z. B. die Antwort mit einer Lücke, der Anfang der
  Antwort. Bei Multiple Choice wird eine weitere falsche Option ausgegraut.
- Danach: Lösung mit kurzer Erklärung und Verweis auf die Stelle im Lernstoff

Regeln:
- Tipps verraten auf keiner Stufe mehr als für diese Stufe vorgesehen,
  besonders Stufe 1 darf die Antwort nicht vorwegnehmen
- Tipps gehen auf die konkrete falsche Antwort ein, wenn das hilft
  (z. B. "Du hast X mit Y verwechselt")
- Tipps verwenden nur den Lernstoff
- Der Nutzer kann auch ohne falsche Antwort mit einem Tipp-Button den nächsten
  Tipp anfordern oder direkt die Lösung anzeigen lassen
- Die Anzahl der Tipp-Stufen und Versuche ist in den Einstellungen anpassbar
  (Standard: 3 Stufen) und kann ganz abgeschaltet werden
- Bei Multiple Choice können Tipps vorab zusammen mit der Frage generiert werden,
  damit sie ohne Wartezeit erscheinen

Verknüpfung mit dem Lernstand:
- Richtig beim ersten Versuch ohne Tipp → zählt als "Gewusst"
- Richtig nach Tipps → zählt als "Halb gewusst"
- Lösung angezeigt oder nach allen Stufen noch falsch → zählt als "Nicht gewusst"
- Pro Frage wird gespeichert, wie viele Tipps gebraucht wurden

### 8. Auswertung und Wiederholung
- Nach jeder Session eine Auswertung: Ergebnis gesamt und pro Thema, Liste der
  falsch beantworteten Fragen, Anzahl der benötigten Tipps, Ergebnis pro
  Schwierigkeitsstufe
- Jede Frage und Karte wird in einem Leitner-System mit 5 Fächern geführt:
  Gewusst → ein Fach höher, Halb gewusst → bleibt, Nicht gewusst → zurück in Fach 1
- Übersicht pro Fach und Thema, was man kann und was nicht
  (z. B. Fortschrittsbalken, farbliche Markierung)
- Bei der nächsten Session kommen Fragen aus niedrigen Fächern häufiger dran,
  und zu schwachen Themen werden zusätzliche neue Fragen generiert,
  ebenfalls nur aus dem Lernstoff
- Bei "gemischt" passt sich die Schwierigkeit an: Themen, die gut sitzen,
  bekommen mehr schwere Fragen

### 9. Design
- Mehrere Farbschemata (Hell, Dunkel und mindestens 2 weitere), in den
  Einstellungen wählbar. Die Markierung von KI-Ergänzungen und die Darstellung
  farbiger Hervorhebungen müssen in jedem Farbschema gut erkennbar sein.
- Der Chat-Modus sieht aus wie eine typische Chat-App (Sprechblasen,
  Eingabefeld unten, Tastatur verdeckt nichts)
- Unterstützung für Dynamic Type und VoiceOver (KI-Ergänzungen und
  Hervorhebungen werden auch von VoiceOver als solche angesagt)

### 10. Developer-Modus
In den Einstellungen per Schalter aktivierbar (standardmäßig aus). Wenn aktiv,
zeigt die App zusätzliche Informationen an:

Pro KI-Anfrage (z. B. als ausklappbare Info unter dem Ergebnis):
- Anbieter, Modell und Reasoning-Stufe
- Input-, Output- und (falls vorhanden) Cache- und Reasoning-Tokens, aus den
  Usage-Angaben der jeweiligen API
- Geschätzte Kosten in Euro und Dollar
- Dauer der Anfrage, Zeit bis zum ersten Token (bei Streaming) und
  Tokens pro Sekunde
- Bei Apple Foundation Models: genutzte Tokens im Verhältnis zur Kontextgröße
  (`tokenCount(for:)` und `contextSize`, ab iOS 26.4)
- Ob Bild, gespeicherter Text oder beides gesendet wurde
- Welche Lerneinheiten im Kontext waren, welche Tools die KI aufgerufen hat und
  wie viele Tokens aus dem Cache kamen
- Der verwendete System-Prompt (mit gefüllten Platzhaltern), der vollständige
  Prompt und die rohe Modellantwort (kopierbar)
- Reasoning-Inhalte bzw. Zusammenfassung, falls die API sie liefert
- Parsing-Fehler, falls die Antwort nicht dem erwarteten Format entsprach
- Warnungen der Quellenprüfung (Inhalte ohne gültige Quellenangabe)

Übersicht (eigener Bildschirm im Developer-Modus):
- Kosten und Tokens pro Lernsession, pro Tag und pro Monat, aufgeteilt nach
  Anbieter, Modell und Aufgabe (Digitalisierung, Strukturierung, Abfrage usw.)
- Liste der letzten Anfragen mit den Infos oben
- Vergleich der Digitalisierung pro Quelle: Vision-Framework, KI-Transkription
  und manuell korrigierte Fassung nebeneinander, mit erkannten Hervorhebungen
  und deren Positionen als Overlay auf dem Originalbild
- Statistik pro Modell: Anteil der Inhalte ohne gültige Quelle (zeigt, welche
  Modelle sich schlechter an den Lernstoff halten) und Anzahl der manuellen
  Korrekturen bei der Digitalisierung (zeigt, welches Modell Handschrift am
  besten erkennt)
- Qualitätstest der Texterkennung: Der Nutzer korrigiert für ausgewählte
  Testseiten einen Referenztext. Die App berechnet pro Methode (Vision,
  Goodnotes-Text, jedes KI-Modell, bei KI über mehrere Durchläufe) die Zeichen-
  und Wortfehlerquote und zeigt sie an, inkl. iOS-Version und Gerät. So lässt
  sich nach iOS-Updates prüfen, ob die Erkennung schlechter geworden ist.
- Export des Anfrage-Logs als JSON-Datei
- Logs löschen

Preise:
- Die APIs liefern keine Preise. Lege daher eine Preistabelle pro Modell an
  (Preis pro 1 Mio. Input-/Output-/Cache-Tokens), mit Standardwerten für
  gängige Modelle, die in den Einstellungen bearbeitet werden können.
  Reasoning-Tokens werden wie Output-Tokens berechnet, sofern die API nichts
  anderes angibt.
- Unbekannte Modelle ohne Preis: Tokens anzeigen, Kosten als "unbekannt"
- Kostenlose Anbieter (Apple, selbst gehostet, Hugging Face lokal) mit 0 € anzeigen
- Kosten immer als "geschätzt" kennzeichnen

Logs werden in SwiftData gespeichert.

## Phasen
0. Künstliche Goodnotes-Test-PDFs, lokales Git-Repository mit .gitignore,
   Projektgerüst mit XcodeGen und Core-Package, lokale Build- und Test-Skripte,
   CLAUDE.md, PLAN.md, DECISIONS.md, MANUAL_TESTS.md, PHASES.md
1. Datenmodell inkl. gespeicherter Digitalisierung und Themenstruktur mit
   Herkunft und Quellenverweisen, Fächerverwaltung, Import inkl. Goodnotes-PDFs
   und Share-Extension, Digitalisierung mit Vision-Framework (inkl.
   Farbebenen bei Goodnotes, Dokument-API ab iOS 26) und eingebettetem
   PDF-Text, Abgleich mit dem reduzierten Goodnotes-PDF, Ansicht zum Prüfen und
   Korrigieren des Texts, manuelle Strukturierung (Weg a)
2. Anbieter-Protokoll inkl. Metadaten, Reasoning und Streaming, Mock-Modell,
   Apple Foundation Model, OpenAI-kompatible Anbieter, Claude- und OpenAI-API
   mit Modell- und Reasoning-Auswahl, Speichern der Anfrage-Logs
3. Hervorhebungen: KI-Transkription mit bildfähigen Modellen, Bildanalyse als
   Fallback, Farblegende pro Fach, Bearbeiten der Hervorhebungen,
   Versionierung bei erneuter Erkennung
4. System-Prompts (Standardtexte, feste Grundregel, Platzhalter, Editor,
   Fach-Zusätze, Export/Import), sortierte Fassung inkl. Vollständigkeits-
   prüfung und Ansicht, Strukturierung per KI und gemischt (Wege b
   und c) inkl. Nutzung der Hervorhebungen, Lückenerkennung mit Bestätigung,
   Quellenprüfung, Überprüfung und Korrektur, Lerneinheiten mit IDs,
   Kurzfassungen, Suchindex inkl. Embeddings, Kontext-Zusammenstellung
5. Multiple Choice mit Schwierigkeitsstufen, Freitext, Karteikarten, Vorrat und
   Vorab-Erzeugung von Fragen, Prompt-Caching
6. Tipp-System mit Stufen, Chat-Modus mit Tool-Zugriff auf den Lernstoff
7. Leitner-System inkl. Verknüpfung mit Tipps, Auswertung, Fortschrittsübersicht
8. Farbschemata, Barrierefreiheit, Developer-Modus (Ansichten, Preistabelle,
   Vergleich der Digitalisierung, Qualitätstest der Texterkennung, Export),
   Feinschliff
9. Hugging-Face-Download und lokale Ausführung auf dem Gerät

## Ablauf
- Wird der Kontext knapp oder endet die Sitzung, vorher den aktuellen Stand in
  CLAUDE.md festhalten (was fertig ist, woran du gerade arbeitest, nächster
  Schritt).
- Keine API-Keys, Tokens oder persönlichen Daten im Repository. Für Tests mit
  echten APIs nichts committen, sondern nur Mock-Modelle verwenden.
