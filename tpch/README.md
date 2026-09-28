# TPC-H

The 22 TPC-H queries on seven engines, all reading the same rows:

| engine | reads |
|---|---|
| `pivot` | the parquet files in place |
| `duckdb` | its own database file, loaded from the parquet files |
| `duckdb-parquet` | the parquet files in place |
| `clickhouse` | MergeTree tables ordered by the same primary keys, loaded from the parquet files and merged with `OPTIMIZE FINAL` |
| `clickhouse-parquet` | the parquet files in place (`clickhouse-local`) |
| `datafusion` | the parquet files in place (`datafusion-cli`) |
| `spark` | the parquet files in place (PySpark, one local session for the whole power run) |

Every engine runs on its default settings and is installed the way ClickBench
installs it: the latest pivot and DuckDB releases, ClickHouse's latest build
from clickhouse.com, and the latest DataFusion release built from source with
LTO. Spark is the latest PySpark release on Java 17, run the way ClickBench
runs it; ClickBench pins Spark 3.5.5, whose vectorized parquet reader fails on
some of the string pages pivot writes.

```sh
./run-all.sh 100                                   # all engines at SF100
./run-all.sh 1000 pivot duckdb clickhouse          # some engines at SF1000
DATA_DIR=/mnt/nvme/tpch ./run-all.sh 1000          # datasets on another disk
PIVOT_BINARY=~/pivot/target/release/pivot ./run-all.sh 100 pivot
```

Nothing is installed system-wide beyond packages: each engine keeps its
binary, its tables (DuckDB's database file, ClickHouse's data directory,
pivot's catalog) and its spill files in its own directory. Clone the repo onto
the disk you want measured, an NVMe mount say, and the whole run stays on it.

## Data

`data/generate.sh` generates the tables with tpchgen-cli (2.0.1, pinned so a
scale factor always gives the same rows). `../lib/pivot-style.sh` then rewrites
them into the files pivot itself writes: a pivot server adopts the generated
files, copies each table into one of its own, sorted by the table's primary
key (`sort_by` in `pivot/create.sql`), with
`INSERT INTO t SELECT * FROM generated_t`, settles it with `COMPACT t FINAL`
until no two files overlap in key range, and the files each table's Delta log
names become the dataset. So every engine reads what a sorted pivot table
looks like after an INSERT (128k-row row groups, Snappy), and the engines with
their own storage load from those files.

`run-all.sh` does both once per scale factor and keeps the result in
`datasets/sf<N>`. SF1000 is ~396 GB generated and needs a few TB of disk once
the engines' own copies are loaded.

## Running: a power run

TPC-H is scored as a power run, one pass over the queries the way TPC-H's
power test runs them: after loading, the driver (`../lib/power-run.sh`) stops
the engine, drops the page cache and starts it again, then times q01 through
q22 run back to back in one session, from the first query's start to the last
one's end. That wall time is the score; each query's own time is printed too.

One session means one process for the embedded engines (a single `duckdb`,
`datafusion-cli` or `clickhouse-local` runs all 22 queries, so later queries
find what earlier ones left in its memory) and one connection for the servers
(pivot, ClickHouse). A query that fails ends the run without a score, and the
whole run may take `BENCH_TIMEOUT` seconds (default 3600).

Each engine directory has ClickBench's small scripts (`install`, `start`,
`stop`, `check`, `load`, `data-size`) plus `power`, which runs the query files
it is given in one session and prints each query's time. Logs go to
`results/sf<N>/<engine>.log`, and at the end `../lib/compare.py` ranks the
engines by power-run time.

The run takes the queries in their numbered order, q01 to q22; TPC-H's own
power test uses a permuted order and adds two refresh functions, which a
read-only parquet dataset does not have.

## Queries

`queries/` holds the official texts with their default substitution
parameters, with two changes every engine gets: q11's HAVING fraction is
`0.0001 / SF` (the driver fills in `{fraction}`), and q11 sorts by
`ps_partkey` after `value` so tied values come back in one order. q15's view
is written as a CTE.
