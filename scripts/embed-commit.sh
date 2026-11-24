#!/bin/bash
# Xcode build phase of the app target (project.yml): writes the git commit the app is built from into the built
# Info.plist as StudyHelperCommit, shown in the settings next to the version (D-029). "+" marks uncommitted changes
# to the app (StudyHelper/, Packages/, project.yml), so a build from a work in progress never looks like a commit.
set -u
PLIST="${TARGET_BUILD_DIR:?}/${INFOPLIST_PATH:?}"
[ -f "$PLIST" ] || { echo "warning: Info.plist fehlt, Commit nicht eingetragen: $PLIST"; exit 0; }
cd "${SRCROOT:?}" || exit 0
commit="$(git rev-parse --short=7 HEAD 2>/dev/null || true)"
if [ -n "$commit" ] && [ -n "$(git status --porcelain -- StudyHelper Packages project.yml 2>/dev/null)" ]; then
    commit="$commit+"
fi
/usr/libexec/PlistBuddy -c "Delete :StudyHelperCommit" "$PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :StudyHelperCommit string ${commit:-unbekannt}" "$PLIST"
echo "StudyHelperCommit = ${commit:-unbekannt}"
