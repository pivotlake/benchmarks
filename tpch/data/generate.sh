#!/bin/bash
#
# generate.sh - generate the TPC-H tables at a scale factor with tpchgen-cli,
# as parquet, one directory per table (<dir>/<table>/<table>.N.parquet):
# SNAPPY, 7 MiB row groups. SF1000 is ~396 GB and takes ~2.5 minutes on 192
# cores.
#
# Usage: ./generate.sh <scale factor> <output dir>

set -eu

sf="$1"
out="$2"

# Pinned, so a scale factor always yields the same files. --locked: an
# unlocked resolve pulls a tpchgen-arrow that fails to build.
source "$(dirname "$0")/../../lib/install-rust.sh"
if ! tpchgen-cli --version 2>/dev/null | grep -qx "tpchgen 2.0.1"; then
    cargo install tpchgen-cli --version 2.0.1 --locked
fi

rm -rf "$out"
tpchgen-cli --scale-factor "$sf" --format parquet --parts 10 --output-dir "$out"
