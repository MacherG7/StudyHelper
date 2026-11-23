#!/usr/bin/env bash
# Generates the project and builds the app for the iOS Simulator.
# Usage: scripts/build.sh [--ipad]
source "$(dirname "$0")/common.sh"

DESTINATION="generic/platform=iOS Simulator"
if [[ "${1:-}" == "--ipad" ]]; then
    DESTINATION="platform=iOS Simulator,name=${IPAD_DEVICE:-iPad Pro 11-inch (M5)}"
fi

generate_project
step "App bauen ($DESTINATION)"
xcodebuild build \
    -project "$PROJECT" -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet
echo "Build erfolgreich."
