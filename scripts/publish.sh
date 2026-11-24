#!/usr/bin/env bash
# Publishes the current commit: secret check, push to GitHub (origin/main), brings the main checkout
# that Xcode opens up to date (fast-forward; its post-merge hook regenerates the project) and releases the
# commit as a beta with the .ipa built on this Mac (scripts/beta-release.sh, D-028).
# Usage: scripts/publish.sh            after every commit (beta)
#        scripts/publish.sh --final    full version (D-032)
source "$(dirname "$0")/common.sh"

"$ROOT/scripts/check-secrets.sh"

# Every commit raises the version (scripts/bump-version.sh, D-027): warn if this push would not.
if git -C "$ROOT" fetch -q origin main 2>/dev/null; then
    remote_version="$(git -C "$ROOT" show origin/main:project.yml 2>/dev/null | awk -F'"' '/^    (MARKETING_VERSION|CURRENT_PROJECT_VERSION):/{printf "%s ", $2}')"
    local_version="$(awk -F'"' '/^    (MARKETING_VERSION|CURRENT_PROJECT_VERSION):/{printf "%s ", $2}' "$ROOT/project.yml")"
    if [[ -n "$remote_version" && "$remote_version" == "$local_version" ]] \
        && [[ "$(git -C "$ROOT" rev-parse HEAD)" != "$(git -C "$ROOT" rev-parse origin/main)" ]]; then
        echo "Warnung: Version unverändert ($("$ROOT/scripts/bump-version.sh" --show)). Vor dem Commit scripts/bump-version.sh ausführen."
    fi
fi

step "Nach GitHub pushen (origin/main)"
git -C "$ROOT" push origin HEAD:main

# The main checkout is the first entry of `git worktree list`.
MAIN_CHECKOUT="$(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{print substr($0, 10); exit}')"
step "Lokalen Checkout für Xcode aktualisieren: $MAIN_CHECKOUT"
if [[ "$(git -C "$MAIN_CHECKOUT" rev-parse --abbrev-ref HEAD)" != "main" ]]; then
    echo "Übersprungen: dort ist nicht der Branch main ausgecheckt."
elif [[ "$MAIN_CHECKOUT" == "$ROOT" ]]; then
    "$ROOT/scripts/bootstrap.sh"
elif git -C "$MAIN_CHECKOUT" merge --ff-only -q "$(git -C "$ROOT" rev-parse HEAD)"; then
    git -C "$MAIN_CHECKOUT" fetch -q origin || true
    echo "Aktualisiert auf $(git -C "$MAIN_CHECKOUT" log --oneline -1)"
else
    echo "Nicht aktualisiert: lokale Änderungen im Checkout stehen im Weg (git status dort prüfen)."
fi

# A commit that changes what goes into the .ipa becomes a beta release on GitHub: v<A.B.C.D> with the unsigned
# .ipa; other commits (docs, tests, scripts) get none (D-033). "--final" publishes it as a
# full version instead (only after the developer said so, D-032).
"$ROOT/scripts/beta-release.sh" "$@"
