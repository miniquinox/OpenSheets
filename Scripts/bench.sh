#!/usr/bin/env bash
#
# bench.sh — run the performance lane, write docs/perf/latest.json, and gate on regression.
#
#   Scripts/bench.sh                    measure, compare against docs/perf/baseline.json
#   Scripts/bench.sh --record-baseline  measure, then write docs/perf/baseline.json
#   Scripts/bench.sh --strict           no widening for a busy machine; a failed benchmark
#                                       assertion also fails the run
#   Scripts/bench.sh --no-compare       measure only
#   Scripts/bench.sh --debug            unoptimised build (numbers are not comparable)
#   Scripts/bench.sh --filter <regex>   which suites to run (default: anything named *Benchmark*)
#   Scripts/bench.sh --tolerance 0.10   regression threshold, as a fraction
#   Scripts/bench.sh --package-dir <p>  benchmark a package other than Packages/OpenSheetsCore
#
#   --record-baseline refuses to run above 0.5x load. If the machine genuinely cannot get quieter,
#   --baseline-on-a-busy-machine records anyway. The load is stamped into the file either way, so
#   the next person can see what they are comparing against; the long flag is there to make that
#   a decision rather than a habit.
#
# HOW IT WORKS
#   The benchmark suites are gated on OPENSHEETS_BENCH=1, so a normal `swift test` never pays for
#   them. This script sets it, runs the suites, and scrapes the one-line JSON records that
#   `TestSupport.Benchmark.record` prints. Those are joined against docs/perf/budgets.json — which
#   lists every budget in PLAN.md §10.6, including the ones nobody can measure yet — and written
#   to docs/perf/latest.json.
#
#   Any test target can contribute: call `Benchmark.record(id:value:unit:)` and the number appears.
#   Name the suite so it matches the filter (anything containing "Benchmark").
#
# WHY IT DOES NOT JUST COMPARE SECONDS
#   Seven agents build on one Mac and CI runs on a shared VM. A raw seconds comparison between two
#   such runs measures the machines, not the code. Two corrections, both recorded in the output:
#
#     1. Every seconds-valued metric is divided by this run's `machine.calibration.seconds` over
#        the baseline's. That is a fixed CPU kernel timed on both machines, so the ratio is how
#        much slower this one is.
#     2. On a machine whose load average exceeds its core count, the tolerance for *timing*
#        metrics is widened and the run is flagged. Counts and byte sizes keep the strict
#        tolerance: they do not care how busy the machine is, which is exactly why they are the
#        metrics worth writing.
#
#   `--strict` turns off the widening. Use it for a deliberate idle run, and for recording a
#   baseline.
#
# See docs/perf/README.md for how to profile and how to update the baseline deliberately.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$PWD"
PERF_DIR="$ROOT/docs/perf"
PACKAGE_DIR="$ROOT/Packages/OpenSheetsCore"

CONFIGURATION="release"
FILTER="Benchmark"
TOLERANCE=""
COMPARE=true
RECORD_BASELINE=false
ALLOW_LOADED_BASELINE=false
STRICT=false
KEEP_LOG=false

while [[ $# -gt 0 ]]; do
	case "$1" in
		--record-baseline) RECORD_BASELINE=true; STRICT=true ;;
		--baseline-on-a-busy-machine) RECORD_BASELINE=true; STRICT=true; ALLOW_LOADED_BASELINE=true ;;
		--no-compare) COMPARE=false ;;
		--strict) STRICT=true ;;
		--debug) CONFIGURATION="debug" ;;
		--keep-log) KEEP_LOG=true ;;
		--filter) FILTER="${2:?--filter needs a regex}"; shift ;;
		--tolerance) TOLERANCE="${2:?--tolerance needs a fraction, e.g. 0.10}"; shift ;;
		--package-dir) PACKAGE_DIR="${2:?--package-dir needs a path}"; shift ;;
		-h|--help)
			sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done

mkdir -p "$PERF_DIR"
LOG="$(mktemp -t opensheets-bench)"
$KEEP_LOG || trap 'rm -f "$LOG"' EXIT

