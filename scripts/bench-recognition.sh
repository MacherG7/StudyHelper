#!/usr/bin/env bash
# Runs the real recognition on a local sample and scores it (docs/DECISIONS.md D-022).
#   scripts/bench-recognition.sh <name> [--baseline <older-name>]
# Uses LocalSamples/GPG_bearbeitbar.pdf (or $BENCH_PDF) and its *.reference.json; runs land in LocalSamples/bench/.
source "$(dirname "$0")/common.sh"
NAME="${1:?Aufruf: scripts/bench-recognition.sh <name> [--baseline <name>]}"; shift
PDF="${BENCH_PDF:-$ROOT/LocalSamples/GPG_bearbeitbar.pdf}"
REF="${PDF%.pdf}.reference.json"
OUT="$ROOT/LocalSamples/bench"
mkdir -p "$OUT"
step "recognition-bench bauen"
(cd "$PACKAGE_DIR" && swift build -c release --product recognition-bench >/dev/null)
step "Erkennung: $(basename "$PDF")"
"$PACKAGE_DIR/.build/release/recognition-bench" "$PDF" "$OUT/$NAME.json"
EXTRA=()
if [[ "${1:-}" == "--baseline" ]]; then EXTRA=(--baseline "$OUT/$2.json"); shift 2; fi
python3 "$ROOT/scripts/score-recognition.py" "$OUT/$NAME.json" --ref "$REF" ${EXTRA[@]+"${EXTRA[@]}"} "$@"
