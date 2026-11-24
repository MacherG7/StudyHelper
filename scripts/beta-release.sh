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
#   --force                             beta even if nothing in the .ipa changed
#   --source-only [--tag=vA.B.C.D]      only add an existing release (default v<current version>) to the source
#   --notes=TEXT                        "what's new" in the source (default: subject of the release commit)
# After the release the version is added to distribution/source.json (the source for SideStore, AltStore and
# StikStore, D-034) and committed and pushed as "Source: …" – the only commit without a version bump.
# A beta is only published if something that goes into the .ipa changed since the last release (IPA_PATHS below;
# version lines of project.yml do not count, D-033), and never twice for one version (scripts/bump-version.sh).
source "$(dirname "$0")/common.sh"
REPO="MacherG7/StudyHelper"
FINAL=0
DRY=0
FORCE=0
SOURCE_ONLY=0
SOURCE_TAG=""
SOURCE_NOTES=""
for arg in "$@"; do
    case "$arg" in
        --final) FINAL=1 ;;
        --dry-run) DRY=1 ;;
        --force) FORCE=1 ;;
        --source-only) SOURCE_ONLY=1 ;;
        --tag=*) SOURCE_TAG="${arg#--tag=}" ;;
        --notes=*) SOURCE_NOTES="${arg#--notes=}" ;;
        *) fail "Unbekannte Option: $arg (erlaubt: --final, --dry-run, --force, --source-only)" ;;
    esac
done
# Everything that ends up in the .ipa: the app, the package libraries it links, the build settings and the scripts
# that build it. Tests, docs, other scripts and the remaining package targets are not part of the app.
IPA_PATHS=(
    StudyHelper
    Packages/StudyHelperCore/Package.swift
    Packages/StudyHelperCore/Sources/StudyCore
    Packages/StudyHelperCore/Sources/StudyImport
    Packages/StudyHelperCore/Sources/StudyData
    Packages/StudyHelperCore/Sources/StudyAI
    scripts/build-ipa.sh
    scripts/embed-commit.sh
)

# True if the .ipa of HEAD would differ from the one built at commit $1 (project.yml without its version lines).
ipa_changed() {
    git -C "$ROOT" diff --quiet "$1" HEAD -- "${IPA_PATHS[@]}" || return 0
    git -C "$ROOT" diff "$1" HEAD -- project.yml | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' \
        | grep -qvE '^[+-]    (MARKETING_VERSION|CURRENT_PROJECT_VERSION):'
}
command -v gh >/dev/null 2>&1 || fail "gh fehlt (brew install gh, dann gh auth login)."

# Adds the release's .ipa ($1) to distribution/source.json and commits and pushes that (D-034).
update_source() {
    local ipa="$1" notes
    notes="$SOURCE_NOTES"
    [[ -n "$notes" ]] || notes="$(git -C "$ROOT" log -1 --format=%s "$TAG^{commit}" 2>/dev/null || git -C "$ROOT" log -1 --format=%s)"
    step "Source für SideStore, AltStore und StikStore aktualisieren"
    python3 "$ROOT/scripts/update-source.py" --ipa "$ipa" --source "$ROOT/distribution/source.json" \
        --repo "$REPO" --notes "$notes" >/dev/null
    python3 "$ROOT/scripts/update-source.py" --check "$ROOT/distribution/source.json"
    git -C "$ROOT" add distribution/source.json
    git -C "$ROOT" commit -q -m "Source: $TITLE" -m "Version $VERSION in distribution/source.json (D-034)." \
        -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
    git -C "$ROOT" push -q origin HEAD:main
    echo "Source-URL: https://raw.githubusercontent.com/$REPO/main/distribution/source.json"
}

VERSION="$("$ROOT/scripts/bump-version.sh" --show)"
MARKETING="${VERSION%.*}"
BUILD="${VERSION##*.}"
# "1.0.0" is called "1.0", "1.0.1" stays "1.0.1".
NAME="$MARKETING"
[[ "$MARKETING" == *.0 ]] && NAME="${MARKETING%.0}"
TAG="v$VERSION"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"

exists() { gh release view "$1" --repo "$REPO" >/dev/null 2>&1 || git -C "$ROOT" ls-remote --exit-code --tags origin "refs/tags/$1" >/dev/null 2>&1; }

if [[ $SOURCE_ONLY == 1 ]]; then
    [[ -n "$SOURCE_TAG" ]] && { TAG="$SOURCE_TAG"; VERSION="${TAG#v}"; }
    gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 || fail "Release $TAG gibt es nicht."
    TITLE="$(gh release view "$TAG" --repo "$REPO" --json name --jq .name)"
    DL="$ROOT/build/source-ipa"
    rm -rf "$DL" && mkdir -p "$DL"
    gh release download "$TAG" --repo "$REPO" --pattern '*.ipa' --dir "$DL"
    update_source "$(ls "$DL"/*.ipa | head -1)"
    exit 0
fi

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
    # Last release before this commit: the newest version tag (A.B.C.D) reachable from HEAD.
    git -C "$ROOT" fetch -q --tags origin 2>/dev/null || true
    LAST="$(git -C "$ROOT" describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null || true)"
    if [[ $FORCE == 0 && -n "$LAST" ]] && ! ipa_changed "$LAST"; then
        echo "Seit $LAST hat sich nichts geändert, was in die .ipa gehört – kein neues Release (erzwingen: --force)."
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
update_source "$ASSET"