echo "==> benchmark lane ($CONFIGURATION, filter /$FILTER/)"
uptime | sed 's/^/    /'

ARGS=(test -c "$CONFIGURATION" --filter "$FILTER")
# Release test builds need testability turned back on or @testable imports fail to link. Matches
# Scripts/test.sh, which is A0's and is where that lesson was first paid for.
[[ "$CONFIGURATION" == "release" ]] && ARGS+=(-Xswiftc -enable-testing)
# Serial on purpose. The allocation and residency counters read process-wide statistics, and a
# suite running beside them makes those numbers meaningless — measured going *negative* once.
ARGS+=(--no-parallel)

# `set +e` around the pipeline: `tee` masks swift's exit status and PIPESTATUS is the only way
# back to it, but a trailing `|| true` would overwrite PIPESTATUS with `true`'s.
set +e
(
	cd "$PACKAGE_DIR"
	OPENSHEETS_BENCH=1 swift "${ARGS[@]}"
) 2>&1 | tee "$LOG" | grep -E '^(@@OPENSHEETS_BENCH@@|  \[perf/|  \[snapshot\])'
BENCH_STATUS=${PIPESTATUS[0]}
set -e

SAMPLES=$(grep -c '^@@OPENSHEETS_BENCH@@ ' "$LOG" || true)
echo "==> collected ${SAMPLES:-0} sample(s)"

if [[ "${SAMPLES:-0}" -eq 0 ]]; then
	echo "::error::the benchmark lane produced no samples" >&2
	echo "    filter /$FILTER/ matched nothing, or the suites are gated off." >&2
	echo "    Last 40 lines of the run:" >&2
	tail -40 "$LOG" >&2
	exit 1
fi

if [[ "$BENCH_STATUS" -ne 0 ]]; then
	echo "::warning::the benchmark lane exited $BENCH_STATUS — samples were still collected."
	echo "    A benchmark assertion failed. The numbers below are still real, and the gate below"
	echo "    is still the gate. Under --strict this also fails the run; by default it does not,"
	echo "    because a wall-clock assertion inside a benchmark is the flakiest thing in the"
	echo "    repository and must not be what makes this job red."
fi

export OPENSHEETS_BENCH_LOG="$LOG"
export OPENSHEETS_PERF_DIR="$PERF_DIR"
export OPENSHEETS_BENCH_CONFIGURATION="$CONFIGURATION"
export OPENSHEETS_BENCH_STRICT="$STRICT"
export OPENSHEETS_BENCH_COMPARE="$COMPARE"
export OPENSHEETS_BENCH_RECORD_BASELINE="$RECORD_BASELINE"
export OPENSHEETS_BENCH_ALLOW_LOADED_BASELINE="$ALLOW_LOADED_BASELINE"
export OPENSHEETS_BENCH_TOLERANCE="$TOLERANCE"

# Python rather than jq: jq is not on a stock macOS runner, python3 is. Kept inline rather than in
# a sibling script so the whole harness is one reviewable file.
set +e
python3 - <<'PYTHON'
import json
import os
import platform
import subprocess
import sys
import time

perf_dir = os.environ["OPENSHEETS_PERF_DIR"]
log_path = os.environ["OPENSHEETS_BENCH_LOG"]
configuration = os.environ["OPENSHEETS_BENCH_CONFIGURATION"]
strict = os.environ["OPENSHEETS_BENCH_STRICT"] == "true"
compare = os.environ["OPENSHEETS_BENCH_COMPARE"] == "true"
record_baseline = os.environ["OPENSHEETS_BENCH_RECORD_BASELINE"] == "true"
allow_loaded_baseline = os.environ.get("OPENSHEETS_BENCH_ALLOW_LOADED_BASELINE") == "true"
tolerance_override = os.environ.get("OPENSHEETS_BENCH_TOLERANCE") or ""

