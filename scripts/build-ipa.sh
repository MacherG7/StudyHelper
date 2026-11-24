#!/usr/bin/env bash
# Builds the .ipa – always unsigned (D-030): a signed .ipa would carry the Apple ID (e-mail) of the developer
# certificate. SideStore, AltStore, StikStore or Sideloadly sign it with the installing user's Apple ID; to run the
# app on your own device without them, build and run it from Xcode.
#   scripts/build-ipa.sh            → build/ipa/StudyHelper.ipa (unsigned)
#   scripts/build-ipa.sh --final    → marks the build as full version (no "(Beta)" in the app, D-032)
#   --unsigned                      accepted for older calls; the .ipa is unsigned anyway
source "$(dirname "$0")/common.sh"

CHANNEL=Beta
for arg in "$@"; do
    case "$arg" in
        --unsigned) ;;
        --final) CHANNEL=Final ;;
        *) fail "Unbekannte Option: $arg" ;;
    esac
done

generate_project
ARCHIVE="$ROOT/build/StudyHelper.xcarchive"
OUT="$ROOT/build/ipa"
rm -rf "$ARCHIVE" "$OUT"
mkdir -p "$OUT"

step "Archiv bauen (Release, unsigniert, $CHANNEL)"
xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination "generic/platform=iOS" -archivePath "$ARCHIVE" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" STUDYHELPER_CHANNEL="$CHANNEL" -quiet

step ".ipa packen (unsigniert)"
APP="$ARCHIVE/Products/Applications/StudyHelper.app"
[[ -d "$APP" ]] || fail "App fehlt im Archiv: $APP"
STAGE="$OUT/stage"
mkdir -p "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/StudyHelper.app"
(cd "$STAGE" && zip -qry "$OUT/StudyHelper.ipa" Payload)
rm -rf "$STAGE"
IPA="$OUT/StudyHelper.ipa"
echo "Fertig: $IPA ($(du -h "$IPA" | cut -f1), unsigniert)"
