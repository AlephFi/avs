#!/bin/bash
# Calculate coverage for src/ files only

forge coverage --ir-minimum --exclude-tests --report summary 2>&1 | \
  grep "^[|] src/" | \
  awk -F'|' '{
    # Extract covered/total from the second column (Lines)
    if (match($2, /([0-9]+)\/([0-9]+)/, arr)) {
      covered += arr[1]
      total += arr[2]
    }
  } END {
    if (total > 0) {
      coverage = (covered / total) * 100
      missing = total - covered
      printf "Total src/ coverage: %.2f%% (%d/%d lines)\n", coverage, covered, total
      printf "Missing: %d lines to reach 100%%\n", missing
    }
  }'