MARKER = "@@OPENSHEETS_BENCH@@ "
LOWER_IS_BETTER = {"seconds": True, "milliseconds": True, "bytes": True, "count": True,
                   "ratio": False, "rate": False}
TIME_UNITS = {"seconds", "milliseconds"}


def load(path, default=None):
    try:
        with open(path) as handle:
            return json.load(handle)
    except FileNotFoundError:
        return default


budgets_doc = load(os.path.join(perf_dir, "budgets.json"), {"metrics": []})
budgets = {entry["id"]: entry for entry in budgets_doc.get("metrics", [])}
# Two tolerances, because counts and clocks are not the same kind of number. Measured on this
# hardware: counts and byte sizes move by 0.3% between runs, wall-clock metrics by 3-29%. One
# tolerance covering both is either a gate that never fires or a gate that always does.
tolerance = float(budgets_doc.get("regressionTolerance", 0.10))
timing_tolerance = float(budgets_doc.get("timingTolerance", 0.20))
loaded_multiplier = float(budgets_doc.get("loadedMachineTimingMultiplier", 2.5))
if tolerance_override:
    tolerance = timing_tolerance = float(tolerance_override)

# --- collect ---------------------------------------------------------------------------------
samples = {}
with open(log_path, errors="replace") as handle:
    for line in handle:
        index = line.find(MARKER)
        if index < 0:
            continue
        try:
            sample = json.loads(line[index + len(MARKER):])
        except json.JSONDecodeError:
            continue
        # Last write wins: a metric emitted twice in one run is the later measurement.
        samples[sample["id"]] = sample


def sysctl(name):
    try:
        return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True,
                              timeout=5).stdout.strip()
    except Exception:
        return ""


load_average = os.getloadavg()
metrics = {}
for identifier, entry in budgets.items():
    sample = samples.get(identifier)
    if sample is None:
        metrics[identifier] = {
            "value": None,
            "unit": entry.get("unit", "count"),
            "budget": entry.get("budget"),
            "status": "blocked",
            "samples": 0,
            "owner": entry.get("owner"),
            "note": "no sample emitted"
                    + (f"; blocked on {entry['blockedOn']}" if entry.get("blockedOn") else ""),
        }
        continue
    metrics[identifier] = {
        "value": sample.get("value"),
        "unit": sample.get("unit", entry.get("unit", "count")),
        "budget": entry.get("budget", sample.get("budget")),
        "status": sample.get("status", "measured"),
        "samples": sample.get("samples", 1),
        "owner": entry.get("owner"),
        "machineFactor": sample.get("machineFactor"),
        "normalizedLoad": sample.get("normalizedLoad"),
        "note": sample.get("note"),
    }

# Anything emitted but not declared still gets recorded, flagged so somebody adds it to
# budgets.json. Dropping it would make an unlisted metric invisible, which is how metrics die.
for identifier, sample in samples.items():
    if identifier in metrics:
        continue
    metrics[identifier] = {
        "value": sample.get("value"),
        "unit": sample.get("unit", "count"),
        "budget": sample.get("budget"),
        "status": sample.get("status", "measured"),
        "samples": sample.get("samples", 1),
        "owner": None,
        "note": (sample.get("note") or "") + " [undeclared: add it to docs/perf/budgets.json]",
    }

calibration = (samples.get("machine.calibration.seconds") or {}).get("value")
normalized_load = (samples.get("machine.load.normalized") or {}).get("value")
if normalized_load is None:
    normalized_load = load_average[0] / max(os.cpu_count() or 1, 1)

latest = {
    "schema": 1,
    "takenAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "configuration": configuration,
    # No git commands here: several agents share this working directory and a concurrent git
    # invocation corrupts the index. CI passes the revision in instead.
    "revision": os.environ.get("OPENSHEETS_PERF_REVISION") or os.environ.get("GITHUB_SHA"),
    "machine": {
        "os": platform.platform(),
        "arch": platform.machine(),
        "model": sysctl("hw.model"),
        "cpu": sysctl("machdep.cpu.brand_string"),
        "cores": os.cpu_count(),
        "loadAverage": [round(value, 2) for value in load_average],
        "normalizedLoad": round(normalized_load, 3),
    },
    "calibrationSeconds": calibration,
    "metrics": dict(sorted(metrics.items())),
}

