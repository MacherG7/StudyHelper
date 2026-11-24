#!/usr/bin/env bash
# Fails if tracked or untracked (not ignored) files contain something that looks
# like an API key, or if a PDF lies outside the synthetic fixture folder
# (real Goodnotes exports must never be committed, see docs/SPEC.md).
source "$(dirname "$0")/common.sh"
cd "$ROOT"

PATTERN='(sk-ant-[A-Za-z0-9_-]{10,}|sk-proj-[A-Za-z0-9_-]{10,}|sk-svcacct-[A-Za-z0-9_-]{10,}|sk-admin-[A-Za-z0-9_-]{10,}|sk-[A-Za-z0-9_-]{32,}|hf_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|[Bb]earer [A-Za-z0-9._-]{20,})'
FIXTURE_DIR='Packages/StudyHelperCore/Sources/TestFixtures/Resources/'

step "Nach API-Keys und fremden PDFs suchen"
files=()
while IFS= read -r -d '' f; do
    [[ -f "$f" ]] && files+=("$f")   # skip files deleted in the working tree
done < <(git ls-files -z --cached --others --exclude-standard)

key_hits=""
for f in "${files[@]}"; do
    [[ "$f" == "scripts/check-secrets.sh" ]] && continue
    if out=$(grep -I -n -E "$PATTERN" -- "$f"); then
        key_hits+="$f: ${out}"$'\n'
    fi
done

pdf_hits=""
for f in "${files[@]}"; do
    if [[ "$f" == *.[pP][dD][fF] && "$f" != "$FIXTURE_DIR"* ]]; then
        pdf_hits+="$f"$'\n'
    fi
done

if [[ -n "$key_hits" ]]; then
    printf '%s' "$key_hits" >&2
    fail "Mögliche Secrets gefunden (siehe oben). Keys gehören in die Keychain."
fi
if [[ -n "$pdf_hits" ]]; then
    printf '%s' "$pdf_hits" >&2
    fail "PDF außerhalb von $FIXTURE_DIR gefunden. Echte Exporte gehören nach LocalSamples/."
fi
echo "Keine Secrets oder fremden PDFs gefunden."
