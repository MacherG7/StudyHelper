# App-Source für SideStore, AltStore und StikStore

SideStore, AltStore (Classic) und StikStore lesen dasselbe Source-Format („AltSource“, JSON). Eine Source
reicht für alle drei. Die App wird beim Installieren mit der Apple-ID des jeweiligen Geräts neu signiert
und von der Store-App alle 7 Tage aufgefrischt. Hintergrund: `docs/DECISIONS.md` D-024.

| Datei | Zweck |
|---|---|
| `source.json` | Die Source (Hauptkopie). Versionen trägt `scripts/publish-source.sh` ein. |
| `icon.svg`, `icon.png` | Icon der Source und der App in der Source (1024 × 1024, Platzhalter) |

## Einmalig: öffentliches Repository anlegen

Source und `.ipa` müssen ohne Anmeldung abrufbar sein. Das Haupt-Repository ist privat, deshalb liegt die
Source in einem eigenen **öffentlichen** Repository (Standard `MacherG7/StudyHelper-Source`, anderer Name
über `SOURCE_REPO=Besitzer/Name`):

```bash
gh repo create MacherG7/StudyHelper-Source --public --add-readme --description "StudyHelper-Source für SideStore, AltStore und StikStore"
```

Darin liegen nur `source.json`, `icon.png` und je Version ein Release mit der `.ipa` – kein Quellcode.
Wer die Source-URL kennt, kann die App herunterladen.

## Neue Beta veröffentlichen

1. Version erhöhen (`scripts/bump-version.sh`, vor jedem Commit ohnehin, D-027), also `MARKETING_VERSION` oder `CURRENT_PROJECT_VERSION` in `project.yml` (jede Version/Build-Kombination
   darf nur einmal in der Source stehen).
2. Auf dem Mac:

   ```bash
   scripts/publish-source.sh "Was ist neu in dieser Version"
   ```

   Das Skript baut eine unsignierte `.ipa` (`scripts/build-ipa.sh`, immer unsigniert), liest Bundle-ID, Version,
   Build, Mindest-iOS, Datenschutz-Texte und Entitlements aus der `.ipa`, trägt Größe und SHA-256 ein, lädt die
   `.ipa` als Release `v<Version>-<Build>` hoch und veröffentlicht danach `icon.png` und `source.json`.
3. `distribution/source.json` committen und `scripts/publish.sh` ausführen.

Optionen: `--ipa PFAD` (vorhandene `.ipa`), `--no-upload` (nur `source.json` lokal aktualisieren),
`--replace` (dieselbe Version/Build ersetzen, nur für Korrekturen). Prüfen ohne Änderung:
`scripts/update-source.py --check distribution/source.json` (läuft auch in `scripts/test.sh`).

## Source auf dem Gerät hinzufügen

Source-URL:

```
https://raw.githubusercontent.com/MacherG7/StudyHelper-Source/main/source.json
```

- **SideStore:** Tab „Sources“ → „+“ → URL einfügen → StudyHelper installieren.
- **AltStore (Classic):** Tab „Sources“ → „+“ → URL einfügen.
- **StikStore:** Bereich für Sources/Repositories → URL hinzufügen.

Hinweise zum kostenlosen Apple-Account: höchstens 3 aktive sideloaded Apps (die Store-App zählt mit) und
10 App-IDs pro 7 Tage. Die Installation aus der Source ist eine eigene App neben der aus Xcode installierten,
wenn die Store-App die Bundle-ID anpasst; Daten werden dann nicht übernommen (MT-S.4).
