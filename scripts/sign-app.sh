#!/bin/bash
# Signs niko-shot.app with Developer ID, the pinned NIKO identity, or ad hoc, and proves the result.
# Prints the signing kind (developer-id | self-signed | ad-hoc) on stdout; diagnostics go to stderr.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo 'Usage: scripts/sign-app.sh /path/to/niko-shot.app [signature-description-output]' >&2
  exit 64
fi
app="$1"
description="${2:-$(mktemp "${TMPDIR:-/tmp}/niko-shot-signature.XXXXXX")}"
[[ -d "$app" ]]

kind="${CI_SIGNING_KIND:-ad-hoc}"
case "$kind" in
  developer-id) identity="${CI_SIGNING_IDENTITY:?Developer ID signing needs CI_SIGNING_IDENTITY}" ;;
  self-signed) identity="${CI_PACKAGE_SIGNING_IDENTITY:?Self-signed signing needs CI_PACKAGE_SIGNING_IDENTITY}" ;;
  ad-hoc) identity=- ;;
  *) echo "Unknown signing kind: $kind" >&2; exit 64 ;;
esac

sign_args=(--force --options runtime --entitlements niko-shot/Resources/niko-shot.entitlements --sign "$identity")
if [[ "$kind" == developer-id ]]; then sign_args+=(--timestamp); else sign_args+=(--timestamp=none); fi
codesign "${sign_args[@]}" "$app" >&2
codesign --verify --deep --strict --verbose=2 "$app" >&2
codesign --display --verbose=4 "$app" 2> "$description"
requirement="$(codesign --display --requirements - "$app" 2>&1)"

case "$kind" in
  developer-id)
    grep -q '^Authority=Developer ID Application:' "$description"
    ;;
  self-signed)
    pinned="$(tr -d ' \n' < scripts/signing-identity.sha1 | tr '[:upper:]' '[:lower:]')"
    grep -q '^Authority=NIKO Code Signing$' "$description"
    # macOS keeps privacy grants only while this requirement stays the same from release to release.
    if [[ "$requirement" != *'identifier "com.n1ko.niko-shot"'* || "$requirement" != *"H\"$pinned\""* ]]; then
      echo "The designated requirement does not pin the NIKO certificate: $requirement" >&2
      exit 1
    fi
    ;;
  ad-hoc)
    grep -q '^Signature=adhoc$' "$description"
    ;;
esac
echo "Signed $app ($kind): ${requirement##*designated => }" >&2
echo "$kind"
