#!/usr/bin/env python3
"""Seals or verifies one complete, matching arm64/x86_64 release and its seven checksums."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from urllib.parse import urlparse

ARCHITECTURES = ("arm64", "x86_64")
SHARED_FIELDS = (
    "version", "build", "bundleIdentifier", "minimumMacOS", "commit",
    "sourceProvenance", "runUrl", "signing", "teamIdentifier", "notarized",
)
VARIANT_FILES = {
    f"niko-shot-{arch}.{extension}" for arch in ARCHITECTURES for extension in ("zip", "dmg")
} | {f"release-info-{arch}.json" for arch in ARCHITECTURES}
PACKAGE_LIMIT = 15_000_000


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def check_files(directory, names):
    actual = {path.name for path in directory.iterdir()}
    require(actual == names, f"Release assets differ: missing={sorted(names - actual)}, unexpected={sorted(actual - names)}")
    for name in names:
        path = directory / name
        require(path.is_file() and not path.is_symlink() and path.stat().st_size > 0,
                f"Release asset must be a nonempty regular file: {name}")
        if path.suffix in (".zip", ".dmg"):
            require(path.stat().st_size < PACKAGE_LIMIT, f"Installation package exceeds the 15 MB budget: {name}")


def read_checksums(directory, names):
    entries = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_.-]+)", line)
        require(match is not None, "SHA256SUMS contains an invalid entry")
        value, name = match.groups()
        require(name in names and name not in entries, f"SHA256SUMS contains an unexpected or duplicate entry: {name}")
        require(digest(directory / name) == value, f"Package checksum failed: {name}")
        entries[name] = value
    require(set(entries) == names, f"SHA256SUMS does not cover every release file: {sorted(names - set(entries))}")
    return entries


def read_variant(directory, architecture):
    result = json.loads((directory / f"release-info-{architecture}.json").read_text())
    require(isinstance(result, dict) and type(result.get("schemaVersion")) is int and result["schemaVersion"] == 1,
            f"Unsupported {architecture} manifest schema")
    require(result.get("architectures") == [architecture], f"Manifest must contain only {architecture}")
    require(result.get("assets") == {"zip": f"niko-shot-{architecture}.zip", "dmg": f"niko-shot-{architecture}.dmg"},
            f"Manifest contains incorrect {architecture} asset names")
    require(all(field in result for field in SHARED_FIELDS), f"Incomplete {architecture} source/signing information")
    for field in ("version", "build", "minimumMacOS"):
        require(isinstance(result[field], str) and result[field].strip() == result[field] and bool(result[field]),
                f"Invalid {architecture} {field}")
    require(result["bundleIdentifier"] == "com.n1ko.niko-shot", f"Incorrect {architecture} bundle identifier")
    require(isinstance(result["commit"], str) and re.fullmatch(r"[0-9a-f]{40}", result["commit"]),
            f"Invalid {architecture} source commit")
    require(result["sourceProvenance"] in ("github-actions", "local-checkout"), f"Invalid {architecture} source provenance")
    run_url = result["runUrl"]
    if run_url is not None:
        require(isinstance(run_url, str), f"Invalid {architecture} build URL")
        parsed = urlparse(run_url)
        require(parsed.scheme == "https" and bool(parsed.netloc) and "/actions/runs/" in parsed.path,
                f"Invalid {architecture} build URL")
    require(result["sourceProvenance"] != "github-actions" or run_url is not None,
            f"GitHub Actions provenance requires a {architecture} run URL")
    require(result["signing"] in ("ad-hoc", "self-signed", "developer-id"), f"Invalid {architecture} signing status")
    require(isinstance(result["notarized"], bool), f"Invalid {architecture} notarization status")
    require(not result["notarized"] or result["signing"] == "developer-id",
            f"An ad hoc {architecture} application cannot claim notarization")
    if result["signing"] == "developer-id":
        require(isinstance(result["teamIdentifier"], str) and re.fullmatch(r"[A-Z0-9]{10}", result["teamIdentifier"]),
                f"Developer ID {architecture} manifest requires its signing team")
    else:
        require(result["teamIdentifier"] is None, f"Ad hoc {architecture} manifest must not claim a signing team")
    require(isinstance(result.get("binarySHA256"), str) and re.fullmatch(r"[0-9a-f]{64}", result["binarySHA256"]),
            f"Invalid {architecture} executable hash")
    require(isinstance(result.get("createdAt"), str) and bool(result["createdAt"]),
            f"Missing {architecture} package creation time")
    return result


def aggregate(directory):
    variants = {architecture: read_variant(directory, architecture) for architecture in ARCHITECTURES}
    first, second = (variants[architecture] for architecture in ARCHITECTURES)
    for field in SHARED_FIELDS:
        require(first[field] == second[field], f"Architectures have different {field}; refusing a mixed release")
    return {"schemaVersion": 2, **{field: first[field] for field in SHARED_FIELDS}, "variants": variants}


def verify(directory):
    covered = VARIANT_FILES | {"release-info.json"}
    check_files(directory, covered | {"SHA256SUMS"})
    read_checksums(directory, covered)
    actual = json.loads((directory / "release-info.json").read_text())
    require(actual == aggregate(directory), "Aggregate manifest does not match both architecture manifests")


def seal(directory):
    check_files(directory, VARIANT_FILES | {"SHA256SUMS"})
    entries = read_checksums(directory, VARIANT_FILES)
    result = aggregate(directory)
    manifest_stage, checksum_stage, created = None, None, False
    manifest = directory / "release-info.json"
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=directory, prefix=".release-info-", delete=False) as stream:
            manifest_stage = Path(stream.name)
            stream.write(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        entries[manifest.name] = digest(manifest_stage)
        with tempfile.NamedTemporaryFile("w", dir=directory, prefix=".checksums-", delete=False) as stream:
            checksum_stage = Path(stream.name)
            for name, value in entries.items():
                stream.write(f"{value}  {name}\n")
        os.link(manifest_stage, manifest)  # Exclusive creation preserves any existing release metadata.
        created = True
        os.replace(checksum_stage, directory / "SHA256SUMS")
    except BaseException:
        if created:
            manifest.unlink(missing_ok=True)
        raise
    finally:
        for path in (manifest_stage, checksum_stage):
            if path is not None:
                path.unlink(missing_ok=True)
    verify(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="Directory containing both architecture packages and manifests")
    parser.add_argument("--verify", action="store_true", help="Verify the sealed eight-asset release without changing any files")
    arguments = parser.parse_args()
    try:
        require(arguments.directory.is_dir(), "Release directory does not exist")
        if arguments.verify:
            verify(arguments.directory)
        else:
            seal(arguments.directory)
    except (OSError, ValueError, TypeError) as error:
        print(f"Release contract failed: {error}", file=sys.stderr)
        return 1
    print("Verified split release: arm64 + x86_64, 8 assets, 7 SHA256 entries.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
