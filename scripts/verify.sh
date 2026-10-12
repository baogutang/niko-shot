#!/bin/bash
# Runs reproducible stage gates and preserves complete local diagnostic logs.
set -euo pipefail
cd "$(dirname "$0")/.."
stage="${1:-all}"
mkdir -p build/evidence
xcodegen generate > "build/evidence/${stage}-generate.log" 2>&1
xcodebuild -scheme niko-shot -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData -parallel-testing-enabled NO clean build test > "build/evidence/${stage}-xcodebuild.log" 2>&1
tail -n 6 "build/evidence/${stage}-xcodebuild.log"
