#!/usr/bin/env bash
# Puts a new beta into the app source for SideStore, AltStore and StikStore (docs/DECISIONS.md D-024):
# takes an .ipa (built unsigned unless --ipa is given), adds it to the published source.json of the public
# distribution repository, uploads the .ipa there as a GitHub release and then publishes icon.png and
# source.json (in that order, so the new version only appears once its download exists).
# Runs automatically for every release with an .ipa (.github/workflows/source.yml).
#
#   scripts/publish-source.sh ["Was ist neu"]            build, update the source, upload
#   scripts/publish-source.sh --ipa PATH ["Was ist neu"]  use an existing .ipa instead of building one
#   scripts/publish-source.sh --notes-file PATH …         release notes from a file
#   scripts/publish-source.sh --skip-existing …           do nothing if this version/build is already published
#   scripts/publish-source.sh --replace ["…"]             overwrite the same version/build (fixes only)
#   scripts/publish-source.sh --no-upload ["…"]           only write build/source/source.json
#
# distribution/source.json is the template (texts, icon, permissions); the version history lives in the
# published source.json. Public repository: $SOURCE_REPO (default MacherG7/StudyHelper-Source).
source "$(dirname "$0")/common.sh"

SOURCE_REPO="${SOURCE_REPO:-MacherG7/StudyHelper-Source}"
IPA=""
UPLOAD=1
MODE=""
NOTES=""
NOTES_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ipa) [[ $# -ge 2 ]] || fail "--ipa braucht einen Pfad."; IPA="$2"; shift 2 ;;
        --notes-file) [[ $# -ge 2 ]] || fail "--notes-file braucht einen Pfad."; NOTES_FILE="$2"; shift 2 ;;
        --no-upload) UPLOAD=0; shift ;;
        --replace) MODE="--replace"; shift ;;
        --skip-existing) MODE="--skip-existing"; shift ;;
        -*) fail "Unbekannte Option: $1" ;;
        *) [[ -z "$NOTES" ]] || fail "Nur ein Text für „Was ist neu“ erlaubt."; NOTES="$1"; shift ;;
    esac
done
if [[ -n "$NOTES_FILE" ]]; then
    NOTES="$(cat "$NOTES_FILE")"
elif [[ -z "$NOTES" ]]; then
    NOTES="$(git -C "$ROOT" log -1 --format=%s)"
fi
command -v python3 >/dev/null 2>&1 || fail "python3 nicht gefunden (Xcode Command Line Tools installieren)."

OUT="$ROOT/build/source"
rm -rf "$OUT"
mkdir -p "$OUT"

if [[ $UPLOAD == 1 ]]; then
    command -v gh >/dev/null 2>&1 || fail "gh wird zum Hochladen gebraucht: brew install gh && gh auth login"
    VISIBILITY="$(gh repo view "$SOURCE_REPO" --json visibility -q .visibility 2>/dev/null)" ||
        fail "Repository $SOURCE_REPO nicht gefunden. Einmalig anlegen: gh repo create $SOURCE_REPO --public --add-readme"
    [[ "$VISIBILITY" == "PUBLIC" ]] ||
        fail "$SOURCE_REPO ist nicht öffentlich. SideStore, AltStore und StikStore laden Source und .ipa ohne Anmeldung."
fi

step "Veröffentlichte Source laden"
PUBLISHED=()
if command -v gh >/dev/null 2>&1 &&
    gh api "repos/$SOURCE_REPO/contents/source.json" -H "Accept: application/vnd.github.raw" \
        > "$OUT/published.json" 2>/dev/null && python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$OUT/published.json" 2>/dev/null; then
    PUBLISHED=(--versions-from "$OUT/published.json")
    echo "Bisherige Versionen aus $SOURCE_REPO übernommen."
else
    echo "Noch keine veröffentlichte Source – erste Version."
fi

if [[ -z "$IPA" ]]; then
    "$ROOT/scripts/build-ipa.sh" --unsigned
    IPA="$ROOT/build/ipa/StudyHelper.ipa"
fi
[[ -f "$IPA" ]] || fail ".ipa nicht gefunden: $IPA"

step "Source aktualisieren"
ARGS=(--ipa "$IPA" --source "$ROOT/distribution/source.json" --output "$OUT/source.json"
      --repo "$SOURCE_REPO" --notes "$NOTES" ${PUBLISHED[@]+"${PUBLISHED[@]}"})   # bash 3.2-safe
[[ -n "$MODE" ]] && ARGS+=("$MODE")
python3 "$ROOT/scripts/update-source.py" "${ARGS[@]}" > "$OUT/release.env"
SKIP=0
source "$OUT/release.env"   # TAG, ASSET, TITLE, VERSION, BUILD – or SKIP=1
if [[ $SKIP == 1 ]]; then
    echo "Nichts zu tun."
    exit 0
fi

# Creates or updates one file on the default branch of $SOURCE_REPO; skips it when unchanged.
put_file() {
    local path="$1" file="$2" remote local_sha
    remote="$(gh api "repos/$SOURCE_REPO/contents/$path" --jq .sha 2>/dev/null || true)"
    [[ "$remote" =~ ^[0-9a-f]{40}$ ]] || remote=""   # missing file (404) or error body
    local_sha="$(git hash-object "$file")"
    if [[ "$remote" == "$local_sha" ]]; then
        echo "$path unverändert."
        return
    fi
    python3 - "$file" "$path aktualisieren ($TAG)" "$remote" > "$OUT/body.json" <<'PY'
import base64, json, sys
file, message, sha = sys.argv[1:4]
body = {"message": message, "content": base64.b64encode(open(file, "rb").read()).decode()}
if sha:
    body["sha"] = sha
json.dump(body, sys.stdout)
PY
    gh api -X PUT "repos/$SOURCE_REPO/contents/$path" --input "$OUT/body.json" --silent
    echo "$path hochgeladen."
}

if [[ $UPLOAD == 0 ]]; then
    echo
    echo "$TITLE eingetragen (nicht hochgeladen): $OUT/source.json"
    exit 0
fi

step "Icon hochladen"
put_file icon.png "$ROOT/distribution/icon.png"

step ".ipa als Release $TAG in $SOURCE_REPO hochladen"
cp "$IPA" "$OUT/$ASSET"
if gh release view "$TAG" --repo "$SOURCE_REPO" >/dev/null 2>&1; then
    [[ "$MODE" == "--replace" ]] || fail "Release $TAG gibt es schon in $SOURCE_REPO (zum Ersetzen: --replace)."
    gh release upload "$TAG" "$OUT/$ASSET" --repo "$SOURCE_REPO" --clobber
else
    gh release create "$TAG" "$OUT/$ASSET" --repo "$SOURCE_REPO" --title "$TITLE" --notes "$NOTES"
fi

step "source.json veröffentlichen"
put_file source.json "$OUT/source.json"

echo
echo "$TITLE ist in der Source. Source-URL für SideStore, AltStore und StikStore:"
echo "  https://raw.githubusercontent.com/$SOURCE_REPO/main/source.json"
