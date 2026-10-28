#!/bin/bash
#
# Power-run driver: times one pass over every query, the way TPC-H's power test
# does. An engine's benchmark.sh exec's this script from the engine's directory
# (<suite>/<engine>/), which holds these scripts:
#
#   install     install the engine
#   start/stop  start/stop its server (no-ops for embedded engines)
#   check       exit 0 once the engine answers
#   load        make the dataset in $BENCH_DATA queryable
#   power       run the query files given as arguments, in order, in ONE
#               session (one process for embedded engines, one connection for
#               servers); print each query's runtime in seconds, one per line;
#               exit non-zero if a query fails
#   data-size   print the bytes the engine queries
#
# After the load the engine is stopped, the page cache dropped and the engine
# started again, then the power run is timed from the moment ./power starts to
# the moment it ends. That wall time is the score. It prints
# "Power run: <seconds>", then "qNN <seconds>" for each query; a run where a
# query failed or that passed $BENCH_TIMEOUT seconds prints "Power run: null".
#
# The queries are the suite's queries/*.sql, in name order; "{fraction}" in a
# query becomes 0.0001 / SF (TPC-H q11's HAVING fraction).
#
# Environment (run-all.sh sets it):
#   BENCH_DATA         dataset directory, one subdirectory of parquet per table
#   BENCH_SF           its scale factor
#   BENCH_RESTARTABLE  "yes" (default) when the engine runs a server
#   BENCH_TIMEOUT      seconds the whole power run may take (default 3600)

set -e

: "${BENCH_DATA:?}" "${BENCH_SF:?}"
: "${BENCH_RESTARTABLE:=yes}"
: "${BENCH_TIMEOUT:=3600}"

# Engines spill and keep scratch files under $TMPDIR: keep them in the engine's
# directory, on the same disk as its storage, rather than on the root volume.
export TMPDIR="$PWD/tmp"
mkdir -p "$TMPDIR"

check_loop() {
    for _ in $(seq 1 300); do
        ./check >/dev/null 2>&1 && return 0
        sleep 1
    done
    echo "./check did not succeed within 300s" >&2
    return 1
}

wait_stopped() {
    for _ in $(seq 1 60); do
        ./check >/dev/null 2>&1 || return 0
        sleep 1
    done
}

echo "installing"
./install
sync
./start >/dev/null 2>&1 || true
check_loop

echo "loading"
start_time=$(date +%s.%N)
./load
sync
awk -v s="$start_time" -v e="$(date +%s.%N)" 'BEGIN { printf "Load time: %.3f\n", e - s }'

# The queries with the scale factor filled in, in run order.
fraction=$(awk -v sf="$BENCH_SF" 'BEGIN { f = sprintf("%.12f", 0.0001 / sf); sub(/0+$/, "", f); print f }')
queries_dir="$TMPDIR/queries"
rm -rf "$queries_dir"
mkdir -p "$queries_dir"
names=()
for file in ../queries/q*.sql; do
    names+=("$(basename "$file" .sql)")
    sed "s/{fraction}/$fraction/" "$file" > "$queries_dir/$(basename "$file")"
done

# Cold start: the engine restarted and nothing in the page cache.
if [ "$BENCH_RESTARTABLE" = "yes" ]; then
    ./stop >/dev/null 2>&1 || true
    wait_stopped
fi
sync
echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
if [ "$BENCH_RESTARTABLE" = "yes" ]; then
    ./start >/dev/null 2>&1 || true
    check_loop
fi

echo "power run: ${#names[@]} queries in one session"
times="$TMPDIR/times"
start_time=$(date +%s.%N)
timeout "$BENCH_TIMEOUT" ./power "$queries_dir"/q*.sql > "$times" && status=0 || status=$?
end_time=$(date +%s.%N)

if [ "$status" -eq 0 ] && [ "$(wc -l < "$times")" -eq "${#names[@]}" ]; then
    awk -v s="$start_time" -v e="$end_time" 'BEGIN { printf "Power run: %.3f\n", e - s }'
    paste -d ' ' <(printf '%s\n' "${names[@]}") "$times"
else
    echo "power run failed (exit $status), no score" >&2
    echo "Power run: null"
fi

echo -n "Data size: "
./data-size
./stop >/dev/null 2>&1 || true
