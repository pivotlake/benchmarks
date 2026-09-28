#!/bin/bash
#
# generate.sh - generate the Star Schema Benchmark tables at a scale factor with
# ssb-dbgen and convert them to parquet, one directory per table
# (<dir>/<table>/*.parquet). lineorder is generated in chunks, one per core, so
# SF1000 takes a couple of minutes on a large machine.
#
# Usage: ./generate.sh <scale factor> <output dir>

set -eu

sf="$1"
out=$(realpath -m "$2")
here=$(cd "$(dirname "$0")" && pwd)

# eyalroz/ssb-dbgen, pinned so a scale factor always yields the same rows.
dbgen_dir="$here/ssb-dbgen"
dbgen="$dbgen_dir/build/dbgen"
if [ ! -x "$dbgen" ]; then
    if ! command -v cmake >/dev/null || ! command -v cc >/dev/null; then
        sudo apt-get update -y
        sudo apt-get install -y cmake build-essential
    fi
    rm -rf "$dbgen_dir"
    git clone https://github.com/eyalroz/ssb-dbgen.git "$dbgen_dir"
    git -C "$dbgen_dir" checkout ae1e254aa4d603d8ef1f44078e5abed011634b23
    cmake -S "$dbgen_dir" -B "$dbgen_dir/build" -DCMAKE_BUILD_TYPE=Release
    cmake --build "$dbgen_dir/build" -j "$(nproc)"
fi

# dbgen writes pipe-separated .tbl files into its working directory.
tbl="$out.tbl"
rm -rf "$tbl" "$out"
mkdir -p "$tbl"
cd "$tbl"
pids=()
for table in c p s d; do
    "$dbgen" -q -f -s "$sf" -T "$table" -b "$dbgen_dir/build/dists.dss" & pids+=($!)
done
chunks=$(nproc)
for chunk in $(seq 1 "$chunks"); do
    "$dbgen" -q -f -s "$sf" -T l -C "$chunks" -S "$chunk" -b "$dbgen_dir/build/dists.dss" & pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid"; done

# Convert with the column names and types of the suite's schema.
schema=$(sed 's/) WITH (.*);/);/' "$here/../pivot/create.sql")
mkdir -p "$out"
for table in lineorder customer supplier part date; do
    columns=$(duckdb -noheader -list -c "$schema
        SELECT '{' || string_agg('''' || column_name || ''': ''' || data_type || '''', ', ' ORDER BY column_index) || '}'
        FROM duckdb_columns() WHERE table_name = '$table'")
    duckdb -c "COPY (FROM read_csv('$tbl/$table.tbl*', delim = '|', header = false, columns = $columns))
               TO '$out/$table' (FORMAT parquet, FILE_SIZE_BYTES '1GB')"
done

cd /
rm -rf "$tbl"
