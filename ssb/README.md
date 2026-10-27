# Star Schema Benchmark

The 13 SSB queries on the same engines as `../tpch` (its seven local ones and
the five that read the same files from S3), all reading the same rows:
`lineorder` joined to its four dimensions (`customer`, `supplier`, `part`,
`date`), in four flights of increasing dimensionality.

| engine | reads |
|---|---|
| `pivot` | the parquet files in place |
| `duckdb` | its own database file, loaded from the parquet files |
| `duckdb-parquet` | the parquet files in place |
| `clickhouse` | MergeTree tables ordered by the same primary keys, loaded from the parquet files and merged with `OPTIMIZE FINAL` |
| `clickhouse-parquet` | the parquet files in place (`clickhouse-local`) |
| `datafusion` | the parquet files in place (`datafusion-cli`) |
| `spark` | the parquet files in place (PySpark, one local session for the whole power run) |
| `pivot-s3`, `duckdb-s3`, `clickhouse-s3`, `datafusion-s3`, `spark-s3` | the same parquet files in an S3 bucket, each the way its local counterpart reads them in place |

```sh
./run-all.sh 100                                   # all local engines at SF100
./run-all.sh 1000 pivot duckdb clickhouse          # some engines at SF1000
./run-all.sh 100 pivot-s3 duckdb-s3 clickhouse-s3 datafusion-s3 spark-s3   # over S3
PIVOT_BINARY=~/pivot/target/release/pivot ./run-all.sh 100 pivot
```

It runs exactly like `../tpch` (see its README): a power run, the 13 queries
back to back in one session from a cold start, timed end to end, with the same
engine scripts, driver and comparison, and this suite's schema, queries and
generator. The `-s3` engines read `s3://pivotlake-benchmarks/ssb/sf<N>` (or
`S3_DATA=s3://bucket/prefix`), which holds SF1 (the first `-s3` run at
another scale factor adds it), the way the TPC-H README's
[Reading from S3](../tpch/README.md#reading-from-s3) describes.

## Data

`data/generate.sh` builds ssb-dbgen (eyalroz/ssb-dbgen, pinned to a commit so
a scale factor always gives the same rows), generates the tables, `lineorder`
in parallel chunks, one per core, and converts them to parquet with DuckDB
using the column types in `pivot/create.sql`. `../lib/pivot-style.sh` then
rewrites them into the files pivot itself writes, sorted by each table's
primary key (`lo_orderkey, lo_linenumber` for `lineorder`), and every engine
reads those.

The schema follows the SSB spec: integer money values, `yyyymmdd` integer date
keys joined against the `date` dimension, BIGINT keys. SF1000's `lineorder`
has 6 billion rows.

## Queries

`queries/` holds the official texts (O'Neil et al.) with their default
substitution parameters; `q11.sql` is Q1.1, `q43.sql` is Q4.3. Q3.1-Q3.4 also
sort by their group keys after `revenue desc`, so tied revenues come back in
one order.
