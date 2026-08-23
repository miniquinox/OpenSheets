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

echo "==> done"
