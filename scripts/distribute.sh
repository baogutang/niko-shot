#!/bin/bash
# Independently archives both Mac architectures and packages them with optional Developer ID/notarization.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -gt 1 ]]; then
  echo 'Usage: scripts/distribute.sh [output-directory]' >&2
  exit 64
fi
output_dir="${1:-build/distribution/packages}"
if [[ -e "$output_dir" && ( ! -d "$output_dir" || -n "$(find "$output_dir" -mindepth 1 -print -quit)" ) ]]; then
  echo "Refusing to replace an existing distribution: $output_dir" >&2
  exit 1
fi
identity="${DEVELOPER_ID_APPLICATION:--}"
team=''
if [[ "$identity" == - ]]; then
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo 'Notarization requires a Developer ID Application signing identity.' >&2
    exit 1
  fi
elif [[ "$identity" == 'Developer ID Application:'* ]]; then
  team="${identity##*\(}"
  team="${team%\)}"
  [[ "$team" =~ ^[A-Z0-9]{10}$ ]]
else
  echo 'Use a full Developer ID Application certificate name or leave signing unset for ad hoc packages.' >&2
  exit 64
fi
mkdir -p build/distribution
distribution_stage="$(mktemp -d build/distribution/split-archive.XXXXXX)"
trap 'rm -rf "$distribution_stage"' EXIT
export CI_SIGNING_IDENTITY="$identity"
xcodegen generate
for architecture in arm64 x86_64; do
  archive="$distribution_stage/niko-shot-$architecture.xcarchive"
  xcodebuild -scheme niko-shot -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$archive" -derivedDataPath "$distribution_stage/DerivedData-$architecture" \
    ARCHS="$architecture" ONLY_ACTIVE_ARCH=NO SWIFT_VERSION=6.0 SWIFT_STRICT_CONCURRENCY=complete \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES ENABLE_TESTABILITY=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO clean archive
  scripts/ci-package.sh "$archive/Products/Applications/niko-shot.app" "$output_dir" "$architecture"
done
python3 scripts/release-manifest.py "$output_dir"
