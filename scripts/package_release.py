#!/usr/bin/env python3
import gzip
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


root = Path(sys.argv[1]).resolve()
config_path = Path(sys.argv[2]).resolve()
package_path = Path(sys.argv[3]).resolve()
mode = sys.argv[4]
tag = sys.argv[5]
temporary = Path(sys.argv[6]).resolve()


def fail(message: str) -> None:
    raise SystemExit(f"package-release: {message}")


def load_json(path: Path, description: str):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot read {description} {path}: {error}")


def require_keys(value: dict, expected: set[str], description: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        fail(f"{description} has unexpected fields (missing={missing}, extra={extra})")


def safe_archive_path(value, description: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{description} must be a non-empty string")
    path = PurePosixPath(value)
    if (
        path.is_absolute()
        or str(path) != value
        or any(part in ("", ".", "..") for part in path.parts)
    ):
        fail(f"{description} must be a normalized relative path: {value!r}")
    return value


def safe_filename(value, suffix: str, description: str) -> str:
    value = safe_archive_path(value, description)
    if PurePosixPath(value).name != value or not value.endswith(suffix):
        fail(f"{description} must be a basename ending in {suffix}: {value!r}")
    return value


config = load_json(config_path, "release inventory")
if not isinstance(config, dict):
    fail("release inventory must be a JSON object")
require_keys(
    config,
    {
        "schemaVersion",
        "bundleName",
        "appArchive",
        "cliArchive",
        "homebrewCask",
        "macOSDistribution",
        "products",
        "cliArchiveFiles",
    },
    "release inventory",
)
if config["schemaVersion"] != 1:
    fail(f"unsupported release inventory schemaVersion: {config['schemaVersion']!r}")

bundle_name = safe_filename(config["bundleName"], ".app", "bundleName")
app_archive = safe_filename(config["appArchive"], ".zip", "appArchive")
cli_archive = safe_filename(config["cliArchive"], ".tar.gz", "cliArchive")
homebrew_cask = safe_filename(config["homebrewCask"], ".rb", "homebrewCask")
reserved_assets = {"release-manifest.json", "SHA256SUMS"}
if len({app_archive, cli_archive, homebrew_cask} | reserved_assets) != 5:
    fail("release asset names must be distinct and must not use reserved names")
distribution = config["macOSDistribution"]
if distribution != {
    "signature": "ad-hoc",
    "hardenedRuntime": True,
    "notarized": False,
}:
    fail("macOSDistribution must require ad-hoc signing, hardened runtime, and no notarization")

products = config["products"]
if not isinstance(products, list) or not products:
    fail("products must be a non-empty array")
declared_names: set[str] = set()
bundle_paths: set[str] = set()
cli_paths: set[str] = set()
normalized_products = []
for index, product in enumerate(products):
    description = f"products[{index}]"
    if not isinstance(product, dict):
        fail(f"{description} must be an object")
    classification = product.get("classification")
    expected = {"name", "classification", "bundlePath"}
    if classification == "cli":
        expected.add("archivePath")
    require_keys(product, expected, description)
    name = product["name"]
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]*", name):
        fail(f"{description}.name is invalid: {name!r}")
    if name in declared_names:
        fail(f"duplicate product: {name}")
    declared_names.add(name)
    if classification not in ("app", "cli"):
        fail(f"{name} must be classified as app or cli")
    bundle_path = safe_archive_path(product["bundlePath"], f"{name}.bundlePath")
    if not bundle_path.startswith("Contents/"):
        fail(f"{name}.bundlePath must be inside the app Contents directory")
    if bundle_path in bundle_paths:
        fail(f"duplicate bundlePath: {bundle_path}")
    bundle_paths.add(bundle_path)
    archive_path = None
    if classification == "cli":
        archive_path = safe_archive_path(product["archivePath"], f"{name}.archivePath")
        if archive_path in cli_paths:
            fail(f"duplicate CLI archive path: {archive_path}")
        cli_paths.add(archive_path)
    normalized_products.append(
        {
            "name": name,
            "classification": classification,
            "bundlePath": bundle_path,
            "archivePath": archive_path,
        }
    )

package = load_json(package_path, "SwiftPM package description")
try:
    swift_products = package["products"]
except (KeyError, TypeError):
    fail("SwiftPM package description does not contain products")
executable_names = {
    product["name"]
    for product in swift_products
    if isinstance(product, dict)
    and isinstance(product.get("type"), dict)
    and "executable" in product["type"]
}
missing = sorted(executable_names - declared_names)
stale = sorted(declared_names - executable_names)
if missing or stale:
    fail(
        "every SwiftPM executable product must be classified exactly once "
        f"(unclassified={missing}, notExecutableOrMissing={stale})"
    )
if not any(product["classification"] == "app" for product in normalized_products):
    fail("at least one executable product must be classified as app")
if not any(product["classification"] == "cli" for product in normalized_products):
    fail("at least one executable product must be classified as cli")

extra_files = config["cliArchiveFiles"]
if not isinstance(extra_files, list):
    fail("cliArchiveFiles must be an array")
normalized_files = []
for index, entry in enumerate(extra_files):
    description = f"cliArchiveFiles[{index}]"
    if not isinstance(entry, dict):
        fail(f"{description} must be an object")
    require_keys(entry, {"source", "archivePath"}, description)
    source_value = safe_archive_path(entry["source"], f"{description}.source")
    archive_path = safe_archive_path(entry["archivePath"], f"{description}.archivePath")
    if archive_path in cli_paths:
        fail(f"duplicate CLI archive path: {archive_path}")
    cli_paths.add(archive_path)
    source_candidate = root / source_value
    if source_candidate.is_symlink():
        fail(f"{description}.source must not be a symlink: {source_value}")
    source = source_candidate.resolve()
    try:
        source.relative_to(root)
    except ValueError:
        fail(f"{description}.source escapes the repository: {source_value}")
    if not source.is_file():
        fail(f"{description}.source is not a regular repository file: {source_value}")
    normalized_files.append(
        {"source": source_value, "archivePath": archive_path, "path": source}
    )

plist_source = root / "Resources" / "Dopa-Info.plist"
try:
    with plist_source.open("rb") as stream:
        source_plist = plistlib.load(stream)
except (OSError, plistlib.InvalidFileException) as error:
    fail(f"cannot read {plist_source}: {error}")
source_version = source_plist.get("CFBundleShortVersionString")
if not isinstance(source_version, str) or not source_version:
    fail("Dopa-Info.plist must define CFBundleShortVersionString")

print(
    "Validated release inventory: "
    + ", ".join(
        f"{product['name']} ({product['classification']})"
        for product in normalized_products
    )
)
if mode == "check":
    raise SystemExit(0)

if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
    fail(f"release tag must have the form vX.Y.Z: {tag!r}")
version = tag[1:]
if source_version != version:
    fail(
        "release tag does not match Resources/Dopa-Info.plist "
        f"({version!r} != {source_version!r})"
    )

app_bundle = root / ".build" / bundle_name
if not app_bundle.is_dir() or app_bundle.is_symlink():
    fail(f"missing built app bundle: {app_bundle}")
bundle_plist_path = app_bundle / "Contents" / "Info.plist"
try:
    with bundle_plist_path.open("rb") as stream:
        bundle_plist = plistlib.load(stream)
except (OSError, plistlib.InvalidFileException) as error:
    fail(f"cannot read built app Info.plist: {error}")
if bundle_plist.get("CFBundleShortVersionString") != version:
    fail("built app version does not match the release tag")


def run_checked(arguments: list[str], description: str) -> None:
    try:
        subprocess.run(
            arguments,
            check=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=30,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        detail = ""
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            detail = ": " + error.stderr.decode("utf-8", errors="replace").strip()
        fail(f"{description} failed{detail}")


def validate_ad_hoc_signature(path: Path, name: str) -> None:
    run_checked(["codesign", "--verify", "--strict", str(path)], f"codesign verification for {name}")
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


def validate_binary(path: Path, name: str, run_help: bool) -> None:
    if not path.is_file() or path.is_symlink() or not os.access(path, os.X_OK):
        fail(f"missing executable for {name}: {path}")
    try:
        architectures = subprocess.check_output(
            ["xcrun", "lipo", "-archs", str(path)],
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30,
        ).strip()
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        fail(f"cannot inspect architecture for {name}: {error}")
    if architectures != "arm64":
        fail(f"{name} must be a thin arm64 Mach-O, found: {architectures!r}")
    validate_ad_hoc_signature(path, name)
    if run_help:
        run_checked([str(path), "--help"], f"{name} --help")


run_checked(
    ["codesign", "--verify", "--deep", "--strict", str(app_bundle)],
    "app codesign verification",
)
validate_ad_hoc_signature(app_bundle, bundle_name)
product_sources: dict[str, Path] = {}
for product in normalized_products:
    source = app_bundle / PurePosixPath(product["bundlePath"])
    validate_binary(source, product["name"], product["classification"] == "cli")
    product_sources[product["name"]] = source

dist = root / "dist"
if dist.resolve().parent != root:
    fail(f"refusing unsafe dist path: {dist}")
if dist.exists():
    if dist.is_symlink() or not dist.is_dir():
        fail(f"refusing to replace non-directory dist path: {dist}")
    shutil.rmtree(dist)
dist.mkdir(mode=0o755)


app_archive_path = dist / app_archive
run_checked(
    [
        "ditto",
        "-c",
        "-k",
        "--sequesterRsrc",
        "--keepParent",
        str(app_bundle),
        str(app_archive_path),
    ],
    "app archive creation",
)


def tar_info_for_file(source: Path, archive_path: str) -> tarfile.TarInfo:
    info = tarfile.TarInfo(archive_path)
    source_stat = source.stat()
    info.size = source_stat.st_size
    info.mode = source_stat.st_mode & 0o777
    info.uid = 0
    info.gid = 0
    info.uname = "root"
    info.gname = "wheel"
    info.mtime = 0
    info.type = tarfile.REGTYPE
    return info


cli_entries: dict[str, Path] = {}
for product in normalized_products:
    if product["classification"] == "cli":
        cli_entries[product["archivePath"]] = product_sources[product["name"]]
for entry in normalized_files:
    cli_entries[entry["archivePath"]] = entry["path"]

cli_archive_path = dist / cli_archive
with cli_archive_path.open("wb") as raw_stream:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw_stream, compresslevel=9, mtime=0) as gzip_stream:
        with tarfile.open(fileobj=gzip_stream, mode="w", format=tarfile.PAX_FORMAT) as archive:
            directories = {
                str(parent)
                for archive_path in cli_entries
                for parent in PurePosixPath(archive_path).parents
                if str(parent) != "."
            }
            for directory in sorted(directories):
                info = tarfile.TarInfo(directory)
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                info.uid = 0
                info.gid = 0
                info.uname = "root"
                info.gname = "wheel"
                info.mtime = 0
                archive.addfile(info)
            for archive_path, source in sorted(cli_entries.items()):
                info = tar_info_for_file(source, archive_path)
                with source.open("rb") as stream:
                    archive.addfile(info, stream)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


for entry in normalized_files:
    if not entry["archivePath"].startswith("completions/"):
        continue
    app_completion = app_bundle / "Contents" / "Resources" / PurePosixPath(
        entry["archivePath"]
    )
    if not app_completion.is_file() or app_completion.is_symlink():
        fail(f"app bundle is missing shell completion: {entry['archivePath']}")
    if sha256(app_completion) != sha256(entry["path"]):
        fail(f"app shell completion differs from its source: {entry['archivePath']}")


app_archive_sha256 = sha256(app_archive_path)
homebrew_cask_path = dist / homebrew_cask
run_checked(
    [
        str(root / "scripts" / "render-homebrew-cask.sh"),
        version,
        app_archive_sha256,
        str(homebrew_cask_path),
    ],
    "Homebrew Cask creation",
)
run_checked(["ruby", "-c", str(homebrew_cask_path)], "Homebrew Cask syntax validation")


manifest = {
    "schemaVersion": 1,
    "version": version,
    "tag": tag,
    "target": {"os": "macOS", "architecture": "arm64"},
    "distribution": distribution,
    "assets": [
        {
            "name": app_archive,
            "sha256": app_archive_sha256,
            "kind": "app",
            "bundle": bundle_name,
            "products": [
                {
                    "name": product["name"],
                    "path": f"{bundle_name}/{product['bundlePath']}",
                }
                for product in normalized_products
            ],
        },
        {
            "name": cli_archive,
            "sha256": sha256(cli_archive_path),
            "kind": "cli",
            "files": sorted(cli_entries),
            "products": [
                {
                    "name": product["name"],
                    "path": product["archivePath"],
                }
                for product in normalized_products
                if product["classification"] == "cli"
            ],
        },
        {
            "name": homebrew_cask,
            "sha256": sha256(homebrew_cask_path),
            "kind": "homebrew-cask",
            "token": "dopa",
            "appArchive": app_archive,
        },
    ],
}
manifest_path = dist / "release-manifest.json"
manifest_path.write_text(
    json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)

checksummed = [app_archive_path, cli_archive_path, homebrew_cask_path, manifest_path]
checksums_path = dist / "SHA256SUMS"
checksums_path.write_text(
    "".join(
        f"{sha256(path)}  {path.name}\n"
        for path in sorted(checksummed, key=lambda item: item.name)
    ),
    encoding="utf-8",
)

# Inspect the archives rather than trusting only the source paths. `ditto` is
# also the extraction path used for macOS application zips in common tooling.
zip_extract = temporary / "zip-extract"
zip_extract.mkdir()
run_checked(["ditto", "-x", "-k", str(app_archive_path), str(zip_extract)], "app archive extraction")
extracted_app = zip_extract / bundle_name
run_checked(
    ["codesign", "--verify", "--deep", "--strict", str(extracted_app)],
    "archived app codesign verification",
)
validate_ad_hoc_signature(extracted_app, f"archived {bundle_name}")
for product in normalized_products:
    extracted = extracted_app / PurePosixPath(product["bundlePath"])
    validate_binary(extracted, f"archived {product['name']}", False)

tar_extract = temporary / "tar-extract"
tar_extract.mkdir()
run_checked(["tar", "-xzf", str(cli_archive_path), "-C", str(tar_extract)], "CLI archive extraction")
for archive_path, original in cli_entries.items():
    extracted = tar_extract / PurePosixPath(archive_path)
    if not extracted.is_file() or sha256(extracted) != sha256(original):
        fail(f"CLI archive content differs from its source: {archive_path}")
for product in normalized_products:
    if product["classification"] != "cli":
        continue
    validate_binary(
        tar_extract / PurePosixPath(product["archivePath"]),
        f"CLI archive {product['name']}",
        True,
    )

expected_assets = {
    app_archive,
    cli_archive,
    homebrew_cask,
    "release-manifest.json",
    "SHA256SUMS",
}
actual_assets = {path.name for path in dist.iterdir() if path.is_file()}
if actual_assets != expected_assets:
    fail(f"unexpected generated asset set: {sorted(actual_assets)}")

print(f"Created release assets for {tag} in {dist}")
for path in sorted(dist.iterdir()):
    print(f"  {path.name}: {path.stat().st_size} bytes")
