#!/usr/bin/env python3
"""Validate static Pages delivery, safe links, image layout and native-guide provenance."""
from hashlib import sha256
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit
import json
import re
import shutil
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / "website"
errors = []


def require(condition, message):
    if not condition:
        errors.append(message)


class Page(HTMLParser):
    def __init__(self, path):
        super().__init__(convert_charrefs=True)
        self.path, self.ids, self.references = path, set(), []
        self.images, self.headings, self.language = [], [], None
        self.sections, self.current_provider = {}, None
        self.feed(path.read_text())

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        identity = attrs.get("id")
        if identity:
            require(identity not in self.ids, f"{self.path.name}: duplicate id {identity}")
            self.ids.add(identity)
        if tag == "html":
            self.language = attrs.get("lang")
        if tag == "h1":
            self.headings.append(attrs)
        if tag == "section" and "guide-card" in attrs.get("class", "").split():
            self.current_provider = identity
            self.sections[identity] = 0
        if tag == "div" and "guide-step" in attrs.get("class", "").split() and "official-links" not in attrs.get("class", "").split():
            if self.current_provider:
                self.sections[self.current_provider] += 1
        if tag == "img":
            self.images.append(attrs)
            require("alt" in attrs, f"{self.path.name}: missing image alternative text")
            require(attrs.get("width", "").isdigit() and attrs.get("height", "").isdigit(),
                    f"{self.path.name}: image dimensions missing for {attrs.get('src')}")
        for name in ("href", "src"):
            if name in attrs:
                self.references.append(attrs[name])
        for target in attrs.get("aria-controls", "").split():
            self.references.append("#" + target)
        if tag == "a" and attrs.get("target") == "_blank":
            require("noopener" in attrs.get("rel", "").split(), f"{self.path.name}: unsafe new-window link")

    def handle_endtag(self, tag):
        if tag == "section":
            self.current_provider = None


pages = {path.resolve(): Page(path) for path in sorted(SITE.glob("*.html"))}
require(len(pages) >= 2, "Home page and provider guide must both exist")
local_reference_count = 0
for path, page in pages.items():
    require(page.language == "zh-CN", f"{path.name}: document language must be explicit")
    require(len(page.headings) == 1, f"{path.name}: expected one primary heading")
    for reference in page.references:
        url = urlsplit(reference)
        if url.scheme or url.netloc:
            require(url.scheme == "https", f"{path.name}: unexpected external scheme {reference}")
            require(not url.username and not url.password, f"{path.name}: credential-bearing URL")
            continue
        target = (path.parent / unquote(url.path)).resolve() if url.path else path
        if target.is_dir():
            target = target / "index.html"
        require(target.is_relative_to(SITE.resolve()), f"{path.name}: local link escapes website")
        require(target.is_file(), f"{path.name}: missing local destination {reference}")
        local_reference_count += 1
        if not target.is_file() or not url.fragment:
            continue
        if target.suffix == ".html":
            require(unquote(url.fragment) in pages[target].ids, f"{path.name}: missing anchor {reference}")
        elif target.suffix == ".svg":
            svg_ids = {element.get("id") for element in ET.parse(target).iter()}
            require(url.fragment in svg_ids, f"{path.name}: missing SVG symbol {reference}")
    for attrs in page.images:
        image = path.parent / attrs.get("src", "")
        if image.suffix == ".png" and image.is_file():
            data = image.read_bytes()
            require(data[:8] == b"\x89PNG\r\n\x1a\n", f"{image.name}: invalid PNG signature")
            actual = struct.unpack(">II", data[16:24])
            declared = (int(attrs["width"]), int(attrs["height"]))
            # Icons deliberately render at a smaller, square size; source-ratio must remain correct.
            require(actual[0] * declared[1] == actual[1] * declared[0],
                    f"{path.name}: distorted/unstable image dimensions for {image.name}: {actual} vs {declared}")

manifest = json.loads((SITE / "guide-data.json").read_text())
native_source = ROOT / manifest["source"]
require(sha256(native_source.read_bytes()).hexdigest() == manifest["sourceSHA256"],
        "Official guide changed in the app: regenerate website/guide.html and guide-data.json")
guide = pages[(SITE / "guide.html").resolve()]
expected_providers = {"baidu", "google", "youdao", "deepl", "custom"}
require({item["id"] for item in manifest["providers"]} == expected_providers, "All five provider paths are required")
for provider in manifest["providers"]:
    require(guide.sections.get(provider["id"]) == provider["stepCount"] == 3,
            f"Guide for {provider['id']} must expose its three native setup steps")
    for address in provider["officialURLs"]:
        require(address in guide.references, f"Guide is missing an official link for {provider['id']}: {address}")
require(manifest["verifiedDate"] in (SITE / "guide.html").read_text(), "Official documentation check date is missing")
all_sources = "\n".join(path.read_text() for path in SITE.glob("*.*") if path.suffix in {".html", ".css", ".js"})
for pattern in (r"OWNER_TOKEN", r"YOUR_(?:GITHUB_)?USERNAME", r"gh[pousr]_[A-Za-z0-9]{30,}", r"-----BEGIN .*PRIVATE KEY-----"):
    require(not re.search(pattern, all_sources), "Website contains a placeholder or credential signature")
for preview in ("ocr", "settings", "recording", "scroll"):
    for theme in ("", "-dark"):
        require((SITE / "assets" / f"app-{preview}{theme}.png").is_file(), f"Missing native {preview}{theme} preview")
require((SITE / "assets/TABLER-LICENSE.txt").is_file(), "Bundled icons need their original license")
require((SITE / "assets/readme-hero.svg").is_file(), "README brand banner missing")
css = (SITE / "styles.css").read_text()
for accommodation in ("prefers-reduced-motion:reduce", "prefers-reduced-transparency:reduce", '[data-theme="dark"]', ":focus-visible"):
    require(accommodation in css, f"Missing appearance/accessibility accommodation: {accommodation}")
for kind in ("dmg", "zip", "checksums"):
    require(f'data-download="{kind}"' in (SITE / "index.html").read_text(), f"Missing {kind} release destination")
require("尚未 Developer ID 公证" in all_sources, "Candidate distribution must explain current signing limitations")
require("sourceProvenance" in (ROOT / "scripts/ci-package.sh").read_text(), "Release packages must retain source provenance")

if shutil.which("node"):
    result = subprocess.run(["node", "--check", str(SITE / "site.js")], capture_output=True, text=True)
    require(result.returncode == 0, "Website JavaScript syntax is invalid: " + result.stderr.strip())
else:
    print("Node unavailable: JavaScript syntax must be checked separately.")

if errors:
    print("Website verification failed:\n" + "\n".join("- " + error for error in errors), file=sys.stderr)
    sys.exit(1)
print(f"Website verified: {len(pages)} pages, {local_reference_count} local links/assets, five native provider guides.")