latest_path = os.path.join(perf_dir, "latest.json")
with open(latest_path, "w") as handle:
    json.dump(latest, handle, indent=2, sort_keys=False)
    handle.write("\n")
print(f"==> wrote {latest_path}")

measured = [key for key, value in metrics.items() if value["status"] in ("measured", "degraded")]
blocked = [key for key, value in metrics.items() if value["status"] == "blocked"]
print(f"    {len(measured)} measured, {len(blocked)} blocked, "
      f"load {normalized_load:.2f}× cores, calibration "
      f"{calibration if calibration is None else format(calibration, '.6f')}s")


def render(value, unit):
    if value is None:
        return "—"
    if unit == "bytes":
        for scale, suffix in ((1 << 30, "GB"), (1 << 20, "MB"), (1 << 10, "KB")):
            if abs(value) >= scale:
                return f"{value / scale:.1f} {suffix}"
        return f"{value:.0f} B"
    if unit in TIME_UNITS:
        return f"{value * 1000:.3f} ms" if unit == "seconds" else f"{value:.3f} ms"
    if unit == "ratio":
        return f"{value:.3f}"
    return f"{value:.0f}"


# --- budgets ---------------------------------------------------------------------------------
over_budget = []
for identifier in sorted(measured):
    metric = metrics[identifier]
    budget = metric["budget"]
    if budget is None:
        continue
    lower_is_better = LOWER_IS_BETTER.get(metric["unit"], True)
    exceeded = metric["value"] > budget if lower_is_better else metric["value"] < budget
    if not exceeded:
        continue
    # A timing budget missed on a busy machine is not evidence. Say so and move on; the
    # baseline comparison below is the load-aware gate.
    if metric["unit"] in TIME_UNITS and metric["status"] == "degraded" and not strict:
        print(f"::warning::{identifier} is over budget "
              f"({render(metric['value'], metric['unit'])} > "
              f"{render(budget, metric['unit'])}) but the machine was loaded — not gating on it")
        continue
    over_budget.append((identifier, metric, budget))

# --- baseline --------------------------------------------------------------------------------
baseline_path = os.path.join(perf_dir, "baseline.json")

if record_baseline:
    if normalized_load >= 0.5 and not allow_loaded_baseline:
        print(f"::error::refusing to record a baseline at {normalized_load:.2f}× load. "
              "A baseline taken on a busy machine bakes that contention into every future "
              "comparison, and every run afterwards looks like an improvement. Quiet the machine "
              "and try again — or, if it genuinely cannot get quieter, "
              "--baseline-on-a-busy-machine records anyway and stamps the load into the file.",
              file=sys.stderr)
        sys.exit(1)
    if normalized_load >= 0.5:
        latest["baselineTakenUnderLoad"] = True
        print(f"::warning::recording a baseline at {normalized_load:.2f}× load because "
              "--baseline-on-a-busy-machine was passed. `baselineTakenUnderLoad` is set in the "
              "file. Re-record it on a quiet machine when one is available: timing numbers taken "
              "under contention are a ceiling, not a measurement.")
    with open(baseline_path, "w") as handle:
        json.dump(latest, handle, indent=2, sort_keys=False)
        handle.write("\n")
    print(f"==> wrote {baseline_path}")
    print("    Commit it with a message saying WHY the numbers moved. See docs/perf/README.md.")
    sys.exit(1 if over_budget else 0)

