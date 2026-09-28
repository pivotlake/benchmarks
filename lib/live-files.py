#!/usr/bin/env python3
"""Print "<table>\t<file>" for every data file live in a pivot datastore's tables.

A pivot datastore keeps a manifest naming each table's directory, and each
table a Delta log whose commits add and remove files. Replaying the commits
gives the live set; files that compaction superseded stay on disk until a
vacuum, so a directory listing would include them.

Usage: live-files.py <datastore location> [table ...]
"""

import json
import pathlib
import sys

location = pathlib.Path(sys.argv[1])
wanted = set(sys.argv[2:])
manifest = json.loads((location / "_pivot_manifest.json").read_text())

for schema in manifest["schemas"]:
    for table, table_id in schema["table_ids"].items():
        if wanted and table not in wanted:
            continue
        table_dir = location / manifest["table_locations"][table_id]
        live = set()
        for commit in sorted((table_dir / "_delta_log").glob("*.json")):
            for line in commit.read_text().splitlines():
                action = json.loads(line)
                if "add" in action:
                    live.add(action["add"]["path"])
                elif "remove" in action:
                    live.discard(action["remove"]["path"])
        for path in sorted(live):
            print(f"{table}\t{table_dir / path}")
