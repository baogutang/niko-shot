#!/bin/bash
# Re-renders every app screenshot on the website from the current build, in light and dark.
# Needs Google Chrome (for the backdrops) and Pillow. Usage: scripts/render-website-images.sh
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d "${TMPDIR:-/tmp}/niko-website-images.XXXXXX")"
trap 'rm -rf "$work"' EXIT
assets=website/assets

python3 scripts/website-images/make_scene.py "$work/scene"
mkdir -p "$work/snap"
cp "$work/scene/backdrop.png" "$work/scene/scroll-preview-source.png" "$work/scene/scroll-preview-source-dark.png" "$work/snap/"
xcodegen generate >/dev/null
xcodebuild -scheme niko-shot -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build-for-testing >/dev/null
TEST_RUNNER_NIKO_SNAPSHOT_DIR="$work/snap" xcodebuild -scheme niko-shot -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  -only-testing:NikoShotTests/DesignSnapshotTests test-without-building >/dev/null

python3 scripts/website-images/composite.py "$work/snap" "$work/scene" "$assets"
cp "$work/snap/app-ocr.png" "$work/snap/app-ocr-dark.png" "$work/snap/app-recording.png" "$work/snap/app-recording-dark.png" "$assets/"
cp "$work/snap/settings-hotkeys-light.png" "$assets/app-settings.png"
cp "$work/snap/settings-hotkeys-dark.png" "$assets/app-settings-dark.png"
for name in capture scroll scroll-dark ocr ocr-dark recording recording-dark settings settings-dark; do
  width=$(sips -g pixelWidth "$assets/app-$name.png" | awk '/pixelWidth/ { print $2 }')
  height=$(sips -g pixelHeight "$assets/app-$name.png" | awk '/pixelHeight/ { print $2 }')
  sips -z $((height / 2)) $((width / 2)) "$assets/app-$name.png" --out "$assets/app-$name-compact.png" >/dev/null
done
python3 scripts/verify-website.py
