#!/usr/bin/env python3

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile


def fail(message: str) -> None:
    raise SystemExit(f"verify-published-release: {message}")


if len(sys.argv) != 3:
    fail("usage: verify_published_release.py vX.Y.Z ASSET_DIRECTORY")

tag = sys.argv[1]
if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
    fail(f"invalid release tag: {tag!r}")
version = tag[1:]
root = Path(__file__).resolve().parent.parent
asset_directory = Path(sys.argv[2]).resolve()
if not asset_directory.is_dir():
    fail(f"asset directory does not exist: {asset_directory}")


def load_json(path: Path, description: str):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot read {description} {path}: {error}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_exact_keys(value, expected: set[str], description: str) -> None:
    if not isinstance(value, dict) or set(value) != expected:
        fail(f"{description} fields differ from the release schema")


config = load_json(root / "release" / "artifacts.json", "release inventory")
try:
    bundle_name = config["bundleName"]
    app_archive_name = config["appArchive"]
    cli_archive_name = config["cliArchive"]
    homebrew_cask_name = config["homebrewCask"]
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
    fail("release inventory must require ad-hoc signing, hardened runtime, and no notarization")

expected_asset_names = {
    app_archive_name,
    cli_archive_name,
    homebrew_cask_name,
    "release-manifest.json",
    "SHA256SUMS",
}
actual_asset_names = {path.name for path in asset_directory.iterdir() if path.is_file()}
if actual_asset_names != expected_asset_names:
    fail(
        "published asset names differ from the inventory "
        f"(expected={sorted(expected_asset_names)}, actual={sorted(actual_asset_names)})"
    )

checksum_names = {
    app_archive_name,
    cli_archive_name,
    homebrew_cask_name,
    "release-manifest.json",
}
checksums = {}
try:
    checksum_lines = (asset_directory / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
except (OSError, UnicodeError) as error:
    fail(f"cannot read SHA256SUMS: {error}")
for line in checksum_lines:
    match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._+-]*)", line)
    if not match or match.group(2) in checksums:
        fail("SHA256SUMS has an invalid or duplicate entry")
    checksums[match.group(2)] = match.group(1)
if set(checksums) != checksum_names:
    fail("SHA256SUMS entries differ from the inventory")
for name, expected_digest in checksums.items():
    if sha256(asset_directory / name) != expected_digest:
        fail(f"checksum mismatch for {name}")

manifest = load_json(asset_directory / "release-manifest.json", "release manifest")
require_exact_keys(
    manifest,
    {"schemaVersion", "version", "tag", "target", "distribution", "assets"},
    "release manifest",
)
if manifest["schemaVersion"] != 1 or manifest["tag"] != tag or manifest["version"] != version:
    fail("release manifest version or tag does not match the requested release")
if manifest["target"] != {"os": "macOS", "architecture": "arm64"}:
    fail("release manifest target is not macOS arm64")
if manifest["distribution"] != distribution:
    fail("release manifest distribution policy differs from the inventory")
if not isinstance(manifest["assets"], list):
    fail("release manifest assets must be an array")
try:
    manifest_assets = {asset["name"]: asset for asset in manifest["assets"]}
except (KeyError, TypeError):
    fail("release manifest contains an invalid asset")
if len(manifest_assets) != 3 or set(manifest_assets) != {
    app_archive_name,
    cli_archive_name,
    homebrew_cask_name,
}:
    fail("release manifest asset set differs from the inventory")

expected_app_products = [
    {"name": product["name"], "path": f"{bundle_name}/{product['bundlePath']}"}
    for product in products
]
app_manifest = manifest_assets[app_archive_name]
require_exact_keys(app_manifest, {"name", "sha256", "kind", "bundle", "products"}, "app asset")
if app_manifest != {
    "name": app_archive_name,
    "sha256": checksums[app_archive_name],
    "kind": "app",
    "bundle": bundle_name,
    "products": expected_app_products,
}:
    fail("app manifest entry differs from the inventory or archive digest")

