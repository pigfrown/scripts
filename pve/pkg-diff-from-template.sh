#!/usr/bin/env bash

set -euo pipefail

TEMPLATE_CTID=999

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <CTID-or-name>"
  exit 1
fi

TARGET="$1"

# Resolve CTID if name was provided
if [[ "$TARGET" =~ ^[0-9]+$ ]]; then
  TARGET_CTID="$TARGET"
else
  TARGET_CTID=$(pct list | awk -v name="$TARGET" '$3 == name {print $1}')
  if [[ -z "${TARGET_CTID:-}" ]]; then
    echo "Could not find container with name: $TARGET"
    exit 1
  fi
fi

echo "Comparing installed packages:"
echo "  Template: CT ${TEMPLATE_CTID}"
echo "  Target:   CT ${TARGET_CTID}"
echo

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Get package lists (names only)
pct exec "$TEMPLATE_CTID" -- apt-mark showmanual \
  | sort > "$TMPDIR/template.txt"

pct exec "$TARGET_CTID" -- apt-mark showmanual \
  | sort > "$TMPDIR/target.txt"

echo "=== Packages added in CT ${TARGET_CTID} ==="
comm -13 "$TMPDIR/template.txt" "$TMPDIR/target.txt" || true
echo

echo "=== Packages removed from CT ${TARGET_CTID} ==="
comm -23 "$TMPDIR/template.txt" "$TMPDIR/target.txt" || true
echo

echo "Done."
