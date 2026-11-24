#!/usr/bin/env bash
# Puts a new beta into the app source for SideStore, AltStore and StikStore (docs/DECISIONS.md D-024):
# builds an unsigned .ipa, adds it to distribution/source.json, uploads the .ipa as a GitHub release of the
# public distribution repository and then publishes icon.png and source.json there (in that order, so the
# new version only appears once its download exists).
#
#   scripts/publish-source.sh ["Was ist neu"]            build, update the source, upload
#   scripts/publish-source.sh --ipa PATH ["Was ist neu"]  use an existing .ipa instead of building one
#   scripts/publish-source.sh --no-upload ["…"]           only update distribution/source.json
#   scripts/publish-source.sh --replace ["…"]             overwrite the same version/build (fixes only)
#
# Public repository: $SOURCE_REPO (default MacherG7/StudyHelper-Source); create it once with
#   gh repo create MacherG7/StudyHelper-Source --public --add-readme
# Without notes the subject of the last commit is used. Afterwards commit distribution/source.json.
source "$(dirname "$0")/common.sh"

SOURCE_REPO="${SOURCE_REPO:-MacherG7/StudyHelper-Source}"
IPA=""
UPLOAD=1
REPLACE=0
NOTES=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ipa) [[ $# -ge 2 ]] || fail "--ipa braucht einen Pfad."; IPA="$2"; shift 2 ;;
        --no-upload) UPLOAD=0; shift ;;
        --replace) REPLACE=1; shift ;;
        -*) fail "Unbekannte Option: $1" ;;
        *) [[ -z "$NOTES" ]] || fail "Nur ein Text für „Was ist neu“ erlaubt."; NOTES="$1"; shift ;;
    esac
done
[[ -n "$NOTES" ]] || NOTES="$(git -C "$ROOT" log -1 --format=%s)"
command -v python3 >/dev/null 2>&1 || fail "python3 nicht gefunden (Xcode Command Line Tools installieren)."

if [[ $UPLOAD == 1 ]]; then
    command -v gh >/dev/null 2>&1 || fail "gh wird zum Hochladen gebraucht: brew install gh && gh auth login"
    VISIBILITY="$(gh repo view "$SOURCE_REPO" --json visibility -q .visibility 2>/dev/null)" ||
        fail "Repository $SOURCE_REPO nicht gefunden. Einmalig anlegen: gh repo create $SOURCE_REPO --public --add-readme"
    [[ "$VISIBILITY" == "PUBLIC" ]] ||
        fail "$SOURCE_REPO ist nicht öffentlich. SideStore, AltStore und StikStore laden Source und .ipa ohne Anmeldung."
fi

if [[ -z "$IPA" ]]; then
    "$ROOT/scripts/build-ipa.sh" --unsigned
    IPA="$ROOT/build/ipa/StudyHelper.ipa"
fi
[[ -f "$IPA" ]] || fail ".ipa nicht gefunden: $IPA"

OUT="$ROOT/build/source"
rm -rf "$OUT"
mkdir -p "$OUT"
step "Source aktualisieren"
ARGS=(--ipa "$IPA" --source "$ROOT/distribution/source.json" --output "$OUT/source.json"
      --repo "$SOURCE_REPO" --notes "$NOTES")
[[ $REPLACE == 1 ]] && ARGS+=(--replace)
python3 "$ROOT/scripts/update-source.py" "${ARGS[@]}" > "$OUT/release.env"
source "$OUT/release.env"   # TAG, ASSET, TITLE, VERSION, BUILD

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

if [[ $UPLOAD == 1 ]]; then
    step "Icon hochladen"
    put_file icon.png "$ROOT/distribution/icon.png"

    step ".ipa als Release $TAG in $SOURCE_REPO hochladen"
    cp "$IPA" "$OUT/$ASSET"
    if gh release view "$TAG" --repo "$SOURCE_REPO" >/dev/null 2>&1; then
        [[ $REPLACE == 1 ]] || fail "Release $TAG gibt es schon in $SOURCE_REPO (zum Ersetzen: --replace)."
        gh release upload "$TAG" "$OUT/$ASSET" --repo "$SOURCE_REPO" --clobber
    else
        gh release create "$TAG" "$OUT/$ASSET" --repo "$SOURCE_REPO" --title "$TITLE" --notes "$NOTES"
    fi

    step "source.json veröffentlichen"
    put_file source.json "$OUT/source.json"
fi

cp "$OUT/source.json" "$ROOT/distribution/source.json"
echo
echo "$TITLE steht in distribution/source.json."
if [[ $UPLOAD == 1 ]]; then
    echo "Source-URL für SideStore, AltStore und StikStore:"
    echo "  https://raw.githubusercontent.com/$SOURCE_REPO/main/source.json"
fi
echo "Jetzt distribution/source.json committen und scripts/publish.sh ausführen."
