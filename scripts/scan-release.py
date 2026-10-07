#!/usr/bin/env python3
"""Reject obvious private data in staged source before a private or public push."""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
paths = subprocess.check_output(["git", "ls-files", "--cached"], cwd=root, text=True).splitlines()
if not paths:
    raise SystemExit("No staged files to inspect.")
patterns = {
    "personal Windows path": re.compile(r"[A-Za-z]:\\(?:Users|AWS)\\", re.I),
    "known personal identifier": re.compile(r"elim" r"i(?:\.|\\|/|@)|shroom" r" mansion|6ab6" r"787b", re.I),
    "API credential": re.compile(r"(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})"),
    "live tunnel URL": re.compile(r"https://[A-Za-z0-9-]+\.trycloudflare\.com", re.I),
    "personal ChatGPT project": re.compile(r"https://chatgpt\.com/g/g-p-[a-z0-9-]+", re.I),
}
findings = []
for name in paths:
    path = root / name
    if not path.is_file():
        continue
    try:
        content = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        continue
    for label, pattern in patterns.items():
        for match in pattern.finditer(content):
            line = content.count("\n", 0, match.start()) + 1
            findings.append(f"{name}:{line}: {label}")
if findings:
    print("\n".join(findings), file=sys.stderr)
    raise SystemExit(1)
print(f"Scanned {len(paths)} staged paths; no known personal identifiers or credential patterns found.")