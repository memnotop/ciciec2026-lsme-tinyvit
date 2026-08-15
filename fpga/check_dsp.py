#!/usr/bin/env python3
import os
import re
import sys
from pathlib import Path
from typing import List


def usage() -> None:
    print("Usage: python3 check_dsp.py <dsp-utilization-report> [max-dsp]", file=sys.stderr)


def extract_dsp_used(report: Path) -> int:
    if not report.is_file():
        raise FileNotFoundError(f"DSP utilization report not found: {report}")

    used_values = []
    for line in report.read_text(errors="replace").splitlines():
        stripped = line.strip()
        if not stripped.startswith("|") or "DSP" not in stripped.upper():
            continue

        columns = [col.strip() for col in stripped.strip("|").split("|")]
        if len(columns) < 2:
            continue
        if not re.fullmatch(r"DSPs?", columns[0], re.IGNORECASE):
            continue

        match = re.fullmatch(r"\d+", columns[1])
        if match:
            used_values.append(int(match.group(0)))

    if not used_values:
        raise ValueError(f"No DSP utilization row found in {report}")

    return max(used_values)


def main(argv: List[str]) -> int:
    if len(argv) not in (2, 3):
        usage()
        return 2

    report = Path(argv[1])
    max_allowed = int(argv[2]) if len(argv) == 3 else int(os.environ.get("DSP_MAX", "0"))
    used = extract_dsp_used(report)
    print(f"DSP used: {used}, allowed: {max_allowed}")
    if used > max_allowed:
        print(f"ERROR: DSP usage {used} exceeds allowed limit {max_allowed}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
