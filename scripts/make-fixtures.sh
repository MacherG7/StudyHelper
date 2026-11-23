#!/usr/bin/env bash
# Regenerates the synthetic Goodnotes test PDFs and their ground-truth JSON.
source "$(dirname "$0")/common.sh"
OUT="$PACKAGE_DIR/Sources/TestFixtures/Resources/Goodnotes"
step "Test-PDFs erzeugen nach $OUT"
swift run --package-path "$PACKAGE_DIR" make-fixtures "$OUT"
