#!/usr/bin/env python3
"""Runs the query files given as arguments, in order, in ONE local PySpark
session over one view per table directory in $BENCH_S3 (the tables tables.txt
names), configured the way ClickBench's spark entry configures it, plus
Hadoop's S3A connector reading the bucket with the keys and region in the
environment. Stdout: each query's runtime in seconds, one per line. Exits
non-zero at the first failing query.

Each runtime covers the query and collecting its whole result: ClickBench's
show(100) would let Spark stop after 100 rows where every other engine
produces them all.
"""

import os
import pathlib
import sys
import timeit

import psutil
import pyspark
from pyspark.sql import SparkSession

# The JVM shares this process's stdout and reports the connector's download on
# it: keep stdout for the times and send everything else to stderr.
times = os.fdopen(os.dup(1), "w")
os.dup2(2, 1)

# The S3A connector of the Hadoop that PySpark bundles, fetched from Maven into
# ./ivy (./load runs a session first, so the download precedes the power run).
jars = pathlib.Path(pyspark.__file__).parent / "jars"
hadoop = next(jars.glob("hadoop-client-api-*.jar")).stem.rsplit("-", 1)[1]

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
    .config("spark.jars.packages", f"org.apache.hadoop:hadoop-aws:{hadoop}")
    .config("spark.jars.ivy", str(pathlib.Path("ivy").resolve()))
    .config("spark.hadoop.fs.s3a.endpoint.region", os.environ["AWS_REGION"])
    # The progress bar redraws itself on stderr with carriage returns.
    .config("spark.ui.showConsoleProgress", "false")
    .getOrCreate()
)
spark.sparkContext.setLogLevel("ERROR")

dataset = "s3a://" + os.environ["BENCH_S3"].removeprefix("s3://")
for table in pathlib.Path("tables.txt").read_text().split():
    spark.read.parquet(f"{dataset}/{table}").createOrReplaceTempView(table)

for path in sys.argv[1:]:
    query = pathlib.Path(path).read_text().strip().rstrip(";")
    try:
        start = timeit.default_timer()
        spark.sql(query).collect()
        elapsed = timeit.default_timer() - start
    except Exception as error:
        print(f"{path}: {error}", file=sys.stderr)
        sys.exit(1)
    print(f"{elapsed:.6f}", file=times, flush=True)
