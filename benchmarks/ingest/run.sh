#!/bin/bash
#
# run.sh - how much ingest a database sustains into a table of logs while a
# query keeps running against it: pivot into a table in S3, or ClickHouse into
# a MergeTree on the disk this directory is on.
#
# Starts a server over new, empty storage, creates the table and inserts into
# it at each of the given loads in turn, a step each, on the same table. A
# load is a number of inserts per second and the size of one insert.
# Meanwhile one connection runs the query again and again over the most
# recent rows. Each step is judged by what changes during it, so a step needs
# minutes, not hours:
#
#   - whether the inserts reach the rate asked for, how many are refused,
#     and how long one takes
#   - how fast the table's live data files (pivot) or active parts
#     (ClickHouse) pile up: merging keeps pace with the inserts when the
#     count stays level
#   - how much memory the server holds, and for pivot how much of its buffer
#     pool its operators pin and its caches fill
#   - how busy the machine is, and the cores the server and the loader use
#   - how long the query takes
#
# The table comes in two layouts, each run from scratch on storage of its own:
#   spread    sorted by deployment, then time: every insert holds rows of every
#             deployment, so every file spans the whole sort key
#   ordered   sorted by time: every insert follows the one before
#
# Usage: ./run.sh [--engine pivot|clickhouse] [options]
#   --engine <name>         pivot (the default) or clickhouse
#   --lake <url>            pivot: where lakes are created in S3, one
#                           directory per layout and run, deleted when the
#                           run ends (default: $INGEST_LAKE_URL)
#   --layouts "spread ordered"   default: spread
#   --loads "<inserts per second>x<size per insert> ..."
#                           one step per load, in order; sizes are Arrow bytes
#                           with a unit: 1KiB, 64KiB, 1MiB (default: 100x1MiB)
#   --step-seconds <n>      how long each load runs (default 300)
#   --connections <n>       connections the inserts are spread over (default 32)
#   --query-range <seconds> how far back the query reads; 0 reads the whole
#                           table (default 900)
#   --query-pause <seconds> between two runs of the query (default 1)
#   --no-query              insert only
#   --region <name>         pivot: the bucket's region (default: $AWS_REGION,
#                           else $AWS_DEFAULT_REGION, else asked of the bucket)
#   --keep-lake             leave the storage: the lake in S3, or ClickHouse's
#                           data directory
#
# Pivot signs its S3 requests as the machine's own identity (an EC2 instance
# role, or the keys in the environment), which needs to read, write, list and
# delete under --lake. ClickHouse is the latest build from clickhouse.com on
# its default settings, with its data in clickhouse-data/ here: put this
# directory on the disk to measure. Its inserts are synchronous, each a part
# of its own, as its client sends them by default.
#   PIVOT_BINARY   run a pivot you built instead of the latest release
#   PIVOT_PORT     the port pivot listens on (default 5432)
#
# Results go to results/<engine>-<layout>/: result.json, the tables printed at
# the end (summary.txt), the server's log, a log per step and the samples.

set -euo pipefail
cd "$(dirname "$0")"

engine=pivot
lake="${INGEST_LAKE_URL:-}"
layouts="spread"
loads="100x1MiB"
step_seconds=300
connections=32
query_range=900
query_pause=1
with_query=yes
region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
keep_lake=no
: "${PIVOT_HOME:=$HOME/.pivot}"
: "${PIVOT_PORT:=5432}"

usage() { sed -n '3,61p' run.sh | sed 's/^# \{0,1\}//' >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --engine)       engine="$2"; shift 2 ;;
        --lake)         lake="$2"; shift 2 ;;
        --layouts)      layouts="$2"; shift 2 ;;
        --loads)        loads="$2"; shift 2 ;;
        --step-seconds) step_seconds="$2"; shift 2 ;;
        --connections)  connections="$2"; shift 2 ;;
        --query-range)  query_range="$2"; shift 2 ;;
        --query-pause)  query_pause="$2"; shift 2 ;;
        --no-query)     with_query=no; shift ;;
        --region)       region="$2"; shift 2 ;;
        --keep-lake)    keep_lake=yes; shift ;;
        *)              usage ;;
    esac
