#!/usr/bin/env bash
# Publishes the current commit: secret check, push to GitHub (origin/main), and brings the main
# checkout that Xcode opens up to date (fast-forward; its post-merge hook regenerates the project).
# Usage: scripts/publish.sh            after every commit
source "$(dirname "$0")/common.sh"

"$ROOT/scripts/check-secrets.sh"

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
