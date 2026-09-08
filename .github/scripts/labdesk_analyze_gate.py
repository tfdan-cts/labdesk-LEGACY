#!/usr/bin/env python3
"""Fail a build on analyzer issues in files LabDesk owns.

`flutter analyze` reports several hundred issues in this repository. Nearly all
of them are inherited from upstream LabDesk and predate the fork, so a gate
that failed on the whole report would have to be switched off to be usable.
This reads the report and fails only on issues in the files LabDesk wrote:

    flutter/lib/labdesk/**
    flutter/lib/common/labdesk_*

Everything else is printed as a count and otherwise left alone.

Usage: labdesk_analyze_gate.py <path to the captured flutter analyze output>
"""

import re
import sys

# Flutter prints an issue as severity, message, location and rule name joined by
# a separator, and it has changed that separator between releases (a bullet in
# older versions, a hyphen in newer ones). Match the location itself instead, so
# the gate does not quietly stop matching anything the next time it changes.
LOCATION = re.compile(r"(?<![\w./\\-])([\w./\\-]+\.dart):\d+:\d+")

# Paths are relative to the flutter/ directory, which is where analyze is run.
OWNED = re.compile(r"^lib/(labdesk/|common/labdesk_)")

# flutter prints "No issues found!", "1 issue found." or "N issues found.", so
# match the singular as well as the plural.
SUMMARY = re.compile(r"(\d+)\s+issues?\s+found")
SUMMARY_LINE = re.compile(r"(\d+\s+issues?\s+found|No issues found)")


def main(path: str) -> int:
    with open(path, encoding="utf-8", errors="replace") as handle:
        lines = handle.read().splitlines()

    summaries = [ln for ln in lines if SUMMARY_LINE.search(ln)]
    if not summaries:
        print(
            "error: the captured output has no 'issues found' summary line, so "
            "flutter analyze did not finish. Treating that as a failure rather "
            "than as a clean report.",
            file=sys.stderr,
        )
        return 1

    match = SUMMARY.search(summaries[-1])
    reported = int(match.group(1)) if match else 0

    located = [ln for ln in lines if LOCATION.search(ln)]
    if len(located) < reported:
        print(
            f"error: flutter analyze reported {reported} issues but only "
            f"{len(located)} lines carry a recognisable file location. The "
            "report format has changed and this gate can no longer tell which "
            "issues belong to LabDesk, so it is failing rather than passing "
            "everything.",
            file=sys.stderr,
        )
        return 1

    owned = []
    for line in located:
        for found in LOCATION.findall(line):
            if OWNED.match(found.replace("\\", "/")):
                owned.append(line.strip())
                break

    noun = "issue" if reported == 1 else "issues"
    print(
        f"\n{reported} analyzer {noun} in the package, {len(owned)} of them in "
        "files LabDesk owns."
    )
    if not owned:
        print("No analyzer issues in lib/labdesk/** or lib/common/labdesk_*.")
        return 0

    print("\nAnalyzer issues in files LabDesk owns:", file=sys.stderr)
    for line in owned:
        print(f"  {line}", file=sys.stderr)
    print(
        "\nFix these. Issues in upstream LabDesk files are not counted here.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} <flutter analyze output>")
    sys.exit(main(sys.argv[1]))
