#!/usr/bin/env bash
# Build everything: the SwiftPM package and the app.
#
# `--package-only` skips xcodebuild, which is what CI wants for the fast lane.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
PACKAGE_ONLY=false
CONFIGURATION="debug"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--package-only) PACKAGE_ONLY=true ;;
		--release) CONFIGURATION="release" ;;
		-h|--help)
			echo "usage: Scripts/build.sh [--package-only] [--release]"
			exit 0
			;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done

echo "==> swift build ($CONFIGURATION)"
cd "$ROOT/Packages/OpenSheetsCore"
# Warnings are errors here rather than in Package.swift: `unsafeFlags` in a manifest makes the
# package unusable as a dependency, and OpenSheets.xcodeproj depends on it by path.
swift build -c "$CONFIGURATION" -Xswiftc -warnings-as-errors

if [[ "$PACKAGE_ONLY" == true ]]; then
	echo "==> done (package only)"
	exit 0
fi

if [[ ! -d "$ROOT/OpenSheets.xcodeproj" ]]; then
	echo "==> no OpenSheets.xcodeproj, skipping the app build"
	exit 0
fi

echo "==> xcodebuild"
cd "$ROOT"
XCODE_CONFIGURATION=$([[ "$CONFIGURATION" == "release" ]] && echo Release || echo Debug)
xcodebuild build \
	-project OpenSheets.xcodeproj \
	-scheme OpenSheets \
	-configuration "$XCODE_CONFIGURATION" \
	-destination 'platform=macOS' \
	CODE_SIGNING_ALLOWED=NO \
	| xcbeautify 2>/dev/null || xcodebuild build \
		-project OpenSheets.xcodeproj \
		-scheme OpenSheets \
		-configuration "$XCODE_CONFIGURATION" \
		-destination 'platform=macOS' \
		CODE_SIGNING_ALLOWED=NO

# Embed the MCP server in the app bundle, so Settings ▸ Claude has a binary to register. The
# xcodeproj has no copy phase and may not gain one (house rule: the project file is never
# edited), so this is the sanctioned bundling point. Failures are loud on purpose: a silent
# skip would ship a Connect button that can never enable.
echo "==> embed opensheets-mcp"
MCP_BINARY="$ROOT/Packages/OpenSheetsCore/.build/$CONFIGURATION/opensheets-mcp"
if [[ ! -x "$MCP_BINARY" ]]; then
	echo "error: $MCP_BINARY is missing or not executable — the swift build above should have produced it" >&2
	exit 1
fi
APP_SETTINGS=$(xcodebuild -project OpenSheets.xcodeproj -scheme OpenSheets \
	-configuration "$XCODE_CONFIGURATION" -destination 'platform=macOS' \
	-showBuildSettings 2>/dev/null)
TARGET_BUILD_DIR=$(echo "$APP_SETTINGS" | awk -F' = ' '/ TARGET_BUILD_DIR =/{print $2; exit}')
FULL_PRODUCT_NAME=$(echo "$APP_SETTINGS" | awk -F' = ' '/ FULL_PRODUCT_NAME =/{print $2; exit}')
APP_BUNDLE="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
if [[ ! -d "$APP_BUNDLE/Contents/MacOS" ]]; then
	echo "error: built app not found at $APP_BUNDLE — xcodebuild reported a product that is not there" >&2
	exit 1
fi
cp "$MCP_BINARY" "$APP_BUNDLE/Contents/MacOS/"
echo "    embedded $APP_BUNDLE/Contents/MacOS/opensheets-mcp"

echo "==> done"
