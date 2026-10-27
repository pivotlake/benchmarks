# pivot benchmarks

Pivot against other engines, on the same machine and the same data, with
scripts short enough to read. Each benchmark has a `run-all.sh` that runs every
engine and prints one comparison:

- [`tpch/`](tpch): TPC-H at any scale factor (SF100 and SF1000 are the usual
  ones), on parquet files written by pivot, on local disk and in S3.
- [`ssb/`](ssb): the Star Schema Benchmark on the same kind of data.
- [`clickbench/`](clickbench): ClickBench, through ClickBench's own harness
  (our fork, which carries the pivot entries, as a submodule).

TPC-H and SSB are scored as a power run: after loading, each engine is
restarted with the page cache dropped, then runs every query back to back in
one session (one process for the embedded engines, one connection for the
servers), timed end to end. The comparison ranks the engines by that time and
prints each query's time within the run.

ClickBench is scored its own way: each query runs three times after restarting
the engine and dropping the page cache; the first try is the cold time, the
best of the other two the hot time. The comparison prints every engine's hot
time per query, then cold and hot totals and ClickBench's score (the geometric
mean over queries of `(time + 10ms) / (fastest engine's time + 10ms)`; 1.00 is
fastest everywhere), over the queries every engine completed.

The scripts need a Linux box with passwordless sudo (to drop caches and
install packages) and plenty of local disk.

```sh
git clone --recurse-submodules https://github.com/pivotlake/benchmarks.git
cd benchmarks
tpch/run-all.sh 100                  # every local engine at TPC-H SF100
ssb/run-all.sh 1000 pivot duckdb     # two engines at SSB SF1000
tpch/run-all.sh 1000 pivot-s3 duckdb-s3   # two engines over the files in S3
clickbench/run-all.sh                # the default ClickBench systems
```

The engines that read the parquet files in place (pivot, DuckDB, ClickHouse,
DataFusion and Spark) also come as `<engine>-s3`, reading the same files from
an S3 bucket in us-east-1 (`s3://pivotlake-benchmarks`, which holds the usual
scale factors; `S3_DATA` names another); `tpch/README.md` has the details.

`tpch/` and `ssb/` each hold their queries, a data generator and one directory
per engine with ClickBench's small scripts plus `power`; `lib/` holds what they
share: the power-run driver (`power-run.sh`), `run-all.sh`, the pivot-style
rewrite of the data and the comparison.

The released pivot is installed with `curl https://pivotlake.io | sh`; set
`PIVOT_BINARY=/path/to/pivot` to benchmark a build of your own instead (TPC-H
and SSB).
