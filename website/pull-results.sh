#!/usr/bin/env bash
# Pulls the current results from S3 and bakes data.js: what Deploy Web does
# before publishing, and how to see the live results locally.
#
# s3://<bucket>/latest/ mirrors results/ one to one, a file per result, which
# the Benchmark workflow overwrites with every run that succeeds, so a sync
# of it is the website's data. Needs AWS credentials that can read the bucket.
#
# Usage: ./pull-results.sh [bucket]    (default: $RESULTS_BUCKET)
set -euo pipefail
cd "$(dirname "$0")"

bucket="${1:-${RESULTS_BUCKET:-}}"
[ -n "$bucket" ] || { echo "usage: pull-results.sh <bucket>  (or set RESULTS_BUCKET)" >&2; exit 1; }

aws s3 sync --delete --exclude '*' --include '*.json' "s3://$bucket/latest/" results/
./generate-results.sh
