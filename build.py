# -*- coding: utf-8 -*-
"""Build BJORN Manager into a standalone binary using PyInstaller.

Usage:
    python build.py
"""

import os
import argparse
import subprocess
import sys

# Project metadata
CREATOR = "Infinition"
APP_NAME = "BJORN Manager"
ENTRY_POINT = os.path.join("bjorn_manager", "__main__.py")
WIN_ICON_PATH = os.path.join("assets", "bjorn.ico")
LINUX_ICON_PATH = os.path.join("assets", "bjorn.png")

# Paths to bundle as data files
DATA_FILES = [
    ("bjorn_ui.html", "."),
    (os.path.join("assets", "bjorn.ico"), "assets"),
    (os.path.join("assets", "icon.ico"), "assets"),
    (os.path.join("assets", "bjorn.png"), "assets"),
    (os.path.join("assets", "webapp.json"), "assets"),
    (os.path.join("assets", "install_bjorn.sh"), "assets"),
    (os.path.join("assets", "lib"), os.path.join("assets", "lib")),
]

HIDDEN_IMPORTS = [
    "bjorn_manager",
    "bjorn_manager.app",
    "bjorn_manager.ui",
    "bjorn_manager.ui.js_bridge",
    "bjorn_manager.ssh",
    "bjorn_manager.ssh.worker",
    "bjorn_manager.ssh.config",
    "bjorn_manager.discovery",
    "bjorn_manager.discovery.manager",
    "bjorn_manager.discovery.device",
    "bjorn_manager.installer",
    "bjorn_manager.installer.script_generator",
    "bjorn_manager.installer.validator",
    "paramiko",
    "zeroconf",
    "netifaces",
    "psutil",
    "ifaddr",
    "certifi",
]

EXCLUDED_BUILD_PATHS = {
    "wiki",
    ".nojekyll",
    "acidwiki.json",
    "index.html",
    "robots.txt",
    "sw.js",
    "security.txt",
}


def ask_version() -> str:
    """Prompt the user for a version string."""
    while True:
        version = input("Enter version number (e.g. 1.0.0): ").strip()
        if version:
            return version
        print("Version cannot be empty.")


def normalize_version(version: str) -> str:
    """Normalize version strings like 'v1.2.3' -> '1.2.3'."""
    return version.strip().removeprefix("v")


def get_platform_tag() -> str:
    """Return a short platform tag for artifact naming."""
    if sys.platform == "win32":
        return "windows"
    if sys.platform.startswith("linux"):
        return "linux"
    if sys.platform == "darwin":
        return "macos"
    return sys.platform


def get_executable_extension() -> str:
    """Return platform-specific executable extension."""
    return ".exe" if sys.platform == "win32" else ""


def get_icon_arg() -> list[str]:
    """Return icon argument when a suitable icon exists."""
    if sys.platform == "win32":
        if os.path.isfile(WIN_ICON_PATH):
            return [f"--icon={WIN_ICON_PATH}"]
        print(f"[WARNING] Windows icon not found: {WIN_ICON_PATH} - building without icon")
        return []

    if sys.platform.startswith("linux"):
        if os.path.isfile(LINUX_ICON_PATH):
            return [f"--icon={LINUX_ICON_PATH}"]
        print(f"[WARNING] Linux icon not found: {LINUX_ICON_PATH} - building without icon")
        return []

    return []


def build(version: str) -> None:
    """Run PyInstaller with the configured options."""
    project_dir = os.path.dirname(os.path.abspath(__file__))
    os.chdir(project_dir)

    if not os.path.isfile(ENTRY_POINT):
        print(f"[ERROR] Entry point not found: {ENTRY_POINT}")
        sys.exit(1)

    icon_arg = get_icon_arg()

    sep = ";" if sys.platform == "win32" else ":"
    add_data_args = []
    for src, dst in DATA_FILES:
        normalized = src.replace("\\", "/").lstrip("./")
        root_name = normalized.split("/", 1)[0]
        if normalized in EXCLUDED_BUILD_PATHS or root_name in EXCLUDED_BUILD_PATHS:
            print(f"[INFO] Excluded from build by policy: {src}")
            continue
        if os.path.exists(src):
            add_data_args.extend(["--add-data", f"{src}{sep}{dst}"])
        else:
            print(f"[WARNING] Data file not found, skipping: {src}")

    hidden_args = []
    for mod in HIDDEN_IMPORTS:
        hidden_args.extend(["--hidden-import", mod])

    platform_tag = get_platform_tag()
    exe_name = f"BJORN_Manager_v{version}_{platform_tag}"
    exe_ext = get_executable_extension()

    cmd = [
        sys.executable,
        "-m",
        "PyInstaller",
        "--onefile",
        "--windowed",
        "--clean",
        "--noconfirm",
        f"--name={exe_name}",
        *icon_arg,
        *add_data_args,
        *hidden_args,
        ENTRY_POINT,
    ]

    print(f"\n{'=' * 60}")
    print(f"  {APP_NAME} - Build")
    print(f"  Creator : {CREATOR}")
    print(f"  Version : {version}")
    print(f"  Platform: {platform_tag}")
    print(f"  Output  : dist/{exe_name}{exe_ext}")
    print(f"{'=' * 60}\n")

    result = subprocess.run(cmd)

    if result.returncode == 0:
        exe_path = os.path.join("dist", f"{exe_name}{exe_ext}")
        size_mb = os.path.getsize(exe_path) / (1024 * 1024) if os.path.isfile(exe_path) else 0
        print(f"\n{'=' * 60}")
        print("  BUILD SUCCESSFUL")
        print(f"  Output : {exe_path}")
        print(f"  Size   : {size_mb:.1f} MB")
        print(f"  Creator: {CREATOR}")
        print(f"{'=' * 60}\n")
    else:
        print(f"\n[ERROR] PyInstaller exited with code {result.returncode}")
        sys.exit(result.returncode)


def main() -> None:
    parser = argparse.ArgumentParser(description="Build BJORN Manager with PyInstaller.")
    parser.add_argument(
        "--version",
        help="Version number, e.g. 1.2.3 or v1.2.3. If omitted, interactive prompt is used.",
    )
    args = parser.parse_args()

    print(f"\n{'=' * 60}")
    print(f"  {APP_NAME} - PyInstaller Build Script")
    print(f"  Creator: {CREATOR}")
    print(f"  Host OS: {get_platform_tag()}")
    print(f"{'=' * 60}\n")

    if sys.platform == "win32":
        print("[INFO] This build will generate a Windows .exe")
    elif sys.platform.startswith("linux"):
        print("[INFO] This build will generate a Linux executable")
    else:
        print("[INFO] This build will generate an executable for the current host OS")
    print("[INFO] PyInstaller does not cross-compile between Windows and Linux.")
    print("[INFO] Build Windows on Windows, Linux on Linux.\n")

    version = normalize_version(args.version) if args.version else ask_version()
    build(version)


if __name__ == "__main__":
    main()
