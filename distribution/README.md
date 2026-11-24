# App-Source für SideStore, AltStore und StikStore

SideStore, AltStore (Classic) und StikStore lesen dasselbe Source-Format („AltSource“, JSON). Eine Source
reicht für alle drei. Die App wird beim Installieren mit der Apple-ID des jeweiligen Geräts neu signiert
und von der Store-App alle 7 Tage aufgefrischt. Hintergrund: `docs/DECISIONS.md` D-024.

| Datei | Zweck |
|---|---|
| `source.json` | Vorlage: Texte, Icon, Farbe, Berechtigungen. Die Versionen stehen nur in der veröffentlichten `source.json` im öffentlichen Repository. |
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

Danach im Repository `MacherG7/StudyHelper` das Secret für die Automatik anlegen:

1. GitHub → Settings → Developer settings → Fine-grained tokens → „Generate new token“:
   Repository access „Only select repositories“ → `MacherG7/StudyHelper-Source`,
   Permissions → Repository → **Contents: Read and write**. Ablaufdatum notieren.
2. `MacherG7/StudyHelper` → Settings → Secrets and variables → Actions → „New repository secret“:
   Name `SOURCE_REPO_TOKEN`, Wert = der Token.

## Automatisch: jedes Release mit .ipa (empfohlen)

Wird in `MacherG7/StudyHelper` ein Release veröffentlicht, an dem eine `.ipa` hängt, lädt der Workflow
`.github/workflows/source.yml` sie herunter und ruft `scripts/publish-source.sh --skip-existing` auf: Die
`.ipa` kommt als Release in das öffentliche Repository und als neueste Version in die Source. Als
„Was ist neu“ dient der Text des Releases (sonst sein Titel). Steht dieselbe Version/Build schon in der
Source, passiert nichts – für eine neue Beta also `MARKETING_VERSION` oder `CURRENT_PROJECT_VERSION` in
`project.yml` erhöhen. Releases ohne `.ipa` (z. B. `phase-N`) werden übersprungen.

Von Hand starten (z. B. für ein schon vorhandenes Release): Actions → „Source aktualisieren“ →
„Run workflow“; ohne Tag nimmt er das neueste Release mit `.ipa`.

Die `.ipa` aus `scripts/build-ipa.sh` ist mit deinem Team signiert; das Skript trägt ihre Entitlements
(z. B. `get-task-allow`) passend in die Source ein. Unsigniert geht auch: `scripts/build-ipa.sh --unsigned`.

## Von Hand vom Mac

1. Version erhöhen (`scripts/bump-version.sh`, vor jedem Commit ohnehin, D-027), also `MARKETING_VERSION` oder `CURRENT_PROJECT_VERSION` in `project.yml` (jede Version/Build-Kombination
   darf nur einmal in der Source stehen).
2. Auf dem Mac:

   ```bash
   scripts/publish-source.sh "Was ist neu in dieser Version"
   ```

   Das Skript baut eine unsignierte `.ipa` (`scripts/build-ipa.sh --unsigned`), liest Bundle-ID, Version,
   Build, Mindest-iOS, Datenschutz-Texte und Entitlements aus der `.ipa`, trägt Größe und SHA-256 ein, lädt die
   `.ipa` als Release `v<Version>-<Build>` hoch und veröffentlicht danach `icon.png` und `source.json`
   (bisherige Versionen werden aus der veröffentlichten Source übernommen).

Optionen: `--ipa PFAD` (vorhandene `.ipa`), `--notes-file PFAD`, `--skip-existing`, `--no-upload` (nur
`build/source/source.json` schreiben), `--replace` (dieselbe Version/Build ersetzen, nur für Korrekturen). Prüfen ohne Änderung:
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
