#!/bin/bash
# Run with an installed Chrome via KEPT_TEST_CHROME, or install Playwright's Chromium first.
set -euo pipefail
cd "$(dirname "$0")/.."
playwright="$(npm exec --yes --package=playwright -- which playwright)"
NODE_PATH="$(dirname "$(dirname "$playwright")")${NODE_PATH:+:$NODE_PATH}" node --test Tests/Website/smoke.cjs
