#!/usr/bin/env bash
# Runs the local checks. Unit tests never call real AI models or APIs.
# Usage: scripts/test.sh [--core] [--ui]
#   --core  only secret check, script tests + package tests on the Mac (fast)
#   --ui    additionally run the XCTest UI tests on the simulator
source "$(dirname "$0")/common.sh"

CORE_ONLY=0
WITH_UI=0
for arg in "$@"; do
    case "$arg" in
        --core) CORE_ONLY=1 ;;
        --ui) WITH_UI=1 ;;
        *) fail "Unbekannte Option: $arg" ;;
    esac
done

[[ $CORE_ONLY == 1 && $WITH_UI == 1 ]] && fail "--core und --ui schließen sich aus."

"$ROOT/scripts/check-secrets.sh"

step "Skript-Tests und Source für SideStore/AltStore/StikStore prüfen"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$ROOT/scripts/tests" -q
python3 "$ROOT/scripts/update-source.py" --check "$ROOT/distribution/source.json"

step "Package-Tests auf dem Mac (swift test)"
swift test --package-path "$PACKAGE_DIR"

if [[ $CORE_ONLY == 1 ]]; then
    echo "Fertig (nur Core)."
    exit 0
fi

DESTINATION="platform=iOS Simulator,name=$SIM_DEVICE"

step "Package-Tests auf dem iOS-Simulator ($SIM_DEVICE)"
(cd "$PACKAGE_DIR" && xcodebuild test \
    -scheme StudyHelperCore-Package \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA/Package" \
    CODE_SIGNING_ALLOWED=NO \
    -quiet)

generate_project
step "App-Unit-Tests auf dem iOS-Simulator ($SIM_DEVICE)"
xcodebuild test \
    -project "$PROJECT" -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -only-testing:StudyHelperTests \
    -quiet

if [[ $WITH_UI == 1 ]]; then
    step "UI-Tests auf dem iOS-Simulator ($SIM_DEVICE)"
    xcodebuild test \
        -project "$PROJECT" -scheme "$SCHEME" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA" \
        -only-testing:StudyHelperUITests \
        -quiet
fi

echo "Alle Tests erfolgreich."
