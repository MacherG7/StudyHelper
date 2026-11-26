#!/usr/bin/env bash
# Marks a finished phase as a release: annotated tag on the current commit, pushed to GitHub.
# Usage: scripts/release.sh phase-2 "Phase 2: KI-Anbieter"
source "$(dirname "$0")/common.sh"
[[ $# -eq 2 ]] || fail "Aufruf: scripts/release.sh <tag> \"<Titel>\""
"$ROOT/scripts/publish.sh"
step "Release-Tag $1 anlegen und pushen"
git -C "$ROOT" tag -a "$1" -m "$2"
git -C "$ROOT" push origin "$1"
if command -v gh >/dev/null 2>&1; then
    # Pre-release: a phase release has no .ipa and must not be shown as "Latest" (only a full version is, D-032).
    gh release create "$1" --repo MacherG7/StudyHelper --title "$2" --generate-notes --verify-tag --prerelease
else
    echo "Hinweis: gh nicht installiert – nur der Tag ist auf GitHub, keine Release-Seite."
fi
