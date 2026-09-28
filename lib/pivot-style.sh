#!/bin/bash
#
# pivot-style.sh - rewrite a generated dataset into the parquet files pivot
# itself writes, the layout a table has after it was loaded with INSERT: every
# engine then runs on the same pivot-written files.
#
# A throwaway pivot server adopts the generated files as generated_<table>,
# runs INSERT INTO <table> SELECT * FROM generated_<table> into its own tables,
# which carry the create.sql's sort_by (each table's primary key), and
# COMPACT <table> FINAL to settle them the way background compaction would: the
# rows end up sorted by the key across the table's files. The files each
# table's Delta log then names are hard-linked into <output dir>/<table>/.
#
# Usage: ./pivot-style.sh <pivot create.sql> <generated dir> <output dir>
#   The create.sql is a suite's pivot/create.sql (tables adopting {source}/<table>);
#   the pivot/install beside it installs pivot.
#   PIVOT_BINARY  use this pivot instead of the latest release

set -eu

create_sql=$(realpath "$1")
source_dir=$(realpath "$2")
out=$(realpath -m "$3")
here=$(cd "$(dirname "$0")" && pwd)
work="$out.work"
: "${PIVOT_HOME:=$HOME/.pivot}"
: "${PIVOT_BINARY:=$PIVOT_HOME/cli/latest/pivot}"
: "${PIVOT_PORT:=5433}"

"$(dirname "$create_sql")/install"

rm -rf "$work" "$out"
mkdir -p "$work/catalog" "$work/generated"

# Adopting a directory writes a _delta_log into it, so pivot gets hard links
# rather than the generated directories themselves.
tables=()
for dir in "$source_dir"/*/; do
    table=$(basename "$dir")
    tables+=("$table")
    mkdir "$work/generated/$table"
    ln "$dir"*.parquet "$work/generated/$table/"
done

cat > "$work/config.yaml" <<CONFIG
server:
  bind: 127.0.0.1:$PIVOT_PORT
datastores:
  default:
    kind: pivot
    location: $work/catalog
    default: true
CONFIG
"$PIVOT_BINARY" server --config "$work/config.yaml" > "$work/server.log" 2>&1 &
server=$!
trap 'kill $server 2>/dev/null; wait $server 2>/dev/null' EXIT

sql() {
    psql -h 127.0.0.1 -p "$PIVOT_PORT" -U pivot -d postgres -X -q -v ON_ERROR_STOP=1 "$@"
}
for attempt in $(seq 1 300); do
    sql -c 'SELECT 1' >/dev/null 2>&1 && break
    if ! kill -0 "$server" 2>/dev/null || [ "$attempt" -eq 300 ]; then
        echo "pivot is not answering on port $PIVOT_PORT (set PIVOT_PORT if another" \
            "server holds it); log tail:" >&2
        tail -5 "$work/server.log" >&2
        exit 1
    fi
    sleep 1
done

# The generated tables are only read, so they need no sort key; pivot's own
# tables keep theirs, so INSERT writes sorted rows and COMPACT FINAL settles
# each table until no two files overlap in sort-key range.
sed -e 's/^CREATE TABLE /CREATE TABLE generated_/' -e "s|{source}|$work/generated|g" \
    -e "s/, sort_by = '[^']*'//" "$create_sql" | sql -f -
sed -e "s/with_pre_existing_parquets = '[^']*', //" "$create_sql" | sql -f -

for table in "${tables[@]}"; do
    echo "$table"
    sql -c "INSERT INTO $table SELECT * FROM generated_$table"
    sql -c "COMPACT $table FINAL"
done

python3 "$here/live-files.py" "$work/catalog" "${tables[@]}" |
    while IFS=$'\t' read -r table file; do
        mkdir -p "$out/$table"
        ln "$file" "$out/$table/"
    done

kill "$server"
wait "$server" 2>/dev/null || true
trap - EXIT
rm -rf "$work"
du -sh "$out"