done
case "$engine" in
    pivot)      [ -n "$lake" ] || { echo "--lake is required" >&2; usage; } ;;
    clickhouse) ;;
    *)          echo "unknown engine: $engine" >&2; usage ;;
esac
lake="${lake%/}"

# The bytes a size such as 64KiB or 1MiB names.
read_size_bytes() {
    local size="${1,,}" number unit
    number="${size%%[a-z]*}"
    unit="${size#"$number"}"
    case "$unit" in
        ''|b)       echo "$number" ;;
        k|kb|kib)   echo $(( number * 1024 )) ;;
        m|mb|mib)   echo $(( number * 1024 * 1024 )) ;;
        g|gb|gib)   echo $(( number * 1024 * 1024 * 1024 )) ;;
        *)          echo "unknown size: $1" >&2; return 1 ;;
    esac
}

for layout in $layouts; do
    case "$layout" in
        spread|ordered) ;;
        *) echo "unknown layout: $layout" >&2; usage ;;
    esac
done
for load in $loads; do
    case "$load" in
        *x*) read_size_bytes "${load#*x}" > /dev/null ;;
        *)   echo "a load is <inserts per second>x<size per insert>, not $load" >&2; usage ;;
    esac
done

if [ "$engine" = pivot ]; then
    command -v aws > /dev/null || { echo "the AWS CLI is needed (aws)" >&2; exit 1; }
    if ! command -v psql > /dev/null; then
        sudo apt-get update -y
        sudo apt-get install -y postgresql-client
    fi
    if [ -z "${PIVOT_BINARY:-}" ]; then
        curl https://pivotlake.io | sh
        PIVOT_BINARY="$PIVOT_HOME/cli/latest/pivot"
    fi
    if [ -z "$region" ]; then
        bucket="${lake#s3://}"
        region=$(aws s3api get-bucket-location --bucket "${bucket%%/*}" --query LocationConstraint --output text)
        [ "$region" != None ] || region=us-east-1
    fi
    connection="host=127.0.0.1 port=$PIVOT_PORT user=pivot dbname=postgres"
else
    # The latest build, as ClickBench installs it.
    [ -x ./clickhouse ] || curl -fsSL https://clickhouse.com/ | sh
    connection="http://127.0.0.1:8123"
fi

source ../lib/install-rust.sh
cargo build --release --manifest-path loader/Cargo.toml
loader="$PWD/loader/target/release/logs-load"

# Run the SQL on standard input on the server.
run_sql() {
    if [ "$engine" = pivot ]; then
        psql -h 127.0.0.1 -p "$PIVOT_PORT" -U pivot -d postgres -X -q -v ON_ERROR_STOP=1 -f -
    else
        ./clickhouse client --multiquery
    fi
}
is_server_up() { echo 'SELECT 1' | run_sql > /dev/null 2>&1; }

server_pid=""
sampler_pid=""
lake_url=""

stop_server() {
    [ -z "$sampler_pid" ] || kill "$sampler_pid" 2> /dev/null || true
    sampler_pid=""
    [ -n "$server_pid" ] || return 0
    kill "$server_pid" 2> /dev/null || true
    # The server holds most of the machine's memory until it exits; a
    # successor started before then risks an OOM kill.
    while kill -0 "$server_pid" 2> /dev/null; do sleep 0.2; done
    server_pid=""
}

delete_lake() {
    [ -n "$lake_url" ] && [ "$keep_lake" = no ] || return 0
    echo "deleting $lake_url"
    if [ "$engine" = pivot ]; then
        aws s3 rm "$lake_url/" --recursive --only-show-errors || echo "deleting $lake_url failed; it is left in S3" >&2
    else
        rm -rf "$lake_url"
    fi
    lake_url=""
}

trap 'stop_server; delete_lake' EXIT

