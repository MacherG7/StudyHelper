# App-Source für SideStore, AltStore und StikStore

SideStore, AltStore (Classic) und StikStore lesen dasselbe Source-Format („AltSource“, JSON). Eine Source
reicht für alle drei. Die App wird beim Installieren mit der Apple-ID des jeweiligen Geräts signiert
und von der Store-App alle 7 Tage aufgefrischt. Hintergrund: `docs/DECISIONS.md` D-024 und D-034.

| Datei | Zweck |
|---|---|
| `source.json` | Die Source. Jedes Release trägt sich hier selbst ein (`scripts/beta-release.sh`). |
| `icon.svg`, `icon.png` | Icon der Source und der App in der Source (1024 × 1024, Platzhalter) |

Das Repository `MacherG7/StudyHelper` ist öffentlich: Source, Icon und die `.ipa` der Releases sind ohne
Anmeldung abrufbar, wie es die Store-Apps brauchen. Die `.ipa` ist immer unsigniert (D-030).

## Neue Version in die Source

Passiert automatisch: `scripts/publish.sh` baut nach einem Commit mit Änderungen an der App die `.ipa`,
legt das Release `v<A.B.C.D>` an (Beta, oder Vollversion mit `--final`) und trägt es danach mit Größe,
SHA-256, Mindest-iOS, Datenschutz-Texten und Entitlements in `source.json` ein – als eigener Commit
„Source: …“, der gleich mit hochgeladen wird.

Nachtragen für ein schon vorhandenes Release:

```bash
scripts/beta-release.sh --source-only --tag=v0.0.1.7
```

Prüfen ohne Änderung: `scripts/update-source.py --check distribution/source.json` (läuft auch in `scripts/test.sh`).

## Source auf dem Gerät hinzufügen

Source-URL:

```
https://raw.githubusercontent.com/MacherG7/StudyHelper/main/distribution/source.json
```

- **SideStore:** Tab „Sources“ → „+“ → URL einfügen → StudyHelper installieren.
- **AltStore (Classic):** Tab „Sources“ → „+“ → URL einfügen.
- **StikStore:** Bereich für Sources/Repositories → URL hinzufügen.

Hinweise zum kostenlosen Apple-Account: höchstens 3 aktive sideloaded Apps (die Store-App zählt mit) und
10 App-IDs pro 7 Tage. Die Installation aus der Source ist eine eigene App neben der aus Xcode installierten,
wenn die Store-App die Bundle-ID anpasst; Daten werden dann nicht übernommen (MT-S.4).
