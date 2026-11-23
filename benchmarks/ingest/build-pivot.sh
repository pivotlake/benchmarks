#!/bin/bash
#
# build-pivot.sh - build the pivot server from a branch, tag or commit of its
# repository and print where the binary is, for PIVOT_BINARY. The build's
# output goes to stderr; a build takes a quarter of an hour or more.
#
# Usage: ./build-pivot.sh <branch, tag or commit> [repository, default pivotlake/pivot]

set -euo pipefail
cd "$(dirname "$0")"

ref="$1"
repository="${2:-pivotlake/pivot}"
{
    sudo apt-get update -y
    sudo apt-get install -y build-essential cmake clang libclang-dev pkg-config git ca-certificates
    source ../lib/install-rust.sh

    rm -rf pivot-source
    git clone "https://github.com/$repository.git" pivot-source
    git -C pivot-source checkout "$ref"
    git -C pivot-source submodule update --init --recursive
    # The repository pins its toolchain; rustup installs it on the first cargo call.
    (cd pivot-source && cargo build --release -p bin --bin pivot)
} >&2
echo "$PWD/pivot-source/target/release/pivot"
