#!/usr/bin/env python3
"""Turn benchmark logs into the website's result files.

One JSON per log, at <out>/<benchmark>/<engine>/<machine>[.sf<N>].json, in the
shape website/index.html reads (see website/results/ for examples): the
engine's display name and tags, the machine, the date, load time and data
size, and the times. A TPC-H or SSB log (lib/power-run.sh) gives "power_run"
and one time per query; a ClickBench log gives the three tries per query.
A log with nothing measured (the engine never installed, say) is skipped.

Usage: results-json.py --benchmark tpch|ssb|clickbench --machine <name>
                       [--sf <N>] [--date YYYY-MM-DD] [--out <dir>] <log>...
The engine is the log's file name (results/sf100/duckdb.log is duckdb).
"""

import argparse
import datetime
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import compare  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Engine directory -> display name and tags, for the website's selectors.
ENGINES = {
    "pivot": ("pivot", ["Rust", "column-oriented", "Parquet", "stateless"]),
    "pivot-parquet-partitioned": ("pivot (Parquet, partitioned)", ["Rust", "column-oriented", "Parquet", "stateless"]),
    "duckdb": ("DuckDB", ["C++", "column-oriented", "embedded"]),
    "duckdb-parquet": ("DuckDB (Parquet)", ["C++", "column-oriented", "embedded", "Parquet", "stateless"]),
    "duckdb-parquet-partitioned": ("DuckDB (Parquet, partitioned)", ["C++", "column-oriented", "embedded", "Parquet", "stateless"]),
    "clickhouse": ("ClickHouse", ["C++", "column-oriented"]),
    "clickhouse-parquet": ("ClickHouse (Parquet)", ["C++", "column-oriented", "Parquet", "stateless"]),
    "clickhouse-parquet-partitioned": ("ClickHouse (Parquet, partitioned)", ["C++", "column-oriented", "Parquet", "stateless"]),
    "datafusion": ("DataFusion", ["Rust", "column-oriented", "embedded", "Parquet", "stateless"]),
    "datafusion-partitioned": ("DataFusion (Parquet, partitioned)", ["Rust", "column-oriented", "embedded", "Parquet", "stateless"]),
    "spark": ("Apache Spark", ["Java", "column-oriented", "Parquet", "stateless"]),
    "starrocks": ("StarRocks", ["C++", "column-oriented"]),
}
CLICKBENCH_NAMES = {"spark": "Apache Spark (Parquet, single)"}
CLICKBENCH_QUERIES = 43


def entry(benchmark, engine, log, machine, sf, date):
    name, tags = ENGINES.get(engine, (engine, []))
    if benchmark == "clickbench":
        name = CLICKBENCH_NAMES.get(engine, name)
    result = {
        "benchmark": benchmark,
        "system": name,
        "date": date,
        "machine": machine,
        "tags": tags,
        "comment": "",
        "load_time": log["load"] if log["load"] is not None else 0,
        "data_size": log["size"],
    }
    if benchmark == "clickbench":
        tries = [[None if t is None else float(t) for t in t3] for t3 in log["tries"]]
        tries += [[None, None, None]] * (CLICKBENCH_QUERIES - len(tries))
        result["result"] = tries[:CLICKBENCH_QUERIES]
    else:
        names = sorted(f.stem for f in (ROOT / benchmark / "queries").glob("q*.sql"))
        result["scale_factor"] = sf
        result["result"] = [log["queries"].get(q) for q in names]
        result["power_run"] = log["power"]
    return result


def main():
    args = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    args.add_argument("--benchmark", required=True, choices=["tpch", "ssb", "clickbench"])
    args.add_argument("--machine", required=True)
    args.add_argument("--sf", type=int, help="scale factor (TPC-H and SSB)")
    args.add_argument("--date", default=datetime.date.today().isoformat())
    args.add_argument("--out", default=str(ROOT.parent / "website" / "results"))
    args.add_argument("logs", nargs="+")
    a = args.parse_args()
    if a.benchmark != "clickbench" and a.sf is None:
        args.error(f"--sf is required for {a.benchmark}")

    written = []
    for path in map(pathlib.Path, a.logs):
        log = compare.parse(path)
        measured = log["tries"] or log["queries"] or log["power_run"] or log["load"] is not None or log["size"] is not None
        if not measured:
            print(f"{path}: nothing measured, skipped", file=sys.stderr)
            continue
        suffix = f".sf{a.sf}" if a.benchmark != "clickbench" else ""
        out = pathlib.Path(a.out) / a.benchmark / path.stem / f"{a.machine}{suffix}.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(entry(a.benchmark, path.stem, log, a.machine, a.sf, a.date), indent=4) + "\n")
        written.append(out)
        print(out)
    if not written:
        sys.exit(1)


if __name__ == "__main__":
    main()
