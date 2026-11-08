#!/usr/bin/env python3
"""Maintain the panel-bridge stanza in a DSH profile's cordis.patch.yml.

The loader this deployment runs understands exactly this shape:

    - insert:
        - id: panel-bridge-N
          name: ./plugins/panel-bridge-N/index.js
          config: {...}

Anything else fails at boot: a package-style `name` gives ERR_MODULE_NOT_FOUND,
an unquoted value starting with `@` is invalid YAML, and a `path:` key is ignored.
The block is marker-delimited so re-running this never duplicates it.

Usage:
    patch_profile.py [--patch FILE] [--plugins DIR] [--remove]
"""
import argparse
import os
import re
import subprocess
import sys

MARK = "# DS-Harness-HM companion bridge"


def newest_version(plugins_dir):
    versions = []
    for name in os.listdir(plugins_dir):
        m = re.match(r"panel-bridge-(\d+)$", name)
        if m and os.path.isfile(os.path.join(plugins_dir, name, "index.js")):
            versions.append(int(m.group(1)))
    return max(versions) if versions else None


def strip_block(text):
    idx = text.find(MARK)
    if idx != -1:
        return text[:idx].rstrip("\n") + "\n"
    # legacy block without the marker
    return re.sub(
        r"\n- insert:\n(?:(?:[ \t].*)?\n)*?[ \t]+- id: panel-bridge[^\n]*\n(?:(?:[ \t].*)?\n)*",
        "\n",
        text,
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--patch", default=os.environ.get("PATCH", os.path.expanduser("~/.dsh/profiles/web/cordis.patch.yml")))
    ap.add_argument("--plugins", default=os.environ.get("PLUGINS", os.path.expanduser("~/.dsh/profiles/web/plugins")))
    ap.add_argument("--remove", action="store_true")
    ap.add_argument("--no-validate", action="store_true")
    args = ap.parse_args()

    if not os.path.isfile(args.patch):
        sys.exit(f"patch file not found: {args.patch}")

    text = open(args.patch, encoding="utf-8").read()
    body = strip_block(text)

    if args.remove:
        open(args.patch, "w", encoding="utf-8").write(body)
        print("removed panel-bridge stanza")
    else:
        n = newest_version(args.plugins)
        if n is None:
            sys.exit(f"no panel-bridge-N/index.js under {args.plugins}")
        block = (
            f"{MARK} (panel-bridge): pairing / background SSE / approval\n"
            "# Managed by dsh-panel-bridge/install.sh — do not edit by hand.\n"
            "- insert:\n"
            f"    - id: panel-bridge-{n}\n"
            f"      name: ./plugins/panel-bridge-{n}/index.js\n"
            "      config:\n"
            "        approvalTimeoutMs: 120000\n"
            "        takeOverApprovals: true\n"
            "        injectBridge: false\n"
        )
        open(args.patch, "w", encoding="utf-8").write(body + "\n" + block)
        print(f"patched: panel-bridge-{n}")

    if args.no_validate:
        return
    profile = os.path.basename(os.path.dirname(args.patch))
    dump = subprocess.run(["dsh", "--profile", profile, "--dump-config"], capture_output=True, text=True)
    if dump.returncode != 0:
        err = (dump.stderr or dump.stdout).strip().splitlines()
        print("CONFIG INVALID:", err[-1] if err else "unknown error", file=sys.stderr)
        sys.exit(1)
    print(f"config OK ({len(dump.stdout.splitlines())} lines)")


if __name__ == "__main__":
    main()
