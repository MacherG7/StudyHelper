#!/usr/bin/env bash
# Builds an .ipa for sideloading.
#   scripts/build-ipa.sh             → build/ipa/StudyHelper.ipa, signed (the developer's free Personal Team, see
#                                      project.yml); needs the Xcode account signed in (Xcode → Settings →
#                                      Accounts) and the device registered with the team. Local use only: a signed
#                                      .ipa carries the Apple ID of the certificate, so it is never published (D-030).
#   scripts/build-ipa.sh --unsigned  → build/ipa/StudyHelper.ipa, unsigned, for the SideStore/AltStore/StikStore
#                                      source (they re-sign with the user's Apple ID, see docs/DECISIONS.md D-024).
source "$(dirname "$0")/common.sh"

UNSIGNED=0
for arg in "$@"; do
    case "$arg" in
        --unsigned) UNSIGNED=1 ;;
        *) fail "Unbekannte Option: $arg" ;;
    esac
done

generate_project
ARCHIVE="$ROOT/build/StudyHelper.xcarchive"
OUT="$ROOT/build/ipa"
TEAM="$(awk '/DEVELOPMENT_TEAM:/{print $2; exit}' "$ROOT/project.yml")"
rm -rf "$ARCHIVE" "$OUT"
mkdir -p "$OUT"

if [[ $UNSIGNED == 1 ]]; then
    step "Archiv bauen (Release, unsigniert)"
    xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -destination "generic/platform=iOS" -archivePath "$ARCHIVE" \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -quiet

    step ".ipa packen (unsigniert)"
    APP="$ARCHIVE/Products/Applications/StudyHelper.app"
    [[ -d "$APP" ]] || fail "App fehlt im Archiv: $APP"
    STAGE="$OUT/stage"
    mkdir -p "$STAGE/Payload"
    ditto "$APP" "$STAGE/Payload/StudyHelper.app"
    (cd "$STAGE" && zip -qry "$OUT/StudyHelper.ipa" Payload)
    rm -rf "$STAGE"
else
    step "Archiv bauen (Release, Team $TEAM)"
    xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -destination "generic/platform=iOS" -archivePath "$ARCHIVE" \
        -allowProvisioningUpdates -quiet

    step ".ipa exportieren (Development)"
    cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>debugging</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>compileBitcode</key><false/>
  <key>stripSwiftSymbols</key><true/>
</dict></plist>
PLIST
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT" \
        -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates -quiet
fi
IPA="$(ls "$OUT"/*.ipa | head -1)"
echo "Fertig: $IPA ($(du -h "$IPA" | cut -f1))"
