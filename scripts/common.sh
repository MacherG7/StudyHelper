# Shared helpers for the StudyHelper scripts. Source, don't execute.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT/Packages/StudyHelperCore"
PROJECT="$ROOT/StudyHelper.xcodeproj"
SCHEME="StudyHelper"
SIM_DEVICE="${SIM_DEVICE:-iPhone 17}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData}"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
# Everything that ends up in the .ipa: the app, the package libraries it links, the build settings and the scripts
# that build it. Tests, docs, other scripts and the remaining package targets are not part of the app.
IPA_PATHS=(
    StudyHelper
    Packages/StudyHelperCore/Package.swift
    Packages/StudyHelperCore/Sources/StudyCore
    Packages/StudyHelperCore/Sources/StudyImport
    Packages/StudyHelperCore/Sources/StudyData
    Packages/StudyHelperCore/Sources/StudyAI
    scripts/build-ipa.sh
    scripts/embed-commit.sh
)

# True if the working tree or index changes anything that goes into the .ipa (D-039): project.yml counts only
# without its version lines. Docs, tests and other scripts do not.
app_changes_pending() {
    [[ -n "$(git -C "$ROOT" status --porcelain -- "${IPA_PATHS[@]}")" ]] && return 0
    git -C "$ROOT" diff HEAD -- project.yml | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' \
        | grep -qvE '^[+-]    (MARKETING_VERSION|CURRENT_PROJECT_VERSION):'
}

fail() { printf '\033[31mFehler: %s\033[0m\n' "$*" >&2; exit 1; }

require_xcodegen() {
    command -v xcodegen >/dev/null 2>&1 || fail "xcodegen nicht gefunden. Siehe docs/DECISIONS.md (XcodeGen-Installation)."
}

generate_project() {
    require_xcodegen
    step "Xcode-Projekt mit XcodeGen erzeugen"
    (cd "$ROOT" && xcodegen generate --quiet)
}
