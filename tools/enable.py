#!/usr/bin/env python3
"""Enable an npm-installed dsh-panel-bridge in a DSH profile.

`dsh plugin --profile web add dsh-panel-bridge` only installs the package into the
profile's node_modules — DSH still needs a loader entry to mount it. This adds (or
re-points) that single stanza and validates the profile:

    - insert:
        - id: panel-bridge
          name: dsh-panel-bridge

Usage:
    python3 tools/enable.py [--profile web] [--package dsh-panel-bridge] [--remove]
"""
import argparse
import os
import re
import subprocess
import sys

MARK = "# DS-Harness-HM companion bridge"
ID = "panel-bridge"


def strip_block(text):
    idx = text.find(MARK)
    if idx != -1:
        return text[:idx].rstrip("\n") + "\n"
    return re.sub(
        r"\n- insert:\n(?:(?:[ \t].*)?\n)*?[ \t]+- id: panel-bridge[^\n]*\n(?:(?:[ \t].*)?\n)*",
        "\n",
        text,
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", default=os.environ.get("PROFILE", "web"))
    ap.add_argument("--package", default="dsh-panel-bridge")
    ap.add_argument("--dsh-home", default=os.environ.get("DSH_HOME", os.path.expanduser("~/.dsh")))
    ap.add_argument("--remove", action="store_true")
    ap.add_argument("--no-validate", action="store_true")
    args = ap.parse_args()

    patch = os.path.join(args.dsh_home, "profiles", args.profile, "cordis.patch.yml")
    if not os.path.isfile(patch):
        sys.exit(f"profile patch not found: {patch}")

    text = strip_block(open(patch, encoding="utf-8").read())
    if args.remove:
        open(patch, "w", encoding="utf-8").write(text)
        print("panel-bridge disabled")
    else:
        block = (
            f"{MARK} (panel-bridge)\n"
            "# Managed by `dsh-panel-bridge`: npm install + this stanza is all it needs.\n"
            "- insert:\n"
            f"    - id: {ID}\n"
            f"      name: {args.package}\n"
            "      config:\n"
            "        approvalTimeoutMs: 120000\n"
            "        takeOverApprovals: true\n"
            "        injectBridge: false\n"
        )
        open(patch, "w", encoding="utf-8").write(text + "\n" + block)
        print(f"enabled {args.package} in profile '{args.profile}'")

    if args.no_validate:
        return
    dump = subprocess.run(["dsh", "--profile", args.profile, "--dump-config"], capture_output=True, text=True)
    if dump.returncode != 0:
        err = (dump.stderr or dump.stdout).strip().splitlines()
        print("CONFIG INVALID:", err[-1] if err else "unknown error", file=sys.stderr)
        sys.exit(1)
    print(f"config OK ({len(dump.stdout.splitlines())} lines)")


if __name__ == "__main__":
    main()
