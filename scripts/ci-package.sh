#!/bin/bash
# Verifies and packages an existing universal Release without changing the original application.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 2 ]]; then
  echo 'Usage: scripts/ci-package.sh /path/to/niko-shot.app output-directory' >&2
  exit 64
fi
source_app="$1"
output_dir="$2"
[[ "$(uname -s)" == Darwin && -d "$source_app" ]]
mkdir -p "$output_dir" build/evidence
for asset in niko-shot-universal.zip niko-shot-universal.dmg release-info.json SHA256SUMS; do
  if [[ -e "$output_dir/$asset" ]]; then
    echo "Refusing to replace an existing package: $output_dir/$asset" >&2
    exit 1
  fi
done

package_stage="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/niko-shot-package.XXXXXX")"
trap 'rm -rf "$package_stage"' EXIT
mkdir -p "$package_stage/dmg" "$package_stage/output"
app="$package_stage/dmg/niko-shot.app"
ditto "$source_app" "$app"
binary="$app/Contents/MacOS/niko-shot"
test -s "$binary"
xcrun lipo "$binary" -verify_arch arm64 x86_64
test -s "$app/Contents/Resources/Metadata.appintents/extract.actionsdata"
if [[ -n "$(find "$app" -type d \( -name XCTest.framework -o -name Testing.framework \) -print -quit)" ]]; then
  echo 'A distributable application must not contain injected test frameworks.' >&2
  exit 1
fi

signing_identity="${CI_SIGNING_IDENTITY:--}"
sign_args=(--force --options runtime --entitlements niko-shot/Resources/niko-shot.entitlements --sign "$signing_identity")
if [[ "$signing_identity" == - ]]; then
  sign_args+=(--timestamp=none)
  signing=ad-hoc
else
  sign_args+=(--timestamp)
  signing=developer-id
fi
codesign "${sign_args[@]}" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
codesign --display --verbose=4 "$app" 2> "$package_stage/signature.txt"
if [[ "$signing" == developer-id ]]; then
  grep -q '^Authority=Developer ID Application:' "$package_stage/signature.txt"
else
  grep -q '^Signature=adhoc$' "$package_stage/signature.txt"
fi

notarized=false
notarize() {
  local file="$1" name="$2"
  local args=(--keychain-profile "$NOTARY_PROFILE" --wait --timeout 25m --output-format json)
  if [[ -n "${CI_SIGNING_KEYCHAIN:-}" ]]; then args+=(--keychain "$CI_SIGNING_KEYCHAIN"); fi
  xcrun notarytool submit "$file" "${args[@]}" > "build/evidence/ci-notary-$name.json"
  python3 - "build/evidence/ci-notary-$name.json" <<'PY'
import json, sys
with open(sys.argv[1]) as stream:
    result = json.load(stream)
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization did not return Accepted; no installation package will be published.')
PY
}

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  [[ "$signing" == developer-id ]]
  ditto -c -k --keepParent "$app" "$package_stage/notary-app.zip"
  notarize "$package_stage/notary-app.zip" app
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  notarized=true
fi

if [[ "$notarized" == true ]]; then
  signing_description='Developer ID signed; Apple notarization accepted and stapled.'
elif [[ "$signing" == developer-id ]]; then
  signing_description='Developer ID signed; NOT notarized. Gatekeeper may block the first open.'
else
  signing_description='Ad hoc development signature; NO Developer ID or Apple notarization. Gatekeeper may block the first open.'
fi
printf '%s\n\n%s\n%s\n%s\n' \
  'niko-shot - macOS 14+, Apple Silicon and Intel' \
  "$signing_description" \
  'Drag niko-shot.app into Applications. Check the release source and SHA256 before opening.' \
  'If macOS blocks this candidate, follow Apple support: https://support.apple.com/102445' \
  > "$package_stage/dmg/READ-ME.txt"
ln -s /Applications "$package_stage/dmg/Applications"

zip="$package_stage/output/niko-shot-universal.zip"
dmg="$package_stage/output/niko-shot-universal.dmg"
ditto -c -k --keepParent "$app" "$zip"
hdiutil create -quiet -volname niko-shot -srcfolder "$package_stage/dmg" -format UDZO -imagekey zlib-level=9 "$dmg"
if [[ "$signing" == developer-id ]]; then
  codesign --force --timestamp --sign "$signing_identity" "$dmg"
  codesign --verify --verbose=2 "$dmg"
fi
if [[ "$notarized" == true ]]; then
  notarize "$dmg" dmg
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
fi
hdiutil verify -quiet "$dmg"
codesign --verify --deep --strict --verbose=2 "$app"
for file in "$zip" "$dmg"; do
  if [[ "$(stat -f %z "$file")" -ge 15000000 ]]; then
    echo "Installation package exceeds the 15 MB budget: $file" >&2
    exit 1
  fi
done

commit="${GITHUB_SHA:-$(git rev-parse HEAD)}"
python3 - "$app" "$package_stage/output/release-info.json" "$package_stage/signature.txt" "$commit" "$signing" "$notarized" <<'PY'
import datetime, hashlib, json, os, plistlib, sys
from pathlib import Path
app, output, signature_file, commit, signing, notarized = sys.argv[1:]
app = Path(app)
with (app / 'Contents/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
assert info['CFBundleIdentifier'] == 'com.n1ko.niko-shot'
binary = app / 'Contents/MacOS/niko-shot'
digest = hashlib.sha256(binary.read_bytes()).hexdigest()
team = next((line.split('=', 1)[1] for line in Path(signature_file).read_text().splitlines()
             if line.startswith('TeamIdentifier=')), None)
repository, run_id = os.environ.get('GITHUB_REPOSITORY'), os.environ.get('GITHUB_RUN_ID')
server = os.environ.get('GITHUB_SERVER_URL', 'https://github.com')
result = {
    'schemaVersion': 1,
    'version': info['CFBundleShortVersionString'],
    'build': info['CFBundleVersion'],
    'bundleIdentifier': info['CFBundleIdentifier'],
    'minimumMacOS': info.get('LSMinimumSystemVersion', '14.0'),
    'architectures': ['arm64', 'x86_64'],
    'commit': commit,
    'sourceProvenance': 'github-actions' if os.environ.get('GITHUB_ACTIONS') == 'true' else 'local-checkout',
    'runUrl': f'{server}/{repository}/actions/runs/{run_id}' if repository and run_id else None,
    'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'signing': signing,
    'teamIdentifier': team if team != 'not set' else None,
    'notarized': notarized == 'true',
    'binarySHA256': digest,
    'assets': {'zip': 'niko-shot-universal.zip', 'dmg': 'niko-shot-universal.dmg'},
}
Path(output).write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
PY
(
  cd "$package_stage/output"
  shasum -a 256 niko-shot-universal.zip niko-shot-universal.dmg release-info.json > SHA256SUMS
  shasum -a 256 --check SHA256SUMS
)
for asset in niko-shot-universal.zip niko-shot-universal.dmg release-info.json SHA256SUMS; do
  mv "$package_stage/output/$asset" "$output_dir/$asset"
done
printf 'Verified packages: %s\nSigning: %s; notarized: %s\n' "$output_dir" "$signing" "$notarized"