cli_products = [product for product in products if product["classification"] == "cli"]
expected_cli_products = [
    {"name": product["name"], "path": product["archivePath"]}
    for product in cli_products
]
expected_cli_files = sorted(
    [product["archivePath"] for product in cli_products]
    + [entry["archivePath"] for entry in cli_archive_files]
)
cli_manifest = manifest_assets[cli_archive_name]
require_exact_keys(cli_manifest, {"name", "sha256", "kind", "files", "products"}, "CLI asset")
if cli_manifest != {
    "name": cli_archive_name,
    "sha256": checksums[cli_archive_name],
    "kind": "cli",
    "files": expected_cli_files,
    "products": expected_cli_products,
}:
    fail("CLI manifest entry differs from the inventory or archive digest")

homebrew_cask_manifest = manifest_assets[homebrew_cask_name]
require_exact_keys(
    homebrew_cask_manifest,
    {"name", "sha256", "kind", "token", "appArchive"},
    "Homebrew Cask asset",
)
if homebrew_cask_manifest != {
    "name": homebrew_cask_name,
    "sha256": checksums[homebrew_cask_name],
    "kind": "homebrew-cask",
    "token": "dopa",
    "appArchive": app_archive_name,
}:
    fail("Homebrew Cask manifest entry differs from the inventory or archive digest")


def safe_member_path(name: str, description: str) -> PurePosixPath:
    path = PurePosixPath(name)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        fail(f"unsafe path in {description}: {name!r}")
    return path


app_archive_path = asset_directory / app_archive_name
try:
    with zipfile.ZipFile(app_archive_path) as archive:
        zip_files = set()
        for entry in archive.infolist():
            path = safe_member_path(entry.filename.rstrip("/"), "app archive")
            if path.parts[0] == "__MACOSX":
                continue
            if path.parts[0] != bundle_name:
                fail(f"app archive entry is outside {bundle_name}: {entry.filename!r}")
            if not entry.is_dir():
                zip_files.add(str(path))
except (OSError, zipfile.BadZipFile) as error:
    fail(f"cannot inspect app archive: {error}")
for product in products:
    expected_path = f"{bundle_name}/{product['bundlePath']}"
    if expected_path not in zip_files:
        fail(f"app archive is missing {product['name']}: {expected_path}")

cli_archive_path = asset_directory / cli_archive_name
try:
    with tarfile.open(cli_archive_path, "r:gz") as archive:
        tar_files = set()
        for member in archive.getmembers():
            safe_member_path(member.name, "CLI archive")
            if member.isfile():
                tar_files.add(member.name)
            elif not member.isdir():
                fail(f"unsupported CLI archive member type: {member.name!r}")
except (OSError, tarfile.TarError) as error:
    fail(f"cannot inspect CLI archive: {error}")
if tar_files != set(expected_cli_files):
    fail("CLI archive file set differs from the inventory")


