#!/bin/bash
# run-latest.sh — build the newest Asterisma project from the current working
# tree, then launch the exact app bundle that was just built.
#
# Why this exists: the old workflow was "open Xcode and press Run", while the
# command-line build/test command kept changing between sessions. This is the
# one stable command. It picks the newest AsterismaV*.xcodeproj, builds the
# current tree, quits an old instance gracefully, and opens the new bundle.
#
# Usage:
#   ./scripts/run-latest.sh
#   ./scripts/run-latest.sh --build-only
#
# The build deliberately uses Xcode's default DerivedData. On a Desktop or
# iCloud-synced checkout, a custom -derivedDataPath breaks code signing
# (BUG-003: the FileProvider stamp). The app bundle is located from
# `xcodebuild -showBuildSettings`, so this remains correct if Xcode changes
# its DerivedData hash.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_ONLY=0

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
        --build-only)
            BUILD_ONLY=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option: $arg" >&2
            echo "usage: $0 [--build-only]" >&2
            exit 2
            ;;
    esac
done

PROJECT_PATH="${ASTERISMA_PROJECT:-}"
if [[ -z "$PROJECT_PATH" ]]; then
    PROJECT_PATH="$(
        find "$ROOT" -maxdepth 1 -name 'AsterismaV*.xcodeproj' -print \
            | sort -V \
            | tail -n 1
    )"
fi
if [[ -z "$PROJECT_PATH" || ! -d "$PROJECT_PATH" ]]; then
    echo "error: no AsterismaV*.xcodeproj found in $ROOT" >&2
    exit 1
fi
PROJECT_PATH="$(cd "$(dirname "$PROJECT_PATH")" && pwd)/$(basename "$PROJECT_PATH")"
PROJECT_NAME="$(basename "$PROJECT_PATH" .xcodeproj)"
SCHEME="${ASTERISMA_SCHEME:-$PROJECT_NAME}"
CONFIGURATION="${ASTERISMA_CONFIGURATION:-Debug}"

LOG_DIR="$HOME/Library/Logs/$PROJECT_NAME"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/run-latest.log"

echo "Asterisma runner"
echo "  project:       $PROJECT_PATH"
echo "  scheme:        $SCHEME"
echo "  configuration: $CONFIGURATION"
echo "  build log:     $LOG"

# Resolve the product path from Xcode itself. This is what keeps the launched
# app tied to the build we just made instead of a stale copy elsewhere.
if ! SETTINGS="$(
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination 'platform=macOS' \
        -showBuildSettings 2>&1
)"; then
    printf '%s\n' "$SETTINGS" >&2
    echo "error: could not read build settings" >&2
    exit 1
fi

BUILT_PRODUCTS_DIR="$(
    printf '%s\n' "$SETTINGS" \
        | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR = /{print $2; exit}'
)"
FULL_PRODUCT_NAME="$(
    printf '%s\n' "$SETTINGS" \
        | awk -F' = ' '/^ *FULL_PRODUCT_NAME = /{print $2; exit}'
)"
BUNDLE_ID="$(
    printf '%s\n' "$SETTINGS" \
        | awk -F' = ' '/^ *PRODUCT_BUNDLE_IDENTIFIER = /{print $2; exit}'
)"

if [[ -z "$BUILT_PRODUCTS_DIR" || -z "$FULL_PRODUCT_NAME" ]]; then
    echo "error: Xcode did not report a product path" >&2
    exit 1
fi

echo "Building the current working tree…"
if ! xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    build >"$LOG" 2>&1; then
    echo "error: build failed — last 80 log lines:" >&2
    tail -80 "$LOG" >&2
    exit 1
fi

APP_PATH="$BUILT_PRODUCTS_DIR/$FULL_PRODUCT_NAME"
if [[ ! -d "$APP_PATH" ]]; then
    echo "error: build succeeded but the app bundle is missing:" >&2
    echo "  $APP_PATH" >&2
    exit 1
fi

echo "Built: $APP_PATH"

if [[ "$BUILD_ONLY" -eq 1 ]]; then
    echo "Build-only requested; not launching."
    exit 0
fi

EXECUTABLE_NAME="$(
    /usr/libexec/PlistBuddy \
        -c 'Print :CFBundleExecutable' \
        "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
)"
if [[ -z "$EXECUTABLE_NAME" ]]; then
    EXECUTABLE_NAME="${FULL_PRODUCT_NAME%.app}"
fi
if [[ -z "$BUNDLE_ID" ]]; then
    BUNDLE_ID="$(
        /usr/libexec/PlistBuddy \
            -c 'Print :CFBundleIdentifier' \
            "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
    )"
fi

is_any_running() {
    local name
    for name in "$EXECUTABLE_NAME" "AsterismaV2.5" "AsterismaV1.0"; do
        if pgrep -x "$name" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

if is_any_running; then
    echo "Quitting the running instance…"
    if [[ -n "$BUNDLE_ID" ]]; then
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" \
            >/dev/null 2>&1 || true
    fi
    for _ in {1..24}; do
        if ! is_any_running; then
            break
        fi
        sleep 0.25
    done
    if is_any_running; then
        echo "error: the old instance did not quit." >&2
        echo "Quit Asterisma manually and run this command again; the runner" >&2
        echo "will not force-kill the app because that can lose reading data." >&2
        exit 1
    fi
fi

if ! open "$APP_PATH"; then
    echo "error: macOS refused to open the built app" >&2
    exit 1
fi

for _ in {1..40}; do
    if is_any_running; then
        # Give LaunchServices a moment; a bundle that dies during startup
        # must fail this command, not report a false launch success.
        sleep 1
        if is_any_running; then
            PID="$(pgrep -x "$EXECUTABLE_NAME" | head -n 1)"
            echo "Running: $APP_PATH${PID:+ (pid $PID)}"
            exit 0
        fi
        break
    fi
    sleep 0.25
done

echo "error: the app was opened but no running process appeared." >&2
echo "Check $LOG and Console.app for the launch failure." >&2
exit 1
