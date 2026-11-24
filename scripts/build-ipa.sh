#!/usr/bin/env bash
# Builds a signed development .ipa for sideloading (free Personal Team of <Apple-ID>, see project.yml).
#   scripts/build-ipa.sh            → build/ipa/StudyHelper.ipa
# Needs the Xcode account to be signed in (Xcode → Settings → Accounts) and the device registered with the team.
source "$(dirname "$0")/common.sh"
generate_project
ARCHIVE="$ROOT/build/StudyHelper.xcarchive"
OUT="$ROOT/build/ipa"
TEAM="$(awk '/DEVELOPMENT_TEAM:/{print $2; exit}' "$ROOT/project.yml")"
rm -rf "$ARCHIVE" "$OUT"
mkdir -p "$OUT"

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
IPA="$(ls "$OUT"/*.ipa | head -1)"
echo "Fertig: $IPA ($(du -h "$IPA" | cut -f1))"