failed=()
for layout in $layouts; do
    case "$engine/$layout" in
        pivot/spread)       sorted_by='deployment_id, "timestamp"' ;;
        pivot/ordered)      sorted_by='"timestamp"' ;;
        clickhouse/spread)  sorted_by='deployment_id, timestamp' ;;
        clickhouse/ordered) sorted_by='timestamp' ;;
    esac
    results="$PWD/results/$engine-$layout"
    rm -rf "$results"
    mkdir -p "$results"
    echo
    if [ "$engine" = pivot ]; then
        lake_url="$lake/$(date -u +%Y%m%d-%H%M%S)-$layout-$RANDOM"
        echo "=== ingest, pivot, $layout layout, loads: $loads, ${step_seconds}s each, lake $lake_url, $(date '+%F %T')"
        cat > "$results/config.yaml" <<CONFIG
log: info
server:
  bind: 127.0.0.1:$PIVOT_PORT
datastores:
  lake:
    kind: pivotlake
    location: $lake_url
    default: true
secrets:
  lake:
    type: s3
    region: $region
CONFIG
        nohup "$PIVOT_BINARY" server --config "$results/config.yaml" > "$results/server.log" 2>&1 &
        server_pid=$!
        create_table=create.sql
        query=query.sql
    else
        lake_url="$PWD/clickhouse-data/$layout"
        rm -rf "$lake_url"
        mkdir -p "$lake_url"
        echo "=== ingest, clickhouse, $layout layout, loads: $loads, ${step_seconds}s each, data in $lake_url, $(date '+%F %T')"
        # The server keeps what it writes beside its tables, so it is started
        # in its data directory, and without the watchdog process it would
        # otherwise run under, so that its pid is the server's own.
        clickhouse="$PWD/clickhouse"
        (cd "$lake_url" && CLICKHOUSE_WATCHDOG_ENABLE=0 exec nohup "$clickhouse" server -- --path="$lake_url/" --listen_host=127.0.0.1) \
            > "$results/server.log" 2>&1 &
        server_pid=$!
        create_table=create-clickhouse.sql
        query=query-clickhouse.sql
    fi
    for _ in $(seq 1 120); do
        is_server_up && break
        kill -0 "$server_pid" 2> /dev/null || break
        sleep 1
    done
    if ! is_server_up; then
        echo "the server did not come up; see $results/server.log" >&2
        tail -n 20 "$results/server.log" >&2
        failed+=("$layout")
        stop_server
        delete_lake
        continue
    fi
    sed "s|{sorted_by}|$sorted_by|" "$create_table" | run_sql

    ./sample.py "$engine" "$server_pid" "$PIVOT_PORT" logs "$results/samples.tsv" 2> "$results/sample.log" &
    sampler_pid=$!

    query_options=()
    [ "$with_query" = no ] || query_options=(--query-file "$PWD/$query" --query-range-seconds "$query_range" \
        --query-pause-ms "$(( query_pause * 1000 ))")
    step=0
    : > "$results/steps.tsv"
    for load in $loads; do
        step=$(( step + 1 ))
        inserts_per_second="${load%%x*}"
        insert_bytes=$(read_size_bytes "${load#*x}")
        echo "--- step $step: $inserts_per_second inserts per second of ${load#*x}, $(date '+%T')"
        started=$(date +%s)
        status=0
        "$loader" --engine "$engine" --connection "$connection" --table logs --inserts-per-second "$inserts_per_second" \
            --insert-bytes "$insert_bytes" --connections "$connections" --seconds "$step_seconds" \
            "${query_options[@]}" > "$results/loader-$step.log" 2> "$results/loader-$step.err" || status=$?
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$step" "$load" "$inserts_per_second" "$insert_bytes" "$started" "$(date +%s)" "$status" \
            >> "$results/steps.tsv"
        if [ "$status" != 0 ]; then
            echo "step $step: the loader stopped early; see $results/loader-$step.err and server.log" >&2
            tail -n 3 "$results/loader-$step.err" >&2
            failed+=("$layout step $step")
            break
        fi
    done

    stop_server
    ./summarize.py "$results" --engine "$engine" --layout "$layout" --query-range "$query_range" --connections "$connections" | tee "$results/summary.txt"
    delete_lake
done

if [ ${#failed[@]} -gt 0 ]; then
    echo "failed: ${failed[*]}" >&2
    exit 1
fi
