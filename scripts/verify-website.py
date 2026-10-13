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
        self.inputs, self.downloads, self.fallbacks = [], {}, {}
        self.noscript_depth = 0
        self.sections, self.current_provider = {}, None
        self.feed(path.read_text())

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if tag == "noscript":
            self.noscript_depth += 1
        if tag == "input":
            self.inputs.append(attrs)
        if tag == "a" and "data-download" in attrs:
            self.downloads[attrs["data-download"]] = attrs
        if tag == "a" and "data-download-fallback" in attrs:
            self.fallbacks[attrs["data-download-fallback"]] = (attrs, self.noscript_depth > 0)
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
        for name in ("srcset", "imagesrcset"):
            for item in attrs.get(name, "").split(","):
                tokens = item.split()
                if tokens:
                    self.references.append(tokens[0])
        for target in attrs.get("aria-controls", "").split():
            self.references.append("#" + target)
        if tag == "a" and attrs.get("target") == "_blank":
            require("noopener" in attrs.get("rel", "").split(), f"{self.path.name}: unsafe new-window link")

    def handle_endtag(self, tag):
        if tag == "noscript":
            self.noscript_depth -= 1
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
for variant, limit in (("", 260_000), ("-800", 80_000)):
    image = SITE / "assets" / f"capture-sculpture{variant}.jpg"
    require(image.is_file(), f"Missing responsive hero image: {image.name}")
    if image.is_file():
        require(image.read_bytes().startswith(b"\xff\xd8\xff"), f"Invalid hero JPEG: {image.name}")
        require(image.stat().st_size < limit, f"Hero exceeds delivery size budget: {image.name}")
for preview in ("ocr", "settings", "recording", "scroll", "annotation"):
    for theme in (("",) if preview == "annotation" else ("", "-dark")):
        require((SITE / "assets" / f"app-{preview}{theme}-compact.png").is_file(),
                f"Missing compact native {preview}{theme} preview")
css = (SITE / "styles.css").read_text()
for accommodation in ("prefers-reduced-motion:reduce", "prefers-reduced-transparency:reduce", '[data-theme="dark"]', ":focus-visible"):
    require(accommodation in css, f"Missing appearance/accessibility accommodation: {accommodation}")
home = pages[(SITE / "index.html").resolve()]
navigation_url = "https://github.com/baogutang/niko-shot/releases/tag/nightly"
for kind in ("dmg", "zip", "checksums", "manifest"):
    require(home.downloads.get(kind, {}).get("href") == navigation_url,
            f"{kind} must retain a safe GitHub navigation URL until the complete candidate is verified")
chip_inputs = [item for item in home.inputs if item.get("name") == "download-architecture"]
require(len(chip_inputs) == 2 and {item.get("value") for item in chip_inputs} == {"arm64", "x86_64"}
        and all(item.get("type") == "radio" for item in chip_inputs),
        "Architecture selection must expose two native keyboard-accessible radios")
require([item.get("value") for item in chip_inputs if "checked" in item] == ["arm64"],
        "The explicitly labelled default must be Apple Silicon")
for architecture in ("arm64", "x86_64"):
    for package in ("dmg", "zip"):
        attrs, in_noscript = home.fallbacks.get(f"{architecture}-{package}", ({}, False))
        require(in_noscript and attrs.get("href") == navigation_url,
                f"JavaScript-free navigation is missing for {architecture} {package}")
site_script = (SITE / "site.js").read_text()
require("navigator.platform" not in site_script and "navigator.userAgent" not in site_script,
        "Browser platform strings must not be used as Mac hardware detection")
require("niko-shot-universal" not in all_sources, "The website must not offer a Universal fallback")
require("尚未 Developer ID 公证" in all_sources, "Candidate distribution must explain current signing limitations")
require("sourceProvenance" in (ROOT / "scripts/ci-package.sh").read_text(), "Release packages must retain source provenance")

