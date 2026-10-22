#!/usr/bin/env python3
"""Merge a managed MCP section into the opencode configuration.

The managed file holds the "mcp" section rendered by Ansible (it may contain
secrets). It is merged into the target opencode.json, replacing the servers it
defines and keeping any other server already configured by the user. The
"mcp" section is removed from the secondary config (opencode.jsonc) so the
same server is never defined twice.
"""

import argparse
import json
import os
import re
import shutil
import sys
import time


def load_json(path, default=None):
    if not os.path.exists(path):
        return {} if default is None else default
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return json.loads(strip_jsonc(text))


def strip_jsonc(text):
    """Best effort JSONC -> JSON conversion (comments and trailing commas)."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"(^|\s)//[^\n]*", "", text)
    text = re.sub(r",(\s*[}\]])", r"\1", text)
    return text


def dump_json(path, data, mode=0o600):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=False)
        handle.write("\n")
    os.chmod(path, mode)


def backup(path):
    stamp = time.strftime("%Y%m%d%H%M%S")
    destination = "%s.bak-%s" % (path, stamp)
    shutil.copy2(path, destination)
    return destination


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--managed", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--secondary", required=False)
    args = parser.parse_args()

    managed = load_json(args.managed)
    managed_mcp = managed.get("mcp", managed)

    target = load_json(args.target)
    current_mcp = target.get("mcp") or {}
    merged = dict(current_mcp)
    merged.update(managed_mcp)
    target["mcp"] = merged

    changed = merged != current_mcp
    if changed:
        if os.path.exists(args.target):
            print("backup: %s" % backup(args.target))
        dump_json(args.target, target)
        print("changed: updated %d MCP servers in %s" % (len(merged), args.target))
    else:
        print("changed: no changes needed in %s" % args.target)

    if args.secondary and os.path.exists(args.secondary):
        secondary = load_json(args.secondary)
        if "mcp" in secondary:
            removed = sorted(secondary["mcp"].keys())
            secondary.pop("mcp")
            dump_json(args.secondary, secondary)
            changed = True
            print("changed: removed duplicate mcp section (%s) from %s"
                  % (", ".join(removed), args.secondary))

    print("servers: %s" % ", ".join(sorted(merged.keys())))
    print("status: %s" % ("changed" if changed else "unchanged"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
