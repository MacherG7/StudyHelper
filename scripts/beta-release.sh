#!/usr/bin/env bash
# Publishes the current commit as a beta on GitHub (D-028): builds the signed .ipa on this Mac
# (scripts/build-ipa.sh, Personal Team of <Apple-ID>) and creates the pre-release "v<A.B.C.D>" with the
# .ipa, tagged on the commit. Runs automatically at the end of scripts/publish.sh, i.e. after every commit.
#   scripts/beta-release.sh             current commit (must be pushed to origin/main)
# A version that already has a release is skipped (the version was not raised, see scripts/bump-version.sh).
source "$(dirname "$0")/common.sh"
REPO="MacherG7/StudyHelper"
command -v gh >/dev/null 2>&1 || fail "gh fehlt (brew install gh, dann gh auth login)."

VERSION="$("$ROOT/scripts/bump-version.sh" --show)"
TAG="v$VERSION"
COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "Release $TAG gibt es schon – übersprungen. Vor dem nächsten Commit scripts/bump-version.sh ausführen."
    exit 0
fi
[[ -z "$(git -C "$ROOT" status --porcelain -- StudyHelper Packages project.yml)" ]] \
    || fail "Uncommittete Änderungen an der App – die .ipa entspräche nicht dem Commit. Erst committen."

"$ROOT/scripts/build-ipa.sh"
ASSET="$ROOT/build/ipa/StudyHelper-$VERSION.ipa"
mv "$ROOT/build/ipa/StudyHelper.ipa" "$ASSET"

NOTES="$ROOT/build/ipa/notes.md"
{
    echo "Beta $VERSION, automatisch nach dem Commit gebaut ($(git -C "$ROOT" rev-parse --short HEAD))."
    echo
    echo "## Änderungen"
    echo
    git -C "$ROOT" log -1 --format=%B | grep -v '^Co-Authored-By:' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
    echo
    echo "## Installieren"
    echo
    echo "Signiert mit dem kostenlosen Team von <Apple-ID> (App-ID \`MiloG.StudyHelper1\`). Installierbar nur auf"
    echo "Geräten, die bei diesem Team registriert sind, z. B. über Xcode → Window → Devices and Simulators → „+“."
    echo "Das Profil läuft nach einigen Tagen ab; dann die neueste Beta installieren."
} > "$NOTES"

step "Beta-Release $TAG auf GitHub"
gh release create "$TAG" "$ASSET" --repo "$REPO" --target "$COMMIT" --prerelease \
    --title "StudyHelper $VERSION Beta" --notes-file "$NOTES"
echo "Veröffentlicht: https://github.com/$REPO/releases/tag/$TAG"
