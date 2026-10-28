#!/bin/bash
#
# run-and-collect.sh - run some benchmarks on some databases and write the
# results into the website: what the Benchmark workflow runs, usable by hand.
#
# Runs each chosen benchmark's run-all.sh on the databases it has (a failing
# benchmark does not stop the others), turns every log into a result file
# under website/results/ (lib/results-json.py) and bakes the website
# (website/generate-results.sh). Exits non-zero if any benchmark failed, after
# collecting what the others produced.
#
# Usage: ./run-and-collect.sh [options]
#   --databases "pivot duckdb ..."   default: every database below
#   --benchmarks "tpch ssb clickbench"   default: all three
#   --sf "100 1000"                  TPC-H and SSB scale factors, each run in
#                                    turn (default 100)
#   --machine <name>                 for the results (default: the EC2 instance
#                                    type, else the hostname)
#   --collect-only                   skip the runs, convert the logs there are
#   --engine-for <benchmark> <database>  print the engine directory that database
#                                    has in that benchmark (nothing if none) and exit
#
# Databases, and what runs for each:
#   pivot                tpch/ssb: pivot              clickbench: pivot-parquet-partitioned
#   duckdb               tpch/ssb: duckdb             clickbench: duckdb
#   duckdb-parquet       tpch/ssb: duckdb-parquet     clickbench: duckdb-parquet-partitioned
#   clickhouse           tpch/ssb: clickhouse         clickbench: clickhouse
#   clickhouse-parquet   tpch/ssb: clickhouse-parquet clickbench: clickhouse-parquet-partitioned
#   datafusion           tpch/ssb: datafusion         clickbench: datafusion-partitioned
#   spark                tpch/ssb: spark              clickbench: spark
#   starrocks            tpch: starrocks              (no SSB or ClickBench entry)
# DATA_DIR, PIVOT_BINARY and BENCH_TIMEOUT pass through to the runs.

set -u
cd "$(dirname "$0")"

all_databases="pivot duckdb duckdb-parquet clickhouse clickhouse-parquet datafusion spark starrocks"
databases="$all_databases"
benchmarks="tpch ssb clickbench"
sfs=100
machine=""
collect_only=no

# The engine directory a database has in a benchmark, or nothing.
engine_for() {
    local benchmark="$1" database="$2"
    case "$benchmark/$database" in
        clickbench/pivot)              echo pivot-parquet-partitioned ;;
        clickbench/duckdb-parquet)     echo duckdb-parquet-partitioned ;;
        clickbench/clickhouse-parquet) echo clickhouse-parquet-partitioned ;;
        clickbench/datafusion)         echo datafusion-partitioned ;;
        clickbench/starrocks)          ;;
        ssb/starrocks)                 ;;
        */*)                           echo "$database" ;;
    esac
}

usage() { sed -n '3,30p' run-and-collect.sh | sed 's/^# \{0,1\}//' >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --engine-for)   engine_for "$2" "$3"; exit 0 ;;
        --databases)    databases="$2"; shift 2 ;;
        --benchmarks)   benchmarks="$2"; shift 2 ;;
        --sf)           sfs="$2"; shift 2 ;;
        --machine)      machine="$2"; shift 2 ;;
        --collect-only) collect_only=yes; shift ;;
        *)              usage ;;
    esac
done


for database in $databases; do
    case " $all_databases " in
        *" $database "*) ;;
        *) echo "unknown database: $database" >&2; usage ;;
    esac
done
for benchmark in $benchmarks; do
    [ -f "$benchmark/run-all.sh" ] || { echo "unknown benchmark: $benchmark" >&2; usage; }
done

if [ -z "$machine" ]; then
    token=$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' 2>/dev/null || true)
    [ -z "$token" ] || machine=$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || true)
    [ -n "$machine" ] || machine=$(hostname -s)
fi
date=$(date +%F)
echo "machine: $machine, date: $date, scale factors: $sfs"
echo "databases: $databases"
echo "benchmarks: $benchmarks"

failed=()
for benchmark in $benchmarks; do
    engines=()
    for database in $databases; do
        engine=$(engine_for "$benchmark" "$database")
        [ -z "$engine" ] || engines+=("$engine")
    done
    [ ${#engines[@]} -gt 0 ] || { echo "$benchmark: none of the databases has an entry, skipped"; continue; }

    # ClickBench has no scale factor: one run; TPC-H and SSB: one per scale factor.
    if [ "$benchmark" = clickbench ]; then run_sfs=""; else run_sfs="$sfs"; fi
    for sf in ${run_sfs:-once}; do
        if [ "$benchmark" = clickbench ]; then
            title="$benchmark"; results="clickbench/results"; sf_args=()
        else
            title="$benchmark SF$sf"; results="$benchmark/results/sf$sf"; sf_args=(--sf "$sf")
        fi

        if [ "$collect_only" = no ]; then
            echo
            echo "##### $title: ${engines[*]}, $(date '+%F %T')"
            if [ "$benchmark" = clickbench ]; then
                clickbench/run-all.sh "${engines[@]}" || failed+=("$title")
            else
                "$benchmark/run-all.sh" "$sf" "${engines[@]}" || failed+=("$title")
            fi
        fi

        logs=()
        for engine in "${engines[@]}"; do
            log="$results/$engine.log"
            [ -f "$log" ] && logs+=("$log") || echo "$title: no log for $engine" >&2
        done
        echo
        echo "##### $title: results"
        [ ${#logs[@]} -eq 0 ] ||
            lib/results-json.py --benchmark "$benchmark" --machine "$machine" "${sf_args[@]}" --date "$date" "${logs[@]}" || true
    done
done

echo
../website/generate-results.sh

if [ ${#failed[@]} -gt 0 ]; then
    echo "failed: ${failed[*]}" >&2
    exit 1
fi
