# ClickBench

`ClickBench/` is pivotlake's fork of ClickBench (the `pivot-parquet` branch),
which adds the pivot entries to the official harness. `run-all.sh` runs a set
of its systems one after another and compares them:

```sh
./run-all.sh                                  # the default set below
./run-all.sh pivot-parquet-partitioned duckdb # any systems in ClickBench/
```

The default set is pivot, DuckDB and DataFusion over the partitioned parquet
files, DuckDB and ClickHouse on their own storage, ClickHouse over the
partitioned parquet files, and Spark over the single parquet file (ClickBench's
only Spark entry, with its pinned Spark 3.5.5):

    pivot-parquet-partitioned  duckdb-parquet-partitioned  duckdb
    clickhouse  clickhouse-parquet-partitioned  datafusion-partitioned  spark

The dataset is downloaded once into `data/` and hard-linked into each system's
directory. Each system then runs exactly as ClickBench runs it (its own
install, load and settings), minus the concurrent-QPS test. Logs go to
`results/<system>.log`, and `../lib/compare.py` prints the hot times and the
summary at the end.
