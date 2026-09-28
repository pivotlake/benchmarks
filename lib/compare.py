#!/usr/bin/env python3
"""Compare benchmark logs, one log per engine, in either of two formats.

Power runs (lib/power-run.sh): a log holds "Power run: <s>" (null when the run
failed), then "qNN <s>" for each query, plus "Load time: <s>" and
"Data size: <bytes>". The power-run time, one pass over every query from a
cold start, is the score. Prints each query's time per engine, then the
engines ranked by power-run time.

Tries (ClickBench's harness): a log holds one "[t1,t2,t3]," line per
query, in query order, maybe after the query's name (null for a try that
failed), plus "Load time" and "Data size". The first try is the cold time, the
best of the others the hot time. Prints each query's hot time per engine, then
a summary per engine: totals, and ClickBench's score, the geometric mean over
queries of (time + 10ms) / (fastest engine's time + 10ms), so 1.00 means
fastest on every query. Totals and scores cover only the queries every engine
completed, so they compare like with like.

Usage: compare.py <engine>.log ...   (the engine's name is the file's name)
"""

import json
import math
import pathlib
import re
import sys


def parse(path):
    log = {"tries": [], "power_run": False, "power": None, "queries": {}, "load": None, "size": None}
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        tries = re.fullmatch(r"(?:\w+ )?(\[(?:null|[0-9.]+)(?:,(?:null|[0-9.]+))*\]),?", line)
        query = re.fullmatch(r"(q\d+) ([0-9.]+)", line)
        if tries:
            log["tries"].append(json.loads(tries.group(1)))
        elif query:
            log["queries"][query.group(1)] = float(query.group(2))
        elif line.startswith("Power run:"):
            log["power_run"] = True
            value = line.split(":")[1].strip()
            log["power"] = None if value == "null" else float(value)
        elif line.startswith("Load time:"):
            log["load"] = float(line.split(":")[1])
        elif line.startswith("Data size:"):
            log["size"] = int(line.split(":")[1])
    return log


def text(value, digits=3):
    return "-" if value is None else f"{value:.{digits}f}"


def load_and_size(log):
    size = None if log["size"] is None else log["size"] / 1e9
    return f"{text(log['load'], 0):>10}{text(size, 1):>11}"


def compare_power(engines, width):
    names = sorted({q for log in engines.values() for q in log["queries"]})
    print("power run: each query's time (s) within the one pass")
    print("query" + "".join(f"{name:>{width}}" for name in engines))
    for q in names:
        print(f"{q:>5}" + "".join(f"{text(log['queries'].get(q)):>{width}}" for log in engines.values()))

    fastest = min((log["power"] for log in engines.values() if log["power"] is not None), default=None)
    print()
    print("score: power-run time, cold start to the end of the last query (lower is better)")
    print(f"{'engine':<{width}}{'power run (s)':>14}{'vs fastest':>12}{'queries':>9}{'load (s)':>10}{'size (GB)':>11}")
    ranked = sorted(engines.items(), key=lambda e: (e[1]["power"] is None, e[1]["power"] or 0))
    for name, log in ranked:
        ratio = None if log["power"] is None else log["power"] / fastest
        ratio_text = "-" if ratio is None else f"{ratio:.2f}x"
        print(f"{name:<{width}}{text(log['power']):>14}{ratio_text:>12}"
              f"{len(log['queries']):>5}/{len(names):<3}{load_and_size(log)}")


def compare_tries(engines, width):
    query_count = max(len(log["tries"]) for log in engines.values())

    def cold(tries):
        return tries[0]

    def hot(tries):
        rest = [t for t in tries[1:] if t is not None]
        return min(rest) if rest and tries[0] is not None else None

    times = {
        metric: {name: [(f(log["tries"][q]) if q < len(log["tries"]) else None) for q in range(query_count)]
                 for name, log in engines.items()}
        for metric, f in (("cold", cold), ("hot", hot))
    }
    complete = [q for q in range(query_count)
                if all(times["hot"][name][q] is not None for name in engines)]

    print("hot times (s), best of tries 2+")
    print("query" + "".join(f"{name:>{width}}" for name in engines))
    for q in range(query_count):
        print(f"{q + 1:>5}" + "".join(f"{text(times['hot'][name][q]):>{width}}" for name in engines))

    def score(metric, name):
        ratios = [math.log((times[metric][name][q] + 0.01) /
                           (min(times[metric][other][q] for other in engines) + 0.01))
                  for q in complete]
        return math.exp(sum(ratios) / len(ratios)) if ratios else float("nan")

    print()
    print(f"summary over the {len(complete)} of {query_count} queries every engine completed")
    print(f"{'engine':<{width}}{'completed':>10}{'cold total':>12}{'hot total':>11}"
          f"{'cold score':>12}{'hot score':>11}{'load (s)':>10}{'size (GB)':>11}")
    for name, log in sorted(engines.items(), key=lambda e: score("hot", e[0])):
        completed = sum(t is not None for t in times["hot"][name])
        cold_total = sum(times["cold"][name][q] for q in complete)
        hot_total = sum(times["hot"][name][q] for q in complete)
        print(f"{name:<{width}}{completed:>6}/{query_count:<3}{cold_total:>12.2f}{hot_total:>11.2f}"
              f"{score('cold', name):>12.2f}{score('hot', name):>11.2f}{load_and_size(log)}")


engines = {pathlib.Path(p).stem: parse(pathlib.Path(p)) for p in sys.argv[1:]}
width = max(len(name) for name in engines) + 2
if any(log["power_run"] for log in engines.values()):
    compare_power(engines, width)
else:
    compare_tries(engines, width)
