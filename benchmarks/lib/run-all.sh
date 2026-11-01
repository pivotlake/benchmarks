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
# The <engine>-s3 engines read the same files in the bucket DATASETS_URL
# names, where lib/dataset.sh keeps them, instead of the local disk. They run
# only when named. Everything an engine stores (its tables, its spill files)
# stays in its own directory, so a checkout on an NVMe mount keeps the whole
# run on it.
#
# Usage: ./run-all.sh <scale factor> [engine ...]
#   DATA_DIR       where datasets go (default ./datasets)
#   DATASETS_URL   fetch datasets from <url>/<suite>/sf<N> instead of generating,
#                  when there is one (see lib/dataset.sh); the -s3 engines read
#                  that dataset in place, so they need it (s3://pivotbench/datasets)
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

# The credentials the AWS CLI resolves, as export lines (nothing when it
# resolves none).
aws_credentials() {
    aws configure export-credentials --format env 2>/dev/null && return   # AWS CLI v2
    python3 - 2>/dev/null <<'PY'   # v1: its botocore resolves the same chain
import botocore.session
creds = botocore.session.get_session().get_credentials()
if creds:
    c = creds.get_frozen_credentials()
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
local_wanted=no
for engine in "${engines[@]}"; do
    [ -f "$engine/install" ] || { echo "unknown engine: $engine" >&2; usage; }
    if [[ $engine == *-s3 ]]; then s3_engines+=("$engine"); else local_wanted=yes; fi
done
data_dir="${DATA_DIR:-$PWD/datasets}"
dataset="$data_dir/sf$sf"
results="$PWD/results/sf$sf"

# The -s3 engines read the dataset lib/dataset.sh built at
# $DATASETS_URL/<suite>/sf<N> (its manifest says it is all there), in the
# bucket's region, with the credentials the AWS CLI resolves, exported for the
# engines that take them from the environment. With none anywhere the bucket
# must be public, and the CLI and the engines read it unsigned
# (BENCH_S3_ANONYMOUS; pivot-s3 cannot, it writes its datastore there). A
# scale factor the bucket lacks is dataset.sh's job, not the run's.
if [ ${#s3_engines[@]} -gt 0 ]; then
    [ -n "${DATASETS_URL:-}" ] ||
        { echo "${s3_engines[*]}: set DATASETS_URL to the bucket holding the datasets (s3://pivotbench/datasets)" >&2; exit 1; }
    s3_dataset="${DATASETS_URL%/}/$suite/sf$sf"
    command -v aws >/dev/null ||
        { echo "${s3_engines[*]}: reading $s3_dataset needs the AWS CLI (aws)" >&2; exit 1; }
    [ -n "${AWS_ACCESS_KEY_ID:-}" ] || eval "$(aws_credentials)"
    sign=()
    [ -n "${AWS_ACCESS_KEY_ID:-}" ] || { export BENCH_S3_ANONYMOUS=yes; sign=(--no-sign-request); }
    aws s3 cp "${sign[@]}" "$s3_dataset/manifest.json" - >/dev/null 2>&1 ||
        { echo "no dataset at $s3_dataset${BENCH_S3_ANONYMOUS:+ (or none readable without credentials)}: build it with $lib/dataset.sh build $PWD $sf $s3_dataset" >&2; exit 1; }
    bucket="${s3_dataset#s3://}"
    bucket="${bucket%%/*}"
    # HeadBucket names the region and needs only ListBucket.
    AWS_REGION=$(aws s3api head-bucket "${sign[@]}" --bucket "$bucket" --query BucketRegion --output text 2>/dev/null) || AWS_REGION=""
    [ -n "$AWS_REGION" ] && [ "$AWS_REGION" != None ] ||
        AWS_REGION=$(curl -sI "https://$bucket.s3.amazonaws.com/" | tr -d '\r' | awk 'tolower($1) == "x-amz-bucket-region:" { print $2 }')
    export AWS_REGION="${AWS_REGION:-us-east-1}" BENCH_S3="$s3_dataset"
fi

# The local engines' dataset: from S3 when DATASETS_URL names a bucket that
# has it (built there by lib/dataset.sh), generated and rewritten here
# otherwise.
if [ "$local_wanted" = yes ] && [ ! -d "$dataset" ]; then
    if [ -z "${DATASETS_URL:-}" ] || ! "$lib/dataset.sh" fetch "$PWD" "$sf" "$dataset" "$DATASETS_URL/$suite/sf$sf"; then
        data/generate.sh "$sf" "$data_dir/generated-sf$sf"
        "$lib/pivot-style.sh" pivot/create.sql "$data_dir/generated-sf$sf" "$dataset"
    fi
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
