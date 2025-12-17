#!/usr/bin/env python3
"""Calculate coverage for src/ files only"""
import re
import subprocess
import sys
import os

# Get the directory where this script is located
script_dir = os.path.dirname(os.path.abspath(__file__))
project_root = os.path.dirname(script_dir)

result = subprocess.run(
    ['forge', 'coverage', '--ir-minimum', '--exclude-tests', '--report', 'summary'],
    capture_output=True,
    text=True,
    cwd=project_root
)

covered = 0
total = 0
files = []

for line in result.stdout.split('\n'):
    if '| src/' in line:
        match = re.search(r'(\d+\.\d+)% \((\d+)/(\d+)\)', line)
        if match:
            c = int(match.group(2))
            t = int(match.group(3))
            covered += c
            total += t
            missing = t - c
            if missing > 0:
                files.append((line.strip(), c, t, missing))

print("Files with missing coverage:")
for f, c, t, m in files:
    print(f"  Missing {m} lines: {c}/{t} = {(c/t)*100:.2f}%")
    # Extract filename
    filename_match = re.search(r'src/[^|]+', f)
    if filename_match:
        print(f"    {filename_match.group(0)}")

if total > 0:
    coverage = (covered / total) * 100
    missing = total - covered
    print(f"\nTotal src/ coverage: {coverage:.2f}% ({covered}/{total} lines)")
    print(f"Missing: {missing} lines to reach 100%")
    
    if missing == 0:
        print("✓ 100% coverage achieved!")
        sys.exit(0)
    else:
        sys.exit(1)