regressions = []
improvements = []
if compare:
    baseline = load(baseline_path)
    if baseline is None:
        print(f"::warning::no {baseline_path} yet — nothing to compare against. "
              "Run Scripts/bench.sh --record-baseline on an idle machine.")
    else:
        baseline_calibration = baseline.get("calibrationSeconds")
        speed = 1.0
        if calibration and baseline_calibration:
            speed = calibration / baseline_calibration
        if baseline.get("configuration") != configuration:
            print(f"::warning::baseline was taken in {baseline.get('configuration')} and this run "
                  f"is {configuration}. Comparison skipped — the two are not comparable.")
        else:
            loaded = normalized_load >= 1.0 and not strict
            effective_timing = timing_tolerance * loaded_multiplier if loaded else timing_tolerance
            if loaded:
                print(f"::warning::machine load is {normalized_load:.2f}× its core count. "
                      f"Timing metrics are compared at {effective_timing:.0%} instead of "
                      f"{timing_tolerance:.0%}; counts and sizes stay at {tolerance:.0%}. "
                      "A timing regression reported here MUST be re-checked on an idle machine "
                      "(or with --strict) before anyone acts on it.")
            print(f"==> comparing against baseline (machine is {speed:.2f}× the baseline's speed, "
                  f"counts at {tolerance:.0%}, timings at {effective_timing:.0%})")

            for identifier in sorted(measured):
                metric = metrics[identifier]
                before = (baseline.get("metrics") or {}).get(identifier)
                if not before or before.get("value") is None or metric["value"] is None:
                    continue
                if identifier.startswith("machine."):
                    continue
                unit = metric["unit"]
                current = metric["value"]
                # Normalise time by how much slower this machine is. Bytes and counts are
                # machine-independent and must not be scaled — that would hide a real growth.
                if unit in TIME_UNITS and speed > 0:
                    current = current / speed
                previous = before["value"]
                if previous == 0:
                    continue
                delta = (current - previous) / abs(previous)
                if not LOWER_IS_BETTER.get(unit, True):
                    delta = -delta
                noisy = bool((budgets.get(identifier) or {}).get("noisy"))
                limit = effective_timing if (unit in TIME_UNITS or noisy) else tolerance
                if delta > limit:
                    regressions.append((identifier, previous, current, delta, unit, limit))
                elif delta < -limit:
                    improvements.append((identifier, previous, current, delta, unit))

if improvements:
    print(f"==> {len(improvements)} improvement(s)")
    for identifier, previous, current, delta, unit in improvements:
        print(f"    ✓ {identifier}: {render(previous, unit)} → {render(current, unit)} "
              f"({delta:+.1%})")

if over_budget:
    print(f"==> {len(over_budget)} metric(s) over budget")
    for identifier, metric, budget in over_budget:
        print(f"::error::{identifier} is over budget: "
              f"{render(metric['value'], metric['unit'])} vs "
              f"{render(budget, metric['unit'])} ({metric.get('owner') or 'unowned'})")

if regressions:
    print(f"==> {len(regressions)} regression(s)")
    for identifier, previous, current, delta, unit, limit in regressions:
        print(f"::error::{identifier} regressed {delta:+.1%} (tolerance {limit:.0%}): "
              f"baseline {render(previous, unit)} → now {render(current, unit)}"
              + (", machine-speed normalised" if unit in TIME_UNITS else ""))
    print("    If this is a deliberate trade, update the baseline with "
          "Scripts/bench.sh --record-baseline and say why in the commit message.")

if blocked:
    print(f"==> {len(blocked)} budget(s) not measurable yet:")
    for identifier in sorted(blocked):
        print(f"    · {identifier} ({metrics[identifier].get('owner') or 'unowned'})")

sys.exit(1 if (regressions or over_budget) else 0)
PYTHON
PYTHON_STATUS=$?
set -e
if [[ "$PYTHON_STATUS" -ne 0 ]]; then
	echo "==> FAILED"
	exit "$PYTHON_STATUS"
fi

if [[ "$BENCH_STATUS" -ne 0 ]]; then
	if [[ "$STRICT" == true ]]; then
		echo "==> the numbers are within budget but a benchmark assertion failed (--strict)"
		exit "$BENCH_STATUS"
	fi
	echo "==> the numbers are within budget; a benchmark assertion failed (not gating — see above)"
fi

echo "==> OK"
