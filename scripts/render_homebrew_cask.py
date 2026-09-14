#!/usr/bin/env python3
import json
from pathlib import Path, PurePosixPath
import re
import sys


config_path = Path(sys.argv[1])
version = sys.argv[2]
sha256 = sys.argv[3]
output = sys.argv[4]


def fail(message: str) -> None:
    raise SystemExit(f"render-homebrew-cask: {message}")


try:
    config = json.loads(config_path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    fail(f"cannot read release inventory: {error}")

try:
    bundle_name = config["bundleName"]
    app_archive = config["appArchive"]
    distribution = config["macOSDistribution"]
    products = config["products"]
    cli_archive_files = config["cliArchiveFiles"]
except (KeyError, TypeError) as error:
    fail(f"release inventory is missing {error}")
if distribution != {
    "signature": "ad-hoc",
    "hardenedRuntime": True,
    "notarized": False,
}:
    fail("macOSDistribution must be ad-hoc with hardened runtime and no notarization")

for value, suffix, description in (
    (bundle_name, ".app", "bundleName"),
    (app_archive, ".zip", "appArchive"),
):
    if (
        not isinstance(value, str)
        or PurePosixPath(value).name != value
        or not value.endswith(suffix)
    ):
        fail(f"invalid {description}: {value!r}")

cli_products = []
for product in products:
    if not isinstance(product, dict) or product.get("classification") != "cli":
        continue
    name = product.get("name")
    bundle_path = product.get("bundlePath")
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", name):
        fail(f"invalid CLI product name: {name!r}")
    if (
        not isinstance(bundle_path, str)
        or str(PurePosixPath(bundle_path)) != bundle_path
        or not bundle_path.startswith("Contents/")
        or ".." in PurePosixPath(bundle_path).parts
    ):
        fail(f"invalid bundlePath for {name}: {bundle_path!r}")
    cli_products.append((name, bundle_path))
if not cli_products:
    fail("release inventory does not contain a CLI product")

if not isinstance(cli_archive_files, list):
    fail("cliArchiveFiles must be an array")
archive_files = set()
for entry in cli_archive_files:
    if not isinstance(entry, dict) or not isinstance(entry.get("archivePath"), str):
        fail("cliArchiveFiles entries must contain an archivePath")
    archive_files.add(entry["archivePath"])

completion_paths = []
# Cask/StanzaOrder requires repeated completion artifacts to remain grouped by
# stanza type instead of alternating bash, fish, and zsh for each executable.
for shell, extension in (
    ("bash", "bash"),
    ("fish", "fish"),
    ("zsh", "zsh"),
):
    for name, _ in cli_products:
        archive_path = f"completions/{name}.{extension}"
        if archive_path not in archive_files:
            fail(f"release inventory is missing {shell} completion for {name}")
        if shell == "fish":
            target = None
        elif shell == "bash":
            target = name
        else:
            target = f"_{name}"
        completion_paths.append((shell, archive_path, target))

lines = [
    'cask "dopa" do',
    f'  version "{version}"',
    f'  sha256 "{sha256}"',
    "",
    f'  url "https://github.com/gw31415/dopa/releases/download/v#{{version}}/{app_archive}",',
    '      verified: "github.com/gw31415/dopa/"',
    '  name "Dopa"',
    '  desc "Prevent system sleep only when needed"',
    '  homepage "https://github.com/gw31415/dopa"',
    "",
    "  depends_on arch: :arm64",
    "  depends_on macos: :tahoe",
    "",
    f'  app "{bundle_name}"',
]
for name, bundle_path in cli_products:
    source = f"#{{appdir}}/{bundle_name}/{bundle_path}"
    if PurePosixPath(bundle_path).name == name:
        lines.append(f'  binary "{source}"')
    else:
        lines.append(f'  binary "{source}", target: "{name}"')
for shell, archive_path, target in completion_paths:
    source = f"#{{appdir}}/{bundle_name}/Contents/Resources/{archive_path}"
    if target is None:
        lines.append(f'  {shell}_completion "{source}"')
    else:
        lines.append(f'  {shell}_completion "{source}", target: "{target}"')
lines.extend(
    [
        "",
        "  caveats <<~EOS",
        "    Dopa is ad-hoc signed without a Developer ID and is not notarized by Apple.",
        "    macOS may block it after installation or upgrade.",
        "",
        "    After trying to open Dopa once, allow it in:",
        "      System Settings > Privacy & Security > Open Anyway",
        "",
        "    Or, only if you trust this release, remove quarantine from Dopa alone:",
        f'      xattr -dr com.apple.quarantine "#{{appdir}}/{bundle_name}"',
        f'      open "#{{appdir}}/{bundle_name}"',
        "",
        "    Do not use a wildcard: removing quarantine bypasses Apple's malware check.",
        "  EOS",
        "end",
        "",
    ]
)
cask = "\n".join(lines)
if output:
    destination = Path(output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(cask, encoding="utf-8")
else:
    sys.stdout.write(cask)
