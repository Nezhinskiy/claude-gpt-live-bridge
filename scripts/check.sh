#!/bin/sh
# Every check CI runs. Later changes append their own checks below.
set -eu
cd "$(dirname "$0")/.."

swift format lint --strict -r app
(cd app && swift build && swift test)
