#!/usr/bin/env bash
# Publishes the current commit on GitHub with the unsigned .ipa built on this Mac (scripts/build-ipa.sh --unsigned;
# a signed one would carry the developer's Apple ID, D-030). Runs at the end of scripts/publish.sh, i.e. after every
# commit (D-028). Version A.B.C.D from project.yml (D-027); beta or full version as a mark, not in the number (D-032):
#   scripts/beta-release.sh             beta: pre-release "v<A.B.C.D>", title "StudyHelper <A.B[.C]> Beta <D>",
#                                       the app shows "A.B.C.D (Beta)"
#   scripts/beta-release.sh --final     full version (only after the developer said so): same version with a new
#                                       build, normal release "v<A.B.C.D>" plus tag "v<A.B.C>", title
#                                       "StudyHelper <A.B[.C]>", the app shows no "(Beta)"
#   --dry-run                           only print what would be published
# A beta whose version already has a release is skipped (the version was not raised, see scripts/bump-version.sh).
source "$(dirname "$0")/common.sh"
REPO="MacherG7/StudyHelper"
FINAL=0
DRY=0
for arg in "$@"; do
    case "$arg" in
        --final) FINAL=1 ;;
        --dry-run) DRY=1 ;;
        *) fail "Unbekannte Option: $arg (erlaubt: --final, --dry-run)" ;;
    esac
done
command -v gh >/dev/null 2>&1 || fail "gh fehlt (brew install gh, dann gh auth login)."

VERSION="$("$ROOT/scripts/bump-version.sh" --show)"
MARKETING="${VERSION%.*}"
BUILD="${VERSION##*.}"
# "1.0.0" is called "1.0", "1.0.1" stays "1.0.1".
NAME="$MARKETING"
[[ "$MARKETING" == *.0 ]] && NAME="${MARKETING%.0}"
TAG="v$VERSION"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"

exists() { gh release view "$1" --repo "$REPO" >/dev/null 2>&1 || git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/$1" >/dev/null 2>&1; }

if [[ $FINAL == 1 ]]; then
    exists "$TAG" && fail "$TAG ist schon veröffentlicht. Eine Vollversion braucht den nächsten Build: scripts/bump-version.sh, committen, dann scripts/publish.sh --final."
    exists "v$MARKETING" && fail "Die Vollversion v$MARKETING gibt es schon. Für eine neue Version erst scripts/bump-version.sh --set (nach Rückfrage)."
    TITLE="StudyHelper $NAME"
    KIND="Vollversion"
else
    if exists "$TAG"; then
        echo "Release $TAG gibt es schon – übersprungen. Vor dem nächsten Commit scripts/bump-version.sh ausführen."
        exit 0
    fi
    TITLE="StudyHelper $NAME Beta $BUILD"
    KIND="Beta"
fi

if [[ $DRY == 1 ]]; then
    echo "$KIND: Tag $TAG$([[ $FINAL == 1 ]] && echo " + v$MARKETING"), Titel „$TITLE“, $([[ $FINAL == 1 ]] && echo "normales Release" || echo "Pre-Release"), Commit ${COMMIT:0:7}"
    exit 0
fi
[[ -z "$(git -C "$ROOT" status --porcelain -- StudyHelper Packages project.yml)" ]] \
    || fail "Uncommittete Änderungen an der App – die .ipa entspräche nicht dem Commit. Erst committen."

"$ROOT/scripts/build-ipa.sh" --unsigned $([[ $FINAL == 1 ]] && echo --final)
ASSET="$ROOT/build/ipa/StudyHelper-$VERSION.ipa"
mv "$ROOT/build/ipa/StudyHelper.ipa" "$ASSET"

NOTES="$ROOT/build/ipa/notes.md"
{
    if [[ $FINAL == 1 ]]; then
        echo "Vollversion $NAME ($VERSION), gebaut aus Commit $(git -C "$ROOT" rev-parse --short HEAD)."
    else
        echo "Beta $BUILD von $NAME ($VERSION), automatisch nach dem Commit gebaut ($(git -C "$ROOT" rev-parse --short HEAD))."
    fi
    echo
    echo "## Änderungen"
    echo
    git -C "$ROOT" log -1 --format=%B | grep -v '^Co-Authored-By:' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
    echo
    echo "## Installieren"
    echo
    echo "Unsignierte .ipa (App-ID \`MiloG.StudyHelper1\`). Installieren mit SideStore, AltStore, StikStore oder"
    echo "Sideloadly: sie signieren die App beim Installieren mit deiner eigenen Apple-ID."
} > "$NOTES"

step "$KIND $TAG auf GitHub"
if [[ $FINAL == 1 ]]; then
    gh release create "$TAG" "$ASSET" --repo "$REPO" --target "$COMMIT" --latest \
        --title "$TITLE" --notes-file "$NOTES"
    # The full version is also reachable as v<A.B.C>, on the same commit as v<A.B.C.D>.
    git -C "$ROOT" tag -f "v$MARKETING" "$COMMIT" >/dev/null
    git -C "$ROOT" push -q origin "refs/tags/v$MARKETING"
    echo "Tag v$MARKETING gesetzt."
else
    gh release create "$TAG" "$ASSET" --repo "$REPO" --target "$COMMIT" --prerelease \
        --title "$TITLE" --notes-file "$NOTES"
fi
echo "Veröffentlicht: https://github.com/$REPO/releases/tag/$TAG"
