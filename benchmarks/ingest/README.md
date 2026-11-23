# Ingest

How much ingest pivot sustains into a table in S3 while a query keeps running
against it. Pivot only: there is no comparison here, and nothing goes to the
website.

A run starts a pivot server over a new, empty lake in S3, creates a table of
logs and inserts into it at each load you name, one after the other on the
same table. A load is a number of inserts per second and the size of one
insert, so `100x1MiB` is a hundred inserts of 1 MiB every second and
`2000x4KiB` two thousand of 4 KiB. Meanwhile one connection runs
[`query.sql`](query.sql) again and again over the most recent rows.

Every step is judged by what changes while it runs, so a step takes minutes:

| column | what it says |
|---|---|
| `MiB/s asked`, `MiB/s done`, `inserts/s` | whether the inserts reached the rate asked for |
| `insert ms` | how long one insert took, from sending it to its commit |
| `query ms` | how long the query took |
| `live files`, `files/min` | the table's data files at the end of the step, and how fast their count changed during it: merging keeps pace with the inserts when it stays level |
| `machine busy %`, `server cores`, `loader cores` | how much of the machine's CPU was in use, and the cores the server and the loader each used |
| `pool pinned MiB` | the part of the buffer pool the server's operators pinned, which only they give back: at the end of the step, its mean and peak, and how fast it changed |
| `pool cached MiB` | the part of the pool the server's caches filled, which the pool takes back when it runs short |
| `outside pool MiB` | the server's memory outside its buffer pool: at the end of the step, its peak, and how fast it changed |

A load the server sustains has its rate reached, and `files/min` and the two
`per min` columns near zero. The first step of a run also carries the server
warming up.

The pool is taken whole when the server starts, so only the server knows how
much of it is in use. The live files and the pool's use are asked of the
server every ten seconds, from `system.table_files` and
`system.memory_blocks`.

The inserts are sent over `--connections` connections, each waiting for its
insert to commit before the next: when one insert takes 300 ms, 32 connections
send at most about a hundred a second, whatever was asked. Raise
`--connections` for many small inserts.

## The table

26 columns of a log line as an observability pipeline writes it, four of them
`VARIANT` documents, partitioned by day ([`create.sql`](create.sql)). Every
insert holds rows of all 200 deployments, stamped with the time it is sent.
The table comes in two layouts, each run from scratch on a lake of its own:

| layout | sorted by | what it does to files |
|---|---|---|
| `spread` | `deployment_id`, `timestamp` | every insert's file spans the whole sort key, so every file overlaps every other |
| `ordered` | `timestamp` | every insert's file follows the one before |

## Running it

On a Linux machine with the AWS CLI, in the bucket's region, whose identity
(an EC2 instance role, or keys in the environment) may read, write, list and
delete under the lake's prefix:

```sh
./run.sh --lake s3://my-bucket/ingest-lakes                        # 100x1MiB for 5 minutes, spread layout
./run.sh --lake s3://my-bucket/ingest-lakes --layouts "spread ordered" \
    --loads "50x1MiB 100x1MiB 200x1MiB 400x1MiB" --step-seconds 300    # find where it stops keeping up
./run.sh --lake s3://my-bucket/ingest-lakes --loads "2000x4KiB" --connections 256
./run.sh --lake s3://my-bucket/ingest-lakes --query-range 0             # the query reads the whole table
PIVOT_BINARY=~/pivot/target/release/pivot ./run.sh --lake s3://my-bucket/ingest-lakes
```

`./run.sh` with no arguments lists every option. The lake is deleted when the
run ends, unless `--keep-lake`. Results are left in `results/<layout>/`:
`summary.txt` (the table), `result.json`, the server's log, the loader's log of
every insert and query per step, and the samples of memory and live files.

The Benchmark workflow runs it on an EC2 machine type of your choice: name
`ingest` under benchmarks and `pivot` under databases, pick the machines, and
give `run.sh`'s options as `ingest_options`. `pivot_ref` has the machine build
pivot from a branch, tag or commit first (`build-pivot.sh`); empty runs the
latest release. The tables are shown in the run's summary, and the results are
in the run's folder in S3 under `ingest/`.

## What is in here

- `run.sh`: the run.
- `loader/`: `logs-load`, the Rust program that inserts at a rate and runs the
  query. It generates its batches once and only stamps the time on each
  insert, so it takes little of the machine it shares with the server.
- `sample.py`: every ten seconds, the server's resident memory, the CPU time
  used, and the table's live files and the buffer pool's use from the server's
  system tables.
- `summarize.py`: the table and `result.json` from what a run left.
- `build-pivot.sh`: builds pivot from source at a branch, tag or commit.
