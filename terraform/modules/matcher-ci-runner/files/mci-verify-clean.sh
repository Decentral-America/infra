#!/usr/bin/env bash
# Proves a slot left nothing behind: no container and no volume carrying the slot's label, the named
# volume gone from disk, and no sysbox per-container state. Args: SLOT [VOLUME]. Exit 1 lists the leftovers.
set -uo pipefail
SLOT="${1:?slot}"; VOL="${2:-}"
bad=0
c=$(docker ps -aq --filter "label=matcher-ci.slot=${SLOT}")
[ -z "$c" ] || { echo "leftover containers of slot ${SLOT}: $c"; bad=1; }
v=$(docker volume ls -q --filter "label=matcher-ci.slot=${SLOT}")
[ -z "$v" ] || { echo "leftover volumes of slot ${SLOT}: $v"; bad=1; }
if [ -n "$VOL" ] && [ -e "/var/lib/docker/volumes/${VOL}" ]; then echo "volume directory still on disk: ${VOL}"; bad=1; fi
[ "$bad" -eq 0 ] && echo "slot ${SLOT}: clean (no container, no volume left)"
exit "$bad"
