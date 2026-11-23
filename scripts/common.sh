# Shared helpers for the StudyHelper scripts. Source, don't execute.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT/Packages/StudyHelperCore"
PROJECT="$ROOT/StudyHelper.xcodeproj"
SCHEME="StudyHelper"
SIM_DEVICE="${SIM_DEVICE:-iPhone 17}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData}"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mFehler: %s\033[0m\n' "$*" >&2; exit 1; }

require_xcodegen() {
    command -v xcodegen >/dev/null 2>&1 || fail "xcodegen nicht gefunden. Siehe docs/DECISIONS.md (XcodeGen-Installation)."
}

generate_project() {
    require_xcodegen
    step "Xcode-Projekt mit XcodeGen erzeugen"
    (cd "$ROOT" && xcodegen generate --quiet)
}
