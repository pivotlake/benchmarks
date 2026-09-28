#!/bin/bash
#
# run-all.sh - run a suite's queries on every engine over the same data and
# compare them. A suite's own run-all.sh (tpch/, ssb/) runs this from its
# directory.
#
# Generates the dataset at the scale factor (the suite's data/generate.sh),
# rewrites it into the parquet files pivot writes (pivot-style.sh), then runs
# each engine's benchmark.sh over those files: a power run, all the queries in
# one session from a cold start, timed end to end (see power-run.sh). Logs go
# to results/sf<N>/; the comparison prints at the end.
#
# Everything an engine stores (its tables, its spill files) stays in its own
# directory, so a checkout on an NVMe mount keeps the whole run on it.
#
# Usage: ./run-all.sh <scale factor> [engine ...]
#   DATA_DIR       where datasets go (default ./datasets)
#   PIVOT_BINARY   run a pivot you built instead of the latest release
#   BENCH_TIMEOUT  seconds the whole power run may take (default 3600)

set -e

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
suite="$(basename "$PWD")"

# Every directory with an install script is an engine.
all_engines=()
for script in */install; do all_engines+=("$(dirname "$script")"); done

usage() {
    sed -n '3,18p' "$lib/run-all.sh" | sed 's/^# \{0,1\}//' >&2
    echo "  $suite engines (default all): ${all_engines[*]}" >&2
    exit 1
}

[ $# -ge 1 ] || usage
sf="$1"
shift
engines=("$@")
[ ${#engines[@]} -gt 0 ] || engines=("${all_engines[@]}")
for engine in "${engines[@]}"; do
    [ -f "$engine/install" ] || { echo "unknown engine: $engine" >&2; usage; }
done
data_dir="${DATA_DIR:-$PWD/datasets}"
dataset="$data_dir/sf$sf"
results="$PWD/results/sf$sf"

if [ ! -d "$dataset" ]; then
    data/generate.sh "$sf" "$data_dir/generated-sf$sf"
    "$lib/pivot-style.sh" pivot/create.sql "$data_dir/generated-sf$sf" "$dataset"
fi

mkdir -p "$results"
logs=()
for engine in "${engines[@]}"; do
    echo
    echo "=== [$(( ${#logs[@]} + 1 ))/${#engines[@]}] $suite, $engine, SF$sf, $(date '+%F %T')"
    (cd "$engine" && BENCH_DATA="$dataset" BENCH_SF="$sf" ./benchmark.sh) 2>&1 | tee "$results/$engine.log"
    logs+=("$results/$engine.log")
done
echo

"$lib/compare.py" "${logs[@]}"
