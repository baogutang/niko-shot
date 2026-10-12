#!/bin/bash
# Archives, signs and notarizes only with the caller's existing Developer ID and Keychain notary profile.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${DEVELOPER_ID_APPLICATION:?Set the full Developer ID Application certificate name.}"
: "${NOTARY_PROFILE:?Set an existing notarytool Keychain profile name.}"
mkdir -p build/distribution
xcodegen generate
xcodebuild -scheme niko-shot -configuration Release -destination 'platform=macOS' \
  -archivePath build/distribution/niko-shot.xcarchive \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" archive
app="build/distribution/niko-shot.xcarchive/Products/Applications/niko-shot.app"
codesign --verify --deep --strict --verbose=2 "$app"
ditto -c -k --keepParent "$app" build/distribution/niko-shot-notarization.zip
xcrun notarytool submit build/distribution/niko-shot-notarization.zip \
  --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > build/distribution/notarization.json
xcrun stapler staple "$app"
xcrun stapler validate "$app"
ditto -c -k --keepParent "$app" build/distribution/niko-shot.zip
shasum -a 256 build/distribution/niko-shot.zip > build/distribution/SHA256SUMS
