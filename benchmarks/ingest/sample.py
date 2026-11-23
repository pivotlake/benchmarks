#!/usr/bin/env python3
"""Every ten seconds, append a line to a file: the time, the server's resident
memory, how many data files are live in the benchmark's table, the CPU time
spent so far by the whole machine, by the server and by the loader, and how
the server's buffer pool is used.

The live files and the buffer pool are asked of the server itself, from its
system tables. Pivot's `system.table_files` has a row per live data file, and
its `system.memory_blocks` a row per block of the pool, each free, pinned by
an operator, or lent to a cache. ClickHouse's `system.parts` has a row per
part, and its active parts are the table's live files; it has no pool, so
those fields are `NA`.

The CPU times are running totals in clock ticks, as /proc counts them: the
machine's busy and total ticks over all its cores, and the ticks of the
server's process and of the loader's, whichever loader is running.

Usage: sample.py <pivot or clickhouse> <server pid> <pivot's port> <table> <samples file>
"""

import os
import subprocess
import sys
import time

engine, server_pid, server_port, table, samples_path = sys.argv[1:]
LOADER_NAME = "logs-load"
LIVE_FILES_SQL = (
    "SELECT count(*) FROM system.table_files f JOIN system.tables t ON t.id = f.table_id "
    f"WHERE t.name = '{table}'"
)
POOL_SQL = "SELECT state, sum(bytes) FROM system.memory_blocks GROUP BY state"
ACTIVE_PARTS_SQL = f"SELECT count() FROM system.parts WHERE active AND table = '{table}'"
CLICKHOUSE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "clickhouse")


def run_sql(sql):
    """The rows the server answers `sql` with, each a list of its fields."""
    command = {
        "pivot": ["psql", "-h", "127.0.0.1", "-p", server_port, "-U", "pivot", "-d", "postgres",
                  "-X", "-q", "-A", "-t", "-F", "\t", "-v", "ON_ERROR_STOP=1", "-c", sql],
        "clickhouse": [CLICKHOUSE, "client", "--query", sql],
    }[engine]
    answer = subprocess.run(command, check=True, capture_output=True, text=True)
    return [line.split("\t") for line in answer.stdout.splitlines() if line]


def read_pool_bytes():
    """The pool's free bytes, the bytes operators pin and the bytes its caches hold."""
    free = pinned = cached = 0
    for state, state_bytes in run_sql(POOL_SQL):
        if state == "free":
            free += int(state_bytes)
        elif state == "pinned":
            pinned += int(state_bytes)
        else:
            cached += int(state_bytes)
    return free, pinned, cached


def read_resident_kilobytes():
    for line in open(f"/proc/{server_pid}/status"):
        if line.startswith("VmRSS:"):
            return int(line.split()[1])
    raise SystemExit("the server's status has no VmRSS")


def read_machine_ticks():
    """The machine's busy and total CPU ticks since boot."""
    ticks = [int(field) for field in open("/proc/stat").readline().split()[1:]]
    idle = ticks[3] + ticks[4]
    return sum(ticks) - idle, sum(ticks)


def read_process_ticks(pid):
    """The CPU ticks the process `pid` has used, in user and kernel mode."""
    # The command name, in parentheses, may itself hold spaces.
    fields = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
    return int(fields[11]) + int(fields[12])


def read_loader_ticks():
    """The CPU ticks of the loader running now, zero between two steps."""
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            if open(f"/proc/{pid}/comm").read().strip() == LOADER_NAME:
                return read_process_ticks(pid)
        except OSError:
            continue
    return 0


while True:
    started = time.time()
    try:
        if engine == "pivot":
            live_files = int(run_sql(LIVE_FILES_SQL)[0][0])
            pool = read_pool_bytes()
        else:
            live_files = int(run_sql(ACTIVE_PARTS_SQL)[0][0])
            pool = ("NA", "NA", "NA")
    except (subprocess.CalledProcessError, IndexError, ValueError) as error:
        print(f"sample.py: asking the server failed: {error}", file=sys.stderr)
        live_files, pool = "NA", ("NA", "NA", "NA")
    busy_ticks, total_ticks = read_machine_ticks()
    fields = [f"{time.time():.0f}", read_resident_kilobytes(), live_files, busy_ticks, total_ticks,
              read_process_ticks(server_pid), read_loader_ticks(), *pool, f"{time.time() - started:.2f}"]
    with open(samples_path, "a") as samples:
        samples.write("\t".join(str(field) for field in fields) + "\n")
    time.sleep(max(0.0, 10 - (time.time() - started)))
