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
    products = config["products"]
except (KeyError, TypeError) as error:
    fail(f"release inventory is missing {error}")

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

lines = [
    'cask "dopa" do',
    f'  version "{version}"',
    f'  sha256 "{sha256}"',
    "",
    f'  url "https://github.com/gw31415/dopa/releases/download/v#{{version}}/{app_archive}",',
    '      verified: "github.com/gw31415/dopa/"',
    '  name "Dopa"',
    '  desc "Prevent a Mac from sleeping only when needed"',
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
lines.extend(["", "end", ""])
cask = "\n".join(lines)
if output:
    destination = Path(output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(cask, encoding="utf-8")
else:
    sys.stdout.write(cask)
