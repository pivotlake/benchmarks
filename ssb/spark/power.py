#!/usr/bin/env python3
"""Runs the query files given as arguments, in order, in ONE local PySpark
session over one view per table directory in $BENCH_DATA, configured the way
ClickBench's spark entry configures it. Stdout: each query's runtime in
seconds, one per line. Exits non-zero at the first failing query.

Each runtime covers the query and collecting its whole result: ClickBench's
show(100) would let Spark stop after 100 rows where every other engine
produces them all.
"""

import os
import pathlib
import sys
import timeit

import psutil
from pyspark.sql import SparkSession

# 70% of the available memory for the driver, which runs everything in local
# mode, as ClickBench configures it; spills go to $TMPDIR (the engine's
# directory, on the disk being measured) rather than /tmp.
memory_mb = int(psutil.virtual_memory().available / 2**20 * 0.7)
spark = (
    SparkSession.builder
    .appName("pivot-benchmarks")
    .master("local[*]")
    .config("spark.driver.memory", f"{memory_mb}m")
    .config("spark.local.dir", os.environ["TMPDIR"])
    # The progress bar redraws itself on stderr with carriage returns.
    .config("spark.ui.showConsoleProgress", "false")
    .getOrCreate()
)
spark.sparkContext.setLogLevel("ERROR")

for table in sorted(pathlib.Path(os.environ["BENCH_DATA"]).iterdir()):
    spark.read.parquet(str(table)).createOrReplaceTempView(table.name)

for path in sys.argv[1:]:
    query = pathlib.Path(path).read_text().strip().rstrip(";")
    try:
        start = timeit.default_timer()
        spark.sql(query).collect()
        elapsed = timeit.default_timer() - start
    except Exception as error:
        print(f"{path}: {error}", file=sys.stderr)
        sys.exit(1)
    print(f"{elapsed:.6f}", flush=True)
