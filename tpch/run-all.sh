#!/bin/bash
# Run TPC-H on every engine and compare them; see ../lib/run-all.sh.
# Usage: ./run-all.sh <scale factor> [engine ...]
cd "$(dirname "$0")" && exec ../lib/run-all.sh "$@"
