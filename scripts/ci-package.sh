#!/bin/bash
# Verifies and packages one explicitly selected Release architecture without changing the original app.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 3 ]]; then
  echo 'Usage: scripts/ci-package.sh /path/to/niko-shot.app output-directory arm64|x86_64' >&2
  exit 64
fi
source_app="$1"
output_dir="$2"
architecture="$3"
case "$architecture" in
  arm64) platform_description='Apple Silicon (M-series)' ;;
  x86_64) platform_description='Intel' ;;
  *) echo "Unsupported package architecture: $architecture" >&2; exit 64 ;;
esac
[[ "$(uname -s)" == Darwin && -d "$source_app" ]]
mkdir -p "$output_dir" build/evidence
for asset in "niko-shot-$architecture.zip" "niko-shot-$architecture.dmg" "release-info-$architecture.json" release-info.json; do
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
python3 - "$app" "$architecture" <<'PY'
import subprocess, sys
from pathlib import Path
app, expected = Path(sys.argv[1]), sys.argv[2]
magic = {bytes.fromhex(value) for value in (
    'feedface', 'cefaedfe', 'feedfacf', 'cffaedfe',
    'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca')}
main = app / 'Contents/MacOS/niko-shot'
checked = set()
for binary in [main, *app.rglob('*')]:
    if not binary.is_file():
        continue
    resolved = binary.resolve()
    if resolved in checked:
        continue
    with binary.open('rb') as stream:
        header = stream.read(4)
    if header not in magic:
        if binary == main:
            raise SystemExit('The application executable is not a Mach-O binary.')
        continue
    if not resolved.is_relative_to(app.resolve()):
        raise SystemExit(f'Application binary escapes its bundle: {binary}')
    architectures = subprocess.check_output(['xcrun', 'lipo', '-archs', str(binary)], text=True).split()
    if architectures != [expected]:
        raise SystemExit(f'Refusing mixed or incorrect architecture in {binary}: {architectures}; expected only {expected}.')
    checked.add(resolved)
if main.resolve() not in checked:
    raise SystemExit('No architecture-verified application executable was found.')
print(f'Verified {len(checked)} Mach-O binaries: {expected} only.')
PY
test -s "$app/Contents/Resources/Metadata.appintents/extract.actionsdata"
if [[ -n "$(find "$app" -type d \( -name XCTest.framework -o -name Testing.framework \) -print -quit)" ]]; then
  echo 'A distributable application must not contain injected test frameworks.' >&2
  exit 1
fi

signing_identity="${CI_SIGNING_IDENTITY:--}"
signing="$(scripts/sign-app.sh "$app" "$package_stage/signature.txt")"

notarized=false
notarize() {
  local file="$1" name="$2"
  local args=(--keychain-profile "$NOTARY_PROFILE" --wait --timeout 25m --output-format json)
  if [[ -n "${CI_SIGNING_KEYCHAIN:-}" ]]; then args+=(--keychain "$CI_SIGNING_KEYCHAIN"); fi
  xcrun notarytool submit "$file" "${args[@]}" > "build/evidence/ci-notary-$architecture-$name.json"
  python3 - "build/evidence/ci-notary-$architecture-$name.json" <<'PY'
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
elif [[ "$signing" == self-signed ]]; then
  signing_description='Signed with the stable NIKO identity (not Apple notarized): macOS keeps permissions across updates; Gatekeeper asks once on first open.'
else
  signing_description='Signature: ad hoc. Apple notarization: not configured. Gatekeeper may require first-open approval.'
fi
printf '%s\n\n%s\n%s\n%s\n' \
  "niko-shot - macOS 14+, $platform_description ($architecture)" \
  "$signing_description" \
  'Drag niko-shot.app into Applications. Check the release source and SHA256 before opening.' \
  'For first-open instructions, see Apple support: https://support.apple.com/102445' \
  > "$package_stage/dmg/READ-ME.txt"
ln -s /Applications "$package_stage/dmg/Applications"

zip="$package_stage/output/niko-shot-$architecture.zip"
dmg="$package_stage/output/niko-shot-$architecture.dmg"
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
python3 - "$app" "$package_stage/output/release-info-$architecture.json" "$package_stage/signature.txt" "$commit" "$signing" "$notarized" "$architecture" <<'PY'
import datetime, hashlib, json, os, plistlib, sys
from pathlib import Path
app, output, signature_file, commit, signing, notarized, architecture = sys.argv[1:]
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
    'architectures': [architecture],
    'commit': commit,
    'sourceProvenance': 'github-actions' if os.environ.get('GITHUB_ACTIONS') == 'true' else 'local-checkout',
    'runUrl': f'{server}/{repository}/actions/runs/{run_id}' if repository and run_id else None,
    'createdAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'signing': signing,
    'teamIdentifier': team if team != 'not set' else None,
    'notarized': notarized == 'true',
    'binarySHA256': digest,
    'assets': {'zip': f'niko-shot-{architecture}.zip', 'dmg': f'niko-shot-{architecture}.dmg'},
}
Path(output).write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
PY
python3 - "$package_stage/output" "$output_dir" "$architecture" <<'PY'
import hashlib, os, re, shutil, sys, tempfile
from pathlib import Path
stage, output, architecture = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
allowed = {f'niko-shot-{arch}.{extension}' for arch in ('arm64', 'x86_64') for extension in ('zip', 'dmg')}
allowed |= {f'release-info-{arch}.json' for arch in ('arm64', 'x86_64')}
def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()
entries = {}
sums = output / 'SHA256SUMS'
if sums.exists():
    if sums.is_symlink() or not sums.is_file():
        raise SystemExit('SHA256SUMS must be a regular file.')
    for line in sums.read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  ([A-Za-z0-9_.-]+)', line)
        if not match or match[2] not in allowed or match[2] in entries:
            raise SystemExit('Existing SHA256SUMS has an invalid or duplicate package entry.')
        path = output / match[2]
        if path.is_symlink() or not path.is_file() or digest(path) != match[1]:
            raise SystemExit(f'Existing package checksum failed: {match[2]}')
        entries[match[2]] = match[1]
new_assets = [f'niko-shot-{architecture}.zip', f'niko-shot-{architecture}.dmg', f'release-info-{architecture}.json']
if any(name in entries for name in new_assets):
    raise SystemExit('Refusing to replace an existing architecture checksum.')
if set(path.name for path in output.iterdir()) != set(entries) | ({'SHA256SUMS'} if sums.exists() else set()):
    raise SystemExit('Output directory contains files outside the existing package checksums.')
created, checksum_stage = [], None
try:
    for name in new_assets:
        path = output / name
        with path.open('xb') as destination:
            created.append(path)
            with (stage / name).open('rb') as source:
                shutil.copyfileobj(source, destination)
        entries[name] = digest(path)
    with tempfile.NamedTemporaryFile('w', dir=output, prefix='.checksums-', delete=False) as stream:
        checksum_stage = Path(stream.name)
        for name, value in entries.items():
            stream.write(f'{value}  {name}\n')
    os.replace(checksum_stage, sums)
except BaseException:
    for path in created:
        path.unlink(missing_ok=True)
    raise
finally:
    if checksum_stage is not None:
        checksum_stage.unlink(missing_ok=True)
PY
printf 'Verified %s packages: %s\nSigning: %s; notarized: %s\n' "$architecture" "$output_dir" "$signing" "$notarized"
