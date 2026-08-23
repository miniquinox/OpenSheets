#!/usr/bin/env bash
# Run the package test suite.
#
#   Scripts/test.sh                 unit tests, debug
#   Scripts/test.sh --release       the configuration the performance budgets are written for
#   Scripts/test.sh --coverage      with a per-target line-coverage report
#   Scripts/test.sh --sanitize thread|address
#   Scripts/test.sh --filter <pat>
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../Packages/OpenSheetsCore"

CONFIGURATION="debug"
COVERAGE=false
SANITIZER=""
FILTER=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--release) CONFIGURATION="release" ;;
		--coverage) COVERAGE=true ;;
		--sanitize) SANITIZER="${2:?--sanitize needs thread or address}"; shift ;;
		--filter) FILTER="${2:?--filter needs a pattern}"; shift ;;
		-h|--help)
			sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done

ARGS=(test -c "$CONFIGURATION" -Xswiftc -warnings-as-errors)
# `swift test -c release` needs testability turned back on, or @testable imports fail to link.
[[ "$CONFIGURATION" == "release" ]] && ARGS+=(-Xswiftc -enable-testing)
[[ -n "$SANITIZER" ]] && ARGS+=(--sanitize "$SANITIZER")
[[ -n "$FILTER" ]] && ARGS+=(--filter "$FILTER")
$COVERAGE && ARGS+=(--enable-code-coverage)

echo "==> swift ${ARGS[*]}"
swift "${ARGS[@]}"

if $COVERAGE; then
	BINARY=$(swift build -c "$CONFIGURATION" --show-bin-path)/OpenSheetsCorePackageTests.xctest/Contents/MacOS/OpenSheetsCorePackageTests
	PROFILE=$(swift test -c "$CONFIGURATION" --show-codecov-path 2>/dev/null | sed 's|/codecov/.*|/codecov/default.profdata|')
	echo
	echo "==> coverage"
	xcrun llvm-cov report "$BINARY" -instr-profile "$PROFILE" \
		-ignore-filename-regex='(Tests|\.build|checkouts)/' \
		| grep -E 'Sources/|^Filename|^---|^TOTAL'
fi
