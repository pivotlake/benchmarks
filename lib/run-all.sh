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
# The <engine>-s3 engines read the same files from a bucket instead of the
# local disk. They run only when named, and the dataset is uploaded to the
# bucket the first time one of them runs at a scale factor. Everything an
# engine stores (its tables, its spill files) stays in its own directory, so a
# checkout on an NVMe mount keeps the whole run on it.
#
# Usage: ./run-all.sh <scale factor> [engine ...]
#   DATA_DIR       where datasets go (default ./datasets)
#   S3_DATA        where the -s3 engines read them, as s3://bucket/prefix
#                  (default s3://pivotlake-benchmarks/<suite>); they need the
#                  AWS CLI (aws) with credentials for the bucket
#   PIVOT_BINARY   run a pivot you built instead of the latest release
#   BENCH_TIMEOUT  seconds the whole power run may take (default 3600)

set -e

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
suite="$(basename "$PWD")"

# Every directory with an install script is an engine; the -s3 ones run only
# when named.
all_engines=()
local_engines=()
for script in */install; do
    engine="$(dirname "$script")"
    all_engines+=("$engine")
    [[ $engine == *-s3 ]] || local_engines+=("$engine")
done

usage() {
    sed -n '3,25p' "$lib/run-all.sh" | sed 's/^# \{0,1\}//' >&2
    echo "  $suite engines (default: all but the -s3 ones): ${all_engines[*]}" >&2
    exit 1
}

# The credentials the AWS CLI resolves, as export lines.
aws_credentials() {
    aws configure export-credentials --format env 2>/dev/null && return   # AWS CLI v2
    python3 - <<'PY'   # v1: its botocore resolves the same chain
import botocore.session
c = botocore.session.get_session().get_credentials().get_frozen_credentials()
print(f"export AWS_ACCESS_KEY_ID={c.access_key} AWS_SECRET_ACCESS_KEY={c.secret_key}")
if c.token:
    print(f"export AWS_SESSION_TOKEN={c.token}")
PY
}

[ $# -ge 1 ] || usage
sf="$1"
shift
engines=("$@")
[ ${#engines[@]} -gt 0 ] || engines=("${local_engines[@]}")
s3_engines=()
for engine in "${engines[@]}"; do
    [ -f "$engine/install" ] || { echo "unknown engine: $engine" >&2; usage; }
    [[ $engine != *-s3 ]] || s3_engines+=("$engine")
done
data_dir="${DATA_DIR:-$PWD/datasets}"
dataset="$data_dir/sf$sf"
s3_dataset="${S3_DATA:-s3://pivotlake-benchmarks/$suite}/sf$sf"
results="$PWD/results/sf$sf"

if [ ${#s3_engines[@]} -gt 0 ]; then
    command -v aws >/dev/null ||
        { echo "${s3_engines[*]}: reading $s3_dataset needs the AWS CLI (aws)" >&2; exit 1; }
    # The -s3 engines read the bucket with AWS_ACCESS_KEY_ID and
    # AWS_SECRET_ACCESS_KEY (and AWS_SESSION_TOKEN) from the environment, in
    # the bucket's region.
    [ -n "${AWS_ACCESS_KEY_ID:-}" ] || eval "$(aws_credentials)"
    bucket="${s3_dataset#s3://}"
    AWS_REGION="$(aws s3api get-bucket-location --bucket "${bucket%%/*}" --output text)"
    [ "$AWS_REGION" != None ] || AWS_REGION=us-east-1   # how S3 spells it
    export AWS_REGION BENCH_S3="$s3_dataset"
fi

# The local engines need the dataset on disk; the -s3 ones need it in the
# bucket, uploaded from the disk once (sync skips what is already there).
if [ ! -d "$dataset" ] &&
   { [ ${#s3_engines[@]} -lt ${#engines[@]} ] || ! aws s3 ls "$s3_dataset/" >/dev/null 2>&1; }; then
    data/generate.sh "$sf" "$data_dir/generated-sf$sf"
    "$lib/pivot-style.sh" pivot/create.sql "$data_dir/generated-sf$sf" "$dataset"
fi
if [ ${#s3_engines[@]} -gt 0 ] && [ -d "$dataset" ]; then
    echo "uploading $dataset to $s3_dataset"
    aws s3 sync --only-show-errors "$dataset" "$s3_dataset"
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
