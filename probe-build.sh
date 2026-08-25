#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Probe whether an out-of-tree kernel module builds against the running kernel.
# Builds in a temp dir. Never installs, registers with DKMS, or loads anything.
# Usage: ./probe-build.sh <git-url> [ref] [kernel-release]
# Exit 0 = builds clean. 1 = build failed. 2 = prerequisites missing.
set -uo pipefail

URL="${1:-}"; REF="${2:-}"; KREL="${3:-$(uname -r)}"
[ -z "$URL" ] && { echo "usage: $0 <git-url> [ref] [kernel-release]"; exit 2; }

KBUILD="/lib/modules/${KREL}/build"
[ -f "$KBUILD/Makefile" ] || { echo "FAIL: no kernel headers at $KBUILD (need kernel-devel-${KREL})"; exit 2; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
echo "kernel:  $KREL"
echo "headers: $(readlink -f "$KBUILD")"
echo "gcc:     $(gcc -dumpversion)"
echo "source:  $URL ${REF:+@ $REF}"

if ! git clone --quiet --depth 50 "$URL" "$WORK/src" 2>"$WORK/clone.err"; then
  echo "FAIL: clone failed"; sed 's/^/  /' "$WORK/clone.err"; exit 1
fi
if [ -n "$REF" ]; then
  git -C "$WORK/src" checkout --quiet "$REF" 2>/dev/null || { echo "FAIL: ref '$REF' not found"; exit 1; }
fi
echo "commit:  $(git -C "$WORK/src" log -1 --format='%h %ad %s' --date=short)"

echo "--- building ---"
if make -C "$KBUILD" M="$WORK/src" modules -j"$(nproc)" >"$WORK/build.log" 2>&1; then
  mapfile -t KOS < <(find "$WORK/src" -name '*.ko' -printf '%f\n' | sort)
  echo "PASS: built ${#KOS[@]} module(s): ${KOS[*]:-none}"
  [ "${#KOS[@]}" -eq 0 ] && { echo "  but produced no .ko — treat as failure"; exit 1; }
  grep -ciE 'warning:' "$WORK/build.log" | xargs -I{} echo "  warnings: {}"
  exit 0
fi
echo "FAIL: build errors"
grep -iE 'error:|Error [0-9]|No rule to make' "$WORK/build.log" | head -15 | sed 's/^/  /'
exit 1
