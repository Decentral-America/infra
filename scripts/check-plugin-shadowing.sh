#!/usr/bin/env bash
# Fails if any node plugin jar contains a class or resource that the node image itself ships.
#
# The node runs with `-cp /usr/share/dcc/lib/plugins/*:/usr/share/dcc/lib/*`, so a plugin copy of a node
# class silently replaces the node's own. On 2026-10-04 the DEX plugin's stale protobuf classes (dex-grpc
# 0767d246, 703 duplicated image classes) made main's miner throw NoSuchMethodError 577 times and shut the
# node down 5 times while decoding peers' microblocks (FinalizationVoting.hotstuffConflicts()).
#
# Usage: check-plugin-shadowing.sh <node-image-ref> <plugin-dir>
set -euo pipefail
IMG="$1"
PDIR="$2"
T=$(mktemp -d)
CID=""
trap 'rm -rf "$T"; [ -n "$CID" ] && docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT

CID=$(docker create --platform linux/amd64 "$IMG")
docker cp -q "$CID:/usr/share/dcc/lib" "$T/lib"

# Per-jar metadata and the extension's own application.conf are expected to overlap and are not classes.
ALLOW='^(META-INF/|application\.conf$|reference\.conf$)'
for j in "$T"/lib/*.jar; do unzip -Z1 "$j"; done | grep -v '/$' | grep -Ev "$ALLOW" | sort -u > "$T/image.txt"

rc=0
for p in "$PDIR"/*.jar; do
  unzip -Z1 "$p" | grep -v '/$' | grep -Ev "$ALLOW" | sort -u > "$T/plugin.txt"
  n=$(comm -12 "$T/plugin.txt" "$T/image.txt" | tee "$T/dup.txt" | wc -l | tr -d ' ')
  if [ "$n" -ne 0 ]; then
    echo "::error::$(basename "$p") shadows $n node image entries, e.g.:"
    head -5 "$T/dup.txt"
    rc=1
  else
    echo "OK $(basename "$p"): no entry shadows a node image class or resource"
  fi
done
exit $rc