if shutil.which("node"):
    result = subprocess.run(["node", "--check", str(SITE / "site.js")], capture_output=True, text=True)
    require(result.returncode == 0, "Website JavaScript syntax is invalid: " + result.stderr.strip())
    # Executes the real site script with offline GitHub response fixtures; no browser or network is used.
    release_probe = r'''
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const source = fs.readFileSync(process.argv[1], "utf8");
const navigationURL = "https://github.com/baogutang/niko-shot/releases/tag/nightly";
const tag = "candidate-123-1-abcdefabcdef";
const prefix = `https://github.com/baogutang/niko-shot/releases/download/${tag}/`;
const names = ["niko-shot-arm64.dmg", "niko-shot-arm64.zip", "niko-shot-x86_64.dmg", "niko-shot-x86_64.zip",
  "release-info-arm64.json", "release-info-x86_64.json", "release-info.json", "SHA256SUMS"];
let checks = 0;
async function run(changeAssets = items => items, options = {}) {
  const anchors = Object.fromEntries(["dmg", "zip", "checksums", "manifest"].map(kind => {
    let href = navigationURL;
    const writes = [];
    return [kind, { writes, get href() { return href; }, set href(value) { href = value; writes.push(value); },
      setAttribute() {}, querySelector() { return { textContent: "" }; } }];
  }));
  const radios = ["arm64", "x86_64"].map(value => ({ value, checked: false,
    addEventListener(type, listener) { this[type] = listener; } }));
  const status = { textContent: "" }, hint = { textContent: "", hidden: true };
  const selectIntel = () => { radios[0].checked = false; radios[1].checked = true; radios[1].change(); };
  let requests = 0;
  const assets = changeAssets(names.map(name => ({ name, size: 100, state: "uploaded", browser_download_url: prefix + name })));
  const context = {
    document: { documentElement: { dataset: {}, classList: { add() {}, remove() {} } },
      querySelector(selector) {
        if (selector === "#release-status") return status;
        if (selector === "#selected-chip") return hint;
        if (selector === "#chip-selector" || selector === "#download-actions") return { hidden: true };
        const match = selector.match(/^\[data-download="(\w+)"\]$/);
        return match ? anchors[match[1]] : null;
      },
      querySelectorAll(selector) { return selector === 'input[name="download-architecture"]' ? radios : []; }
    },
    window: { addEventListener() {} },
    matchMedia: () => ({ matches: false, addEventListener() {} }),
    localStorage: { getItem: () => null },
    fetch: async () => {
      requests++;
      return { ok: !options.networkFailure, json: async () => requests === 1
        ? { body: options.noMarker ? "" : `<!-- niko-shot-candidate: ${tag} -->` }
        : { tag_name: options.wrongTag ? "another-candidate" : tag, draft: !!options.draft, assets } };
    },
    AbortController, URL, console, setTimeout: () => 1, clearTimeout() {}
  };
  vm.runInNewContext(source, context, { timeout: 1000 });
  if (options.selectBeforeReady) selectIntel();
  await new Promise(setImmediate);
  return { anchors, radios, status, hint, selectIntel };
}
function assertFallback(result) {
  for (const anchor of Object.values(result.anchors)) {
    assert.equal(anchor.href, navigationURL);
    assert.ok(anchor.writes.every(value => value === navigationURL), "Incomplete candidate must never partially enable links");
  }
  result.selectIntel();
  for (const anchor of Object.values(result.anchors)) assert.equal(anchor.href, navigationURL);
  assert.match(result.hint.textContent, /Intel/);
  checks++;
}
(async () => {
  const ready = await run();
  assert.equal(ready.radios[0].checked, true);
  assert.match(ready.hint.textContent, /M 芯片/);
  assert.equal(ready.anchors.dmg.href, prefix + "niko-shot-arm64.dmg");
  assert.equal(ready.anchors.zip.href, prefix + "niko-shot-arm64.zip");
  ready.selectIntel();
  assert.equal(ready.anchors.dmg.href, prefix + "niko-shot-x86_64.dmg");
  assert.equal(ready.anchors.zip.href, prefix + "niko-shot-x86_64.zip");
  assert.equal(ready.anchors.checksums.href, prefix + "SHA256SUMS");
  assert.equal(ready.anchors.manifest.href, prefix + "release-info.json");
  checks++;
  const early = await run(undefined, { selectBeforeReady: true });
  assert.equal(early.anchors.dmg.href, prefix + "niko-shot-x86_64.dmg");
  assert.equal(early.anchors.zip.href, prefix + "niko-shot-x86_64.zip");
  checks++;
  for (const name of names) {
    assertFallback(await run(items => items.filter(item => item.name !== name)));
    assertFallback(await run(items => items.map(item => item.name === name ? { ...item, state: "new" } : item)));
    assertFallback(await run(items => items.map(item => item.name === name
      ? { ...item, browser_download_url: item.browser_download_url.replace(tag, "candidate-122-1-abcdefabcdef") } : item)));
  }
  assertFallback(await run(items => [...items, items[0]]));
  assertFallback(await run(items => items.map((item, index) => index === 0 ? { ...item, size: 0 } : item)));
  assertFallback(await run(items => items.map((item, index) => index === 0
    ? { ...item, browser_download_url: item.browser_download_url.replace("github.com", "example.com") } : item)));
  assertFallback(await run(items => items.map((item, index) => index === 0
    ? { ...item, browser_download_url: item.browser_download_url.replace("https://", "https://credential@") } : item)));
  assertFallback(await run(() => ["niko-shot-universal.dmg", "niko-shot-universal.zip", "release-info.json", "SHA256SUMS"]
    .map(name => ({ name, size: 100, state: "uploaded", browser_download_url: prefix + name }))));
  for (const options of [{ noMarker: true }, { wrongTag: true }, { draft: true }, { networkFailure: true }])
    assertFallback(await run(undefined, options));
  console.log(`Architecture download routing verified: ${checks} offline cases, eight assets required together.`);
})().catch(error => { console.error(error); process.exitCode = 1; });
'''
    result = subprocess.run(["node", "-e", release_probe, str(SITE / "site.js")], capture_output=True, text=True, timeout=20)
    require(result.returncode == 0, "Architecture download regression failed: " + result.stderr.strip())
    if result.returncode == 0:
        print(result.stdout.strip())
else:
    print("Node unavailable: JavaScript syntax must be checked separately.")

if errors:
    print("Website verification failed:\n" + "\n".join("- " + error for error in errors), file=sys.stderr)
    sys.exit(1)
print(f"Website verified: {len(pages)} pages, {local_reference_count} local links/assets, five native provider guides.")
