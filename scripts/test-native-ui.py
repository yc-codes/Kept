#!/usr/bin/env python3
"""Render Kept's native windows in a fresh library and check for expected controls."""
import argparse
import json
import os
import subprocess
import tempfile
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run_matrix(app, work, jobs):
    # The text recognizer compiles while the first windows are coming up.
    recognizer = work / "snapshot-text"
    compiler = subprocess.Popen(
        ["xcrun", "swiftc", str(ROOT / "Tests/Fixtures/snapshot_text.swift"), "-o", str(recognizer)])
    sample = str(ROOT / "website/assets/kept-icon.png")
    settings = {"KEPT_SNAPSHOT_SHOW": "settings"}
    cases = [
        ("capture", settings | {"KEPT_SNAPSHOT_TAB": "capture"}, ["Copied images", "Copied links", "Copied text",
          "Pause clipboard capture", "Excluded apps", "Add App", "Remove", "Library location", "Show in Finder", "Show Welcome"]),
        ("connectors", settings | {"KEPT_SNAPSHOT_TAB": "connectors"}, ["No connectors yet", "Add Connector", "Sync All Now"]),
        ("appearance-light", settings | {"KEPT_SNAPSHOT_TAB": "appearance"}, ["System", "Light", "Dark"]),
        ("appearance-dark", settings | {"KEPT_SNAPSHOT_TAB": "appearance"}, ["System", "Light", "Dark"]),
        ("shortcuts", settings | {"KEPT_SNAPSHOT_TAB": "shortcuts"}, ["Global shortcuts", "Take a snip", "Quick search"]),
        ("agents", settings | {"KEPT_SNAPSHOT_TAB": "agents"},
         ["Kept fix last 4", "Claude Code", "Codex", "Cursor", "Claude Desktop", "Any other MCP client", "kept-mcp"]),
        ("github", settings | {"KEPT_SNAPSHOT_TAB": "connectors", "KEPT_SNAPSHOT_SHEET": "github-stars"},
         ["Connect GitHub Stars", "Cancel"]),
        ("raindrop", settings | {"KEPT_SNAPSHOT_TAB": "connectors", "KEPT_SNAPSHOT_SHEET": "raindrop"},
         ["Connect Raindrop.io", "Cancel"]),
        ("feed", settings | {"KEPT_SNAPSHOT_TAB": "connectors", "KEPT_SNAPSHOT_SHEET": "feed"},
         ["RSS or Atom Feed", "Feed address", "Cancel"]),
        ("welcome-intro", {"KEPT_SNAPSHOT_SHOW": "welcome", "KEPT_SNAPSHOT_STEP": "0"}, ["Welcome to Kept", "Continue"]),
        ("welcome-capture", {"KEPT_SNAPSHOT_SHOW": "welcome", "KEPT_SNAPSHOT_STEP": "1"}, ["Choose what Kept saves", "Back"]),
        ("welcome-shortcuts", {"KEPT_SNAPSHOT_SHOW": "welcome", "KEPT_SNAPSHOT_STEP": "2"}, ["Pick your shortcuts", "Back"]),
        ("welcome-practice", {"KEPT_SNAPSHOT_SHOW": "welcome", "KEPT_SNAPSHOT_STEP": "3"}, ["Take a practice snip", "Skip for Now"]),
        ("library-empty", {}, ["Keep your first capture", "All Items"]),
        ("library-grid", {"KEPT_SNAPSHOT_IMPORT": sample}, ["All Items", "kept-icon"]),
        ("library-list", {"KEPT_SNAPSHOT_IMPORT": sample}, ["All Items", "Name", "Source", "Captured", "kept-icon"]),
        # The window is rarely the active one, and an inactive window dims its Copy button past reading.
        ("inspector", {"KEPT_SNAPSHOT_SHOW": "select", "KEPT_SNAPSHOT_IMPORT": sample},
         ["kept-icon", "Why did you save this", "Open", "Details"]),
        ("quick-search", {"KEPT_SNAPSHOT_SHOW": "quick"}, ["Search Kept", "Nothing kept yet", "Close"]),
        ("quick-search-populated", {"KEPT_SNAPSHOT_SHOW": "quick", "KEPT_SNAPSHOT_IMPORT": sample},
         ["Search Kept", "kept-icon", "Show in Library"]),
    ]

    # Every case gets its own library and preferences, so the windows can render side by side. Each one
    # spends most of its time waiting for its window to settle, not using a processor.
    def run_case(case):
        name, features, labels = case
        suite = "app.kept.ui-tests." + str(uuid.uuid4())
        destination = work / name
        destination.mkdir()
        env = {key: value for key, value in os.environ.items() if not key.startswith("KEPT_")}
        env.update(KEPT_HOME=str(destination / "library"), KEPT_DEFAULTS_SUITE=suite,
                   KEPT_SNAPSHOT_DIR=str(destination))
        env.update(features)
        try:
            subprocess.run(["defaults", "write", suite, "didOnboard", "-bool", "true"], check=True)
            if name.startswith("appearance-"):
                subprocess.run(["defaults", "write", suite, "theme", "-string", name.split("-")[1]], check=True)
            if name == "library-list":
                subprocess.run(["defaults", "write", suite, "libraryViewMode", "-string", "list"], check=True)
            if name == "inspector":
                subprocess.run(["defaults", "write", suite, "libraryShowInspector", "-bool", "true"], check=True)

            log = destination / "app.log"
            with log.open("wb") as output:
                subprocess.run([str(app)], env=env, stdout=output, stderr=output, timeout=25, check=True)
            images = list(destination.glob("*.png"))
            if not images:
                raise AssertionError(f"No windows captured. {log.read_text()}")
            if compiler.wait():
                raise AssertionError("The text recognizer did not compile.")
            text = json.loads(subprocess.check_output([str(recognizer), *map(str, images)], text=True, timeout=35))
            # A single captured window must contain all the expected labels.
            if not any(all(label.casefold() in screen.casefold() for label in labels) for screen in text.values()):
                raise AssertionError(f"Expected {labels}. Captured text: {list(text.values())}")
            return None
        except (AssertionError, subprocess.SubprocessError) as error:
            return error
        finally:
            subprocess.run(["defaults", "delete", suite], capture_output=True)

    failures = 0
    with ThreadPoolExecutor(max_workers=jobs) as pool:
        for (name, _, _), error in zip(cases, pool.map(run_case, cases)):
            failures += error is not None
            print(f"FAIL {name} — {error}" if error else f"PASS {name}", flush=True)
    print(f"{len(cases)} native window checks, {failures} failures")
    return bool(failures)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", nargs="?", type=Path, default=ROOT / "build/Kept.app")
    parser.add_argument("--jobs", type=int, default=2 * (os.cpu_count() or 4),
                        help="windows to render at once (default: twice the processor count)")
    args = parser.parse_args()
    executable = args.app.resolve() / "Contents/MacOS/Kept"
    if not executable.is_file():
        parser.error("Build Kept.app with scripts/build-app.sh first")
    with tempfile.TemporaryDirectory(prefix="kept-native-ui-") as directory:
        raise SystemExit(run_matrix(executable, Path(directory), max(1, args.jobs)))