def run_checked(arguments: list[str], description: str) -> None:
    try:
        subprocess.run(
            arguments,
            check=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=60,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = ""
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            detail = ": " + error.stderr.decode("utf-8", errors="replace").strip()
        fail(f"{description} failed{detail}")


def validate_ad_hoc_signature(path: Path, name: str) -> None:
    run_checked(["codesign", "--verify", "--strict", str(path)], f"signature verification for {name}")
    try:
        details = subprocess.check_output(
            ["codesign", "-dvvv", str(path)],
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        fail(f"cannot inspect ad-hoc signature for {name}: {error}")
    if "Signature=adhoc" not in details or "Authority=" in details:
        fail(f"{name} must use an ad-hoc signature without a signing identity")
    if not re.search(r"flags=0x[0-9a-f]+\([^)]*runtime[^)]*\)", details):
        fail(f"{name} does not enable the hardened runtime")


with tempfile.TemporaryDirectory(prefix="dopa-published-release.") as temporary_value:
    temporary = Path(temporary_value)
    expected_cask = temporary / "expected-dopa.rb"
    run_checked(
        [
            str(root / "scripts" / "render-homebrew-cask.sh"),
            version,
            checksums[app_archive_name],
            str(expected_cask),
        ],
        "Homebrew Cask regeneration",
    )
    published_cask = asset_directory / homebrew_cask_name
    if expected_cask.read_bytes() != published_cask.read_bytes():
        fail("published Homebrew Cask differs from the release inventory and app checksum")
    run_checked(["ruby", "-c", str(published_cask)], "Homebrew Cask syntax validation")

    app_extract = temporary / "app"
    app_extract.mkdir()
    run_checked(["ditto", "-x", "-k", str(app_archive_path), str(app_extract)], "app extraction")
    app_bundle = app_extract / bundle_name
    if not app_bundle.is_dir() or app_bundle.is_symlink():
        fail(f"app archive did not extract exactly one {bundle_name}")
    try:
        with (app_bundle / "Contents" / "Info.plist").open("rb") as stream:
            app_plist = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"cannot read archived app Info.plist: {error}")
    if app_plist.get("CFBundleShortVersionString") != version:
        fail("archived app version does not match the release tag")

    run_checked(
        ["codesign", "--verify", "--deep", "--strict", str(app_bundle)],
        "app deep signature verification",
    )
    validate_ad_hoc_signature(app_bundle, bundle_name)
    for product in products:
        product_path = app_bundle / PurePosixPath(product["bundlePath"])
        if not product_path.is_file() or product_path.is_symlink() or not os.access(product_path, os.X_OK):
            fail(f"archived product is missing or not executable: {product['name']}")
        try:
            architectures = subprocess.check_output(
                ["xcrun", "lipo", "-archs", str(product_path)],
                stderr=subprocess.STDOUT,
                text=True,
                timeout=30,
            ).strip()
        except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            fail(f"cannot inspect architecture for {product['name']}: {error}")
        if architectures != "arm64":
            fail(f"archived product is not thin arm64: {product['name']}")
        validate_ad_hoc_signature(product_path, product["name"])

    cli_extract = temporary / "cli"
    cli_extract.mkdir()
    with tarfile.open(cli_archive_path, "r:gz") as archive:
        for member in archive.getmembers():
            destination = cli_extract / PurePosixPath(member.name)
            if member.isdir():
                destination.mkdir(parents=True, exist_ok=True)
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            source = archive.extractfile(member)
            if source is None:
                fail(f"cannot extract CLI archive member: {member.name}")
            with source, destination.open("wb") as stream:
                shutil.copyfileobj(source, stream)
            destination.chmod(member.mode & 0o777)
    for product in cli_products:
        app_product = app_bundle / PurePosixPath(product["bundlePath"])
        cli_product = cli_extract / PurePosixPath(product["archivePath"])
        if not cli_product.is_file() or not os.access(cli_product, os.X_OK):
            fail(f"CLI archive product is not executable: {product['name']}")
        if sha256(app_product) != sha256(cli_product):
            fail(f"CLI archive binary differs from the app helper: {product['name']}")
        validate_ad_hoc_signature(cli_product, f"CLI archive {product['name']}")
        run_checked(
            [str(cli_product), "--help"],
            f"CLI archive {product['name']} --help",
        )
    for entry in cli_archive_files:
        archive_path = entry["archivePath"]
        if not archive_path.startswith("completions/"):
            continue
        cli_completion = cli_extract / PurePosixPath(archive_path)
        app_completion = app_bundle / "Contents" / "Resources" / PurePosixPath(
            archive_path
        )
        if not app_completion.is_file() or app_completion.is_symlink():
            fail(f"app archive is missing shell completion: {archive_path}")
        if sha256(app_completion) != sha256(cli_completion):
            fail(f"app and CLI shell completions differ: {archive_path}")

print(f"Verified complete published assets for {tag}")
