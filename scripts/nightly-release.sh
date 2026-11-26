#!/usr/bin/env bash
# Publishes the current, still untested working state as a nightly (D-045), so the developer can try it on the
# device while the tests run: run it after scripts/bump-version.sh and before scripts/test.sh, commit and publish.sh.
#   scripts/nightly-release.sh [--notes=TEXT] [--dry-run]
# - builds the unsigned .ipa with channel "Nightly" (the app shows "A.B.C.D (Nightly)", commit with "*" when the
#   working tree has uncommitted changes);
# - replaces the rolling GitHub pre-release "nightly" (tag on origin/main, asset StudyHelper-nightly.ipa): only the
#   newest nightly is kept;
# - updates the entry "StudyHelper Nightly" in distribution/source.json on origin/main in a temporary worktree and
#   pushes that as "Source: … Nightly …" – local, uncommitted or not yet published work is never pushed.
#   scripts/publish.sh later rebases onto such source-only commits.
source "$(dirname "$0")/common.sh"
REPO="MacherG7/StudyHelper"
NOTES=""
DRY=0
for arg in "$@"; do
    case "$arg" in
        --notes=*) NOTES="${arg#--notes=}" ;;
        --dry-run) DRY=1 ;;
        *) fail "Unbekannte Option: $arg (erlaubt: --notes=TEXT, --dry-run)" ;;
    esac
done
command -v gh >/dev/null 2>&1 || fail "gh fehlt (brew install gh, dann gh auth login)."

VERSION="$("$ROOT/scripts/bump-version.sh" --show)"
MARKETING="${VERSION%.*}"
BUILD="${VERSION##*.}"
NAME="$MARKETING"
[[ "$MARKETING" == *.0 ]] && NAME="${MARKETING%.0}"
TITLE="StudyHelper $NAME Nightly $BUILD"
git -C "$ROOT" fetch -q origin main
TARGET="$(git -C "$ROOT" rev-parse origin/main)"
BASE="$(git -C "$ROOT" rev-parse --short HEAD)"
CHANGED="$(git -C "$ROOT" status --porcelain -- StudyHelper Packages project.yml | wc -l | tr -d ' ')"

if [[ $DRY == 1 ]]; then
    echo "Nightly: „$TITLE“, Basis $BASE mit $CHANGED geänderten Dateien, Release nightly auf ${TARGET:0:7}"
    exit 0
fi

"$ROOT/scripts/build-ipa.sh" --nightly
ASSET="$ROOT/build/ipa/StudyHelper-nightly.ipa"
mv "$ROOT/build/ipa/StudyHelper.ipa" "$ASSET"

NOTE_FILE="$ROOT/build/ipa/nightly-notes.md"
{
    echo "**Ungetestet.** Nightly $BUILD von $NAME ($VERSION), gebaut vor den automatischen Tests aus Commit $BASE"
    [[ "$CHANGED" != "0" ]] && echo "mit $CHANGED noch nicht committeten Änderungen an der App."
    echo
    [[ -n "$NOTES" ]] && { echo "## Was ist neu"; echo; echo "$NOTES"; echo; }
    echo "Zum direkten Ausprobieren. Die getestete Fassung folgt als Beta. Unsignierte .ipa (App-ID"
    echo "\`MiloG.StudyHelper1\`), installieren mit SideStore, AltStore, StikStore oder Sideloadly."
} > "$NOTE_FILE"

step "Nightly auf GitHub ersetzen"
if gh release view nightly --repo "$REPO" >/dev/null 2>&1; then
    gh release delete nightly --repo "$REPO" --cleanup-tag --yes
fi
git -C "$ROOT" tag -d nightly >/dev/null 2>&1 || true
gh release create nightly "$ASSET" --repo "$REPO" --target "$TARGET" --prerelease --latest=false \
    --title "$TITLE" --notes-file "$NOTE_FILE"
echo "Veröffentlicht: https://github.com/$REPO/releases/tag/nightly"

step "Source: Eintrag StudyHelper Nightly"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/studyhelper-nightly.XXXXXX")"
trap 'git -C "$ROOT" worktree remove --force "$TMP" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
git -C "$ROOT" worktree add -q --detach "$TMP" origin/main
python3 "$ROOT/scripts/update-source.py" --ipa "$ASSET" --source "$TMP/distribution/source.json" \
    --repo "$REPO" --channel nightly --notes "${NOTES:-Ungetesteter Stand (Nightly $BUILD)}" >/dev/null
python3 "$ROOT/scripts/update-source.py" --check "$TMP/distribution/source.json"
git -C "$TMP" add distribution/source.json
git -C "$TMP" commit -q -m "Source: $TITLE" -m "Nightly in distribution/source.json (D-045)." \
    -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C "$TMP" push -q origin HEAD:main
echo "Source-URL: https://raw.githubusercontent.com/$REPO/main/distribution/source.json"
