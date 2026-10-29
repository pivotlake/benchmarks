#!/bin/bash
#
# dataset.sh - keep a suite's datasets in S3, so a benchmark machine downloads
# one in minutes instead of generating and rewriting it for an hour.
#
#   dataset.sh build <suite dir> <scale factor> <s3 url>
#       Generate the dataset (the suite's data/generate.sh), rewrite it into
#       the parquet files pivot writes (pivot-style.sh) and upload it to the
#       url: <table>/*.parquet per table, then manifest.json, written last so
#       its presence means the upload is complete. Needs a lot of local disk.
#
#   dataset.sh fetch <suite dir> <scale factor> <dest dir> <s3 url>
#       Download a dataset that has a manifest into <dest dir>. Exits 1,
#       with nothing downloaded, if there is none at the url.
#
# The url is <datasets url>/<suite>/sf<N>, e.g. s3://pivotbench/datasets/tpch/sf1000;
# run-all.sh fetches from $DATASETS_URL when it is set and builds otherwise.
# Needs AWS credentials that can read (and for build, write) the bucket.

set -euo pipefail
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '3,19p' "$lib/dataset.sh" | sed 's/^# \{0,1\}//' >&2; exit 1; }

case "${1:-}" in
build)
    [ $# -eq 4 ] || usage
    suite="$2" sf="$3" url="${4%/}"
    # Prove the upload will work before the hour of building: the sync needs
    # to list the prefix and write to it. (`aws s3 ls` of an empty prefix
    # exits 1 silently, so only an error message counts as a failure.)
    denied=$(aws s3 ls "$url/" 2>&1 >/dev/null) || true
    [ -z "$denied" ] && echo probe | aws s3 cp - "$url/.probe" && aws s3 rm --quiet "$url/.probe" ||
        { echo "cannot list and write $url with these credentials: ${denied:-the probe write or delete failed}; nothing built" >&2; exit 1; }
    cd "$suite"
    work="$PWD/datasets"
    generated="$work/generated-sf$sf" out="$work/sf$sf"
    start=$(date +%s)
    [ -d "$out" ] || {
        data/generate.sh "$sf" "$generated"
        "$lib/pivot-style.sh" pivot/create.sql "$generated" "$out"
        rm -rf "$generated"
    }
    built=$(date +%s)
    echo "uploading $(du -sh "$out" | cut -f1) to $url"
    aws s3 sync --only-show-errors --delete --exclude manifest.json "$out/" "$url/"
    pivot_version=$("${PIVOT_BINARY:-$HOME/.pivot/cli/latest/pivot}" --version 2>/dev/null | head -n1 || echo unknown)
    jq -n --arg suite "$(basename "$PWD")" --argjson sf "$sf" --arg pivot "$pivot_version" \
          --arg generator "$(grep -oE '(tpchgen|ssb-dbgen)[ -][0-9][0-9a-f.]*' data/generate.sh | head -n1 || echo unknown)" \
          --argjson bytes "$(du -sb "$out" | cut -f1)" --argjson files "$(find "$out" -name '*.parquet' | wc -l)" \
          --arg date "$(date -u +%F)" --arg machine "$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" http://169.254.169.254/latest/meta-data/instance-type || hostname)" \
          --argjson build_seconds "$(( built - start ))" \
          '{suite: $suite, scale_factor: $sf, pivot: $pivot, generator: $generator, bytes: $bytes, files: $files, date: $date, machine: $machine, build_seconds: $build_seconds}' |
        aws s3 cp - "$url/manifest.json"
    echo "built in $(( built - start ))s, uploaded in $(( $(date +%s) - built ))s"
    ;;
fetch)
    [ $# -eq 5 ] || usage
    suite="$2" sf="$3" dest="$4" url="${5%/}"
    manifest=$(aws s3 cp "$url/manifest.json" - 2>/dev/null) || { echo "no dataset at $url" >&2; exit 1; }
    echo "fetching $(jq -r '"\(.bytes / 1e9 | floor) GB, \(.files) files, built \(.date) with \(.pivot)"' <<< "$manifest") from $url"
    start=$(date +%s)
    mkdir -p "$dest"
    aws s3 sync --only-show-errors --exclude manifest.json "$url/" "$dest/"
    echo "fetched in $(( $(date +%s) - start ))s"
    ;;
*)
    usage
    ;;
esac
