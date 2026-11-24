#!/usr/bin/env bash
# App version "A.B.C.D" (D-027): A.B.C = MARKETING_VERSION (CFBundleShortVersionString, at most three numbers on
# iOS), D = CURRENT_PROJECT_VERSION (build). Both live in project.yml.
#   scripts/bump-version.sh              before every commit: D + 1 (0.0.1.0 → 0.0.1.1), adds project.yml to the index
#   scripts/bump-version.sh --set 0.0.2  bigger version (only after asking the developer): 0.0.2.0
#   scripts/bump-version.sh --show       prints the current version
source "$(dirname "$0")/common.sh"
FILE="$ROOT/project.yml"
marketing="$(awk -F'"' '/^    MARKETING_VERSION:/{print $2; exit}' "$FILE")"
build="$(awk -F'"' '/^    CURRENT_PROJECT_VERSION:/{print $2; exit}' "$FILE")"
[[ "$marketing" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]] \
    || { echo "MARKETING_VERSION/CURRENT_PROJECT_VERSION in project.yml unlesbar: '$marketing' '$build'" >&2; exit 1; }

case "${1:-}" in
    --show) echo "$marketing.$build"; exit 0 ;;
    --set)
        [[ "${2:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Aufruf: scripts/bump-version.sh --set A.B.C" >&2; exit 2; }
        marketing="$2"; build=0 ;;
    "") build=$((build + 1)) ;;
    *) echo "Aufruf: scripts/bump-version.sh [--set A.B.C | --show]" >&2; exit 2 ;;
esac

sed -i '' -E "s/^(    MARKETING_VERSION: )\"[^\"]*\"/\1\"$marketing\"/; s/^(    CURRENT_PROJECT_VERSION: )\"[^\"]*\"/\1\"$build\"/" "$FILE"
git -C "$ROOT" add project.yml
echo "Version $marketing.$build"
