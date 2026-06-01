#!/usr/bin/env python3
"""Session-replay driver for CodeMySpec demos.

Walks a Claude Code session .jsonl and replays its tool calls against a sealed
sandbox (the cli_demo harness on :4005 + a throwaway project dir), rebuilding a
project from scratch so we can capture a demo with no staging.

SAFETY (load-bearing):
  * The source transcript in ~/.claude/projects is NEVER read in place. On
    startup we copy it into demo/sessions/ and only ever touch the copy.
  * File writes are remapped from the recording's absolute paths into the
    throwaway project dir (default /tmp/cms_demo_mms) — never the real repo.
  * Network/destructive bash (git/gh/aws), out-of-tree writes, and external
    MCP calls are flagged and skipped by default; they are recording noise
    (commits, CI-log debugging, the agent's own memory writes), not the build.

Modes:
  --dry-run   (default) classify every op and print the replay plan
  --copy-only just copy the source transcript into demo/sessions/ and exit
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import shutil
import sys

# --- sandbox wiring -------------------------------------------------------
# The real project the recording was made against (paths get remapped FROM it).
DEFAULT_SOURCE_ROOT = "/Users/johndavenport/Documents/github/market_my_spec"
# The throwaway project dir the replay writes INTO (remapped TO).
DEFAULT_FAKE_DIR = "/tmp/cms_demo_mms"
# The cli_demo harness endpoint (config/cli_demo.exs).
DEFAULT_HARNESS_URL = "http://localhost:4005"

SESSIONS_DIR = os.path.join(os.path.dirname(__file__), "..", "sessions")

# bash we never want a replay to run — recording noise, not the build.
NETWORK_DESTRUCTIVE = (
    "git push", "git commit", "git add", "git reset", "git checkout",
    "fly ", "gh ", "curl ", "aws ", "ssh ", "scp ", "rm -rf",
    "npm publish", "mix hex.publish",
)

HARNESS_MCP_PREFIX = "mcp__plugin_codemyspec_local__"
VIBIUM_PREFIX = "mcp__vibium__"
META_TOOLS = {
    "Task", "TaskCreate", "TaskUpdate", "TaskGet", "TaskList",
    "Agent", "Skill", "ToolSearch", "Monitor", "ExitPlanMode", "EnterPlanMode",
}


def copy_source(source_jsonl: str) -> str:
    """Copy the source transcript into demo/sessions/ and return the copy path.

    Read-only on the source. If a copy already exists it is refreshed only when
    the source is newer, so reruns are cheap but never go stale.
    """
    os.makedirs(SESSIONS_DIR, exist_ok=True)
    dest = os.path.join(SESSIONS_DIR, os.path.basename(source_jsonl))
    if not os.path.exists(dest) or os.path.getmtime(source_jsonl) > os.path.getmtime(dest):
        shutil.copy2(source_jsonl, dest)  # copy2 preserves mtime; never writes source
        sys.stderr.write(f"[copy] {source_jsonl}\n   ->  {dest}\n")
    else:
        sys.stderr.write(f"[copy] up to date: {dest}\n")
    return dest


def load_ops(path: str):
    """Yield (timestamp, name, input_dict) for every tool_use in order."""
    with open(path) as f:
        for line in f:
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            msg = o.get("message") or {}
            content = msg.get("content")
            if not isinstance(content, list):
                continue
            for b in content:
                if isinstance(b, dict) and b.get("type") == "tool_use":
                    yield o.get("timestamp", ""), b.get("name", "?"), b.get("input") or {}


def remap(path: str, source_root: str, fake_dir: str):
    if not path:
        return path, False
    if path.startswith(source_root):
        return path.replace(source_root, fake_dir, 1), True
    return path, False  # out-of-tree


def bash_is_flagged(cmd: str) -> bool:
    lc = cmd.lower()
    return any(tok in lc for tok in NETWORK_DESTRUCTIVE)


def classify(name: str, inp: dict, source_root: str, fake_dir: str):
    """Return (cls, action_desc, flagged_reason|None)."""
    if name in ("Write", "Edit", "NotebookEdit"):
        p = inp.get("file_path", "")
        np, ok = remap(p, source_root, fake_dir)
        if not ok:
            return "file", f"{name} -> {p}", "out-of-tree write"
        return "file", f"{name} -> {np}", None
    if name == "Bash":
        cmd = inp.get("command", "")
        if bash_is_flagged(cmd):
            return "bash", f"BASH: {cmd[:80]}", "network/destructive"
        return "bash", f"BASH (cwd={fake_dir}): {cmd[:80]}", None
    if name.startswith(HARNESS_MCP_PREFIX):
        short = name[len(HARNESS_MCP_PREFIX):]
        ka = ", ".join(f"{k}={str(v)[:30]}" for k, v in list(inp.items())[:2])
        return "harness_mcp", f"MCP {short} (X-Working-Dir={fake_dir}) {ka}", None
    if name.startswith(VIBIUM_PREFIX):
        return "vibium", f"VIBIUM {name[len(VIBIUM_PREFIX):]} (recorded / live vs rebuilt project)", None
    if name == "Read":
        return "read", f"READ {inp.get('file_path', '')[:70]}", None  # narration only
    if name in META_TOOLS:
        return "meta", f"META {name}", None
    return "external", f"EXTERNAL {name}", "external side effect"


def dry_run(copy_path: str, source_root: str, fake_dir: str, detail_n: int):
    cls = collections.Counter()
    flagged = []
    detailed = []
    total = 0
    for ts, name, inp in load_ops(copy_path):
        total += 1
        c, desc, reason = classify(name, inp, source_root, fake_dir)
        cls[c] += 1
        if reason:
            flagged.append((reason, name, desc))
        suffix = f"  [FLAG: {reason}]" if reason else ""
        detailed.append((ts[11:19] if ts else "", desc + suffix))

    print(f"SOURCE ROOT (remap from): {source_root}")
    print(f"FAKE DIR    (remap to):   {fake_dir}")
    print(f"HARNESS:                  {DEFAULT_HARNESS_URL}")
    print(f"TRANSCRIPT (working copy):{copy_path}")
    print(f"TOTAL OPS: {total}\n")
    print("=== replay class summary ===")
    for k, v in cls.most_common():
        print(f"  {v:4d}  {k}")
    print(f"\n=== first {detail_n} ops ===")
    for t, d in detailed[:detail_n]:
        print(f"  {t}  {d}")
    by_reason = collections.Counter(r for r, _, _ in flagged)
    print(f"\n=== flagged / skipped ({len(flagged)}) ===")
    for r, n in by_reason.most_common():
        print(f"  {n:3d}  {r}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("source_jsonl", help="path to the source session .jsonl in ~/.claude/projects")
    ap.add_argument("--source-root", default=DEFAULT_SOURCE_ROOT)
    ap.add_argument("--fake-dir", default=DEFAULT_FAKE_DIR)
    ap.add_argument("--detail", type=int, default=40, help="ops to print in detail (dry-run)")
    ap.add_argument("--copy-only", action="store_true", help="copy transcript into demo/sessions/ and exit")
    ap.add_argument("--dry-run", action="store_true", help="classify + print plan (default)")
    args = ap.parse_args()

    copy_path = copy_source(args.source_jsonl)
    if args.copy_only:
        return
    dry_run(copy_path, args.source_root, args.fake_dir, args.detail)


if __name__ == "__main__":
    main()
