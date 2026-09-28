#!/bin/bash
#
# run-all.sh - run ClickBench on several systems with ClickBench's own harness
# (the ClickBench submodule, pivotlake's fork with the pivot entries) and
# compare their times.
#
# The dataset is downloaded once into ./data and hard-linked into each system's
# directory, where the harness's own download then finds it complete. Each
# system's log goes to results/<system>.log; the comparison prints at the end.
# The concurrent-QPS test is skipped: this compares query times.
#
# Usage: ./run-all.sh [system ...]   (directory names in ClickBench/)

set -e
cd "$(dirname "$0")"

default_systems=(
    pivot-parquet-partitioned
    duckdb-parquet-partitioned
    duckdb
    clickhouse
    clickhouse-parquet-partitioned
    datafusion-partitioned
    spark
)

usage() {
    sed -n '3,12p' run-all.sh | sed 's/^# \{0,1\}//' >&2
    echo "  default systems: ${default_systems[*]}" >&2
    echo "  any directory in ClickBench/ with a benchmark.sh is a system (ls ClickBench)" >&2
    exit 1
}

[[ "${1:-}" != -h && "${1:-}" != --help ]] || usage
systems=("$@")
[ ${#systems[@]} -gt 0 ] || systems=("${default_systems[@]}")
for system in "${systems[@]}"; do
    [ -f "ClickBench/$system/benchmark.sh" ] || { echo "unknown system: $system" >&2; usage; }
done
export BENCH_CONCURRENT_DURATION=0

ClickBench/lib/download-hits-parquet-partitioned data
ClickBench/lib/download-hits-parquet-single data

mkdir -p results
for system in "${systems[@]}"; do
    echo
    echo "=== $system, $(date '+%F %T')"
    case $(grep -o 'download-hits-parquet-[a-z]*' "ClickBench/$system/benchmark.sh") in
        download-hits-parquet-single)      ln -f data/hits.parquet "ClickBench/$system/" ;;
        download-hits-parquet-partitioned) ln -f data/hits_*.parquet "ClickBench/$system/" ;;
    esac
    (cd "ClickBench/$system" && ./benchmark.sh) 2>&1 | tee "results/$system.log"
done

logs=()
for system in "${systems[@]}"; do logs+=("results/$system.log"); done
../lib/compare.py "${logs[@]}"
