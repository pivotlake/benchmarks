#!/usr/bin/env python3
"""Turn what one layout's run left in its results directory into two tables,
one row per step each, and result.json beside them.

Reads steps.tsv (what each step asked for and when it ran), loader-<step>.log
(a line per insert and per query run), samples.tsv (every ten seconds: the
server's resident memory, the table's live files, CPU time used and how the
buffer pool is used) and server.log (the size of the pool).

Memory is reported as the server sees it. The buffer pool is taken whole at
startup, so the operating system cannot tell how much of it is in use: the
samples hold what the server's `system.memory_blocks` says, as the bytes
operators pin, which only their holder gives back, and the bytes its caches
hold, which the pool takes back when it runs short. Memory outside the pool
is the server's resident memory less the pool.

Usage: summarize.py <results directory> --engine <name> --layout <name> --query-range <seconds> --connections <count>
"""

import argparse
import json
import os
import pathlib
import re
import statistics

parser = argparse.ArgumentParser()
parser.add_argument("results", type=pathlib.Path)
parser.add_argument("--engine", required=True)
parser.add_argument("--layout", required=True)
parser.add_argument("--query-range", type=int, required=True)
parser.add_argument("--connections", type=int, required=True)
arguments = parser.parse_args()
results = arguments.results

MEBIBYTE = 1 << 20
TICKS_PER_SECOND = os.sysconf("SC_CLK_TCK")


def pick_percentile(sorted_values, percent):
    return sorted_values[min(len(sorted_values) - 1, int(len(sorted_values) * percent / 100))]


def summarize_latencies(latencies_ms):
    if not latencies_ms:
        return None
    ordered = sorted(latencies_ms)
    return {
        "count": len(ordered),
        "mean_ms": round(statistics.fmean(ordered), 1),
        "median_ms": round(pick_percentile(ordered, 50), 1),
        "p99_ms": round(pick_percentile(ordered, 99), 1),
        "max_ms": round(ordered[-1], 1),
    }


def fit_change_per_minute(points):
    """The slope of the least-squares line through (seconds, value) points, per minute."""
    if len(points) < 2:
        return None
    mean_time = statistics.fmean(time for time, _ in points)
    mean_value = statistics.fmean(value for _, value in points)
    spread = sum((time - mean_time) ** 2 for time, _ in points)
    if spread == 0:
        return None
    return 60 * sum((time - mean_time) * (value - mean_value) for time, value in points) / spread


def summarize_bytes(points):
    """Where a series of (seconds, bytes) ended, its mean and peak, and how fast it changed, in MiB."""
    if not points:
        return None
    values = [value for _, value in points]
    change = fit_change_per_minute(points)
    return {
        "mebibytes_at_end": round(values[-1] / MEBIBYTE),
        "mebibytes_mean": round(statistics.fmean(values) / MEBIBYTE),
        "mebibytes_max": round(max(values) / MEBIBYTE),
        "mebibytes_change_per_minute": round(change / MEBIBYTE, 1) if change is not None else None,
    }


pool_bytes = None
server_log = results / "server.log"
if server_log.exists():
    found = re.search(r"pool_bytes=(\d+)", server_log.read_text(errors="replace"))
    pool_bytes = int(found.group(1)) if found else None

samples = []
samples_file = results / "samples.tsv"
if samples_file.exists():
    for line in samples_file.read_text().splitlines():
        (sampled_at, resident_kilobytes, live_files, busy, total, server_ticks, loader_ticks,
         _pool_free, pool_pinned, pool_cached, _asking_seconds) = line.split("\t")
        samples.append({
            "time": int(sampled_at),
            "resident_bytes": int(resident_kilobytes) * 1024,
            "live_files": None if live_files == "NA" else int(live_files),
            "pool_pinned_bytes": None if pool_pinned == "NA" else int(pool_pinned),
            "pool_cached_bytes": None if pool_cached == "NA" else int(pool_cached),
            "busy_ticks": int(busy),
            "total_ticks": int(total),
            "server_ticks": int(server_ticks),
            "loader_ticks": int(loader_ticks),
        })


def summarize_cpu(in_step):
    """How busy the machine was over the samples, and the cores the server and the loader used."""
    if len(in_step) < 2:
        return None
    first, last = in_step[0], in_step[-1]
    seconds = last["time"] - first["time"]
    total_ticks = last["total_ticks"] - first["total_ticks"]
    if seconds <= 0 or total_ticks <= 0:
        return None
    # Each step runs a loader of its own, whose count starts again from zero.
    loader_ticks = sum(max(0, after["loader_ticks"] - before["loader_ticks"])
                       for before, after in zip(in_step, in_step[1:]))
    return {
        "machine_busy_percent": round(100 * (last["busy_ticks"] - first["busy_ticks"]) / total_ticks, 1),
        "server_cores": round((last["server_ticks"] - first["server_ticks"]) / TICKS_PER_SECOND / seconds, 2),
        "loader_cores": round(loader_ticks / TICKS_PER_SECOND / seconds, 2),
    }


steps = []
for line in (results / "steps.tsv").read_text().splitlines():
    index, load, inserts_per_second, insert_bytes, started, ended, loader_status = line.split("\t")
    started, ended = int(started), int(ended)
    insert_latencies, insert_byte_counts, insert_starts = [], [], []
    insert_errors, first_insert_start = 0, None
    query_latencies, query_errors = [], 0
    for event in (results / f"loader-{index}.log").read_text().splitlines():
        fields = event.split(" ", 5)
        if fields[0] == "insert":
            if first_insert_start is None:
                first_insert_start = float(fields[1])
            if fields[4] == "ERROR":
                insert_errors += 1
                continue
            insert_starts.append(float(fields[1]))
            insert_latencies.append(float(fields[2]))
            insert_byte_counts.append(int(fields[3]))
        elif fields[0] == "query":
            if fields[3] == "ERROR":
                query_errors += 1
            else:
                query_latencies.append(float(fields[2]))
    # The loader generates its batches before the first insert, so the rate
    # is over the time it spent inserting.
    inserting_seconds = (ended - first_insert_start) if insert_starts else 0
    in_step = [sample for sample in samples if started <= sample["time"] <= ended]
    live_files = [(sample["time"], sample["live_files"]) for sample in in_step if sample["live_files"] is not None]
    files_per_minute = fit_change_per_minute(live_files)
    steps.append({
        "step": int(index),
        "load": load,
        "requested": {
            "inserts_per_second": float(inserts_per_second),
            "insert_bytes": int(insert_bytes),
            "mebibytes_per_second": round(float(inserts_per_second) * int(insert_bytes) / MEBIBYTE, 2),
        },
        "seconds": ended - started,
        "loader_exit_status": int(loader_status),
        "inserts": {
            "per_second": round(len(insert_starts) / inserting_seconds, 2) if inserting_seconds else 0,
            "mebibytes_per_second": round(sum(insert_byte_counts) / MEBIBYTE / inserting_seconds, 2) if inserting_seconds else 0,
            "latency": summarize_latencies(insert_latencies),
            "errors": insert_errors,
        },
        "query": {"latency": summarize_latencies(query_latencies), "errors": query_errors},
        "live_files": {
            "at_end": live_files[-1][1] if live_files else None,
            "change_per_minute": round(files_per_minute, 1) if files_per_minute is not None else None,
        },
        "cpu": summarize_cpu(in_step),
        "buffer_pool": {
            "pinned": summarize_bytes([(sample["time"], sample["pool_pinned_bytes"]) for sample in in_step
                                       if sample["pool_pinned_bytes"] is not None]),
            "cached": summarize_bytes([(sample["time"], sample["pool_cached_bytes"]) for sample in in_step
                                       if sample["pool_cached_bytes"] is not None]),
        },
        "resident_memory": summarize_bytes([(sample["time"], sample["resident_bytes"]) for sample in in_step]),
        "memory_outside_pool": summarize_bytes(
            [(sample["time"], sample["resident_bytes"] - pool_bytes) for sample in in_step] if pool_bytes else []),
    })

result = {
    "benchmark": "ingest",
    "engine": arguments.engine,
    "layout": arguments.layout,
    "query_range_seconds": arguments.query_range,
    "connections": arguments.connections,
    "buffer_pool_bytes": pool_bytes,
    "steps": steps,
}
(results / "result.json").write_text(json.dumps(result, indent=2) + "\n")


def show(value, suffix=""):
    return "-" if value is None else f"{value}{suffix}"


def show_latency(latency):
    if latency is None:
        return ["-"] * 4
    return [f"{latency[name]:.0f}" for name in ("mean_ms", "median_ms", "p99_ms", "max_ms")]


def show_bytes(summary, names):
    return ["-" if summary is None else show(summary[name]) for name in names]


def print_table(rows):
    widths = [max(len(row[column]) for row in rows) for column in range(len(rows[0]))]
    for row in rows:
        print("  ".join(cell.rjust(width) for cell, width in zip(row, widths)))


print(f"ingest, {arguments.engine}, {arguments.layout} layout, query over the last "
      f"{arguments.query_range or 'all'} seconds, {arguments.connections} connections, "
      f"buffer pool {show(round(pool_bytes / MEBIBYTE) if pool_bytes else None)} MiB")
print()
speed = [["load", "MiB/s asked", "MiB/s done", "inserts/s", "refused", "insert ms: mean", "median", "p99", "max",
          "queries", "errors", "query ms: mean", "median", "p99", "max", "live files", "files/min"]]
resources = [["load", "machine busy %", "server cores", "loader cores", "resident MiB: end", "max",
              "pool pinned MiB: end", "mean", "max", "per min",
              "pool cached MiB: end", "outside pool MiB: end", "max", "per min"]]
for step in steps:
    query = step["query"]
    speed.append([
        step["load"],
        f"{step['requested']['mebibytes_per_second']:g}",
        f"{step['inserts']['mebibytes_per_second']:g}",
        f"{step['inserts']['per_second']:g}",
        show(step["inserts"]["errors"]),
        *show_latency(step["inserts"]["latency"]),
        show(query["latency"]["count"] if query["latency"] else 0),
        show(query["errors"]),
        *show_latency(query["latency"]),
        show(step["live_files"]["at_end"]),
        show(step["live_files"]["change_per_minute"]),
    ])
    cpu = step["cpu"]
    resources.append([
        step["load"],
        *(["-"] * 3 if cpu is None else [show(cpu["machine_busy_percent"]), show(cpu["server_cores"]), show(cpu["loader_cores"])]),
        *show_bytes(step["resident_memory"], ("mebibytes_at_end", "mebibytes_max")),
        *show_bytes(step["buffer_pool"]["pinned"],
                    ("mebibytes_at_end", "mebibytes_mean", "mebibytes_max", "mebibytes_change_per_minute")),
        *show_bytes(step["buffer_pool"]["cached"], ("mebibytes_at_end",)),
        *show_bytes(step["memory_outside_pool"], ("mebibytes_at_end", "mebibytes_max", "mebibytes_change_per_minute")),
    ])
print_table(speed)
print()
print_table(resources)
