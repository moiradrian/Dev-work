#!/usr/bin/env bash
# monitor_reclaimed.sh — realtime reclaimed-bytes monitor for ctrlrpc cleaner_status

set -Eeuo pipefail

INTERVAL="${1:-10}"
SOURCE_CMD="${SOURCE_CMD:-ctrlrpc -p 9911 show.cleaner_status}"
RECLAIMED_COL="${RECLAIMED_COL:-13}"      # <<< force the column here
SKIP_SUMMARY_LINES="${SKIP_SUMMARY_LINES:-12}"
DEBUG="${DEBUG:-0}"

cleanup() { tput cnorm || true; }
trap cleanup EXIT INT TERM
tput civis

while true; do
  clear
  echo "Reclaimed totals (updated: $(date '+%Y-%m-%d %H:%M:%S'))"
  echo "Source: ${SOURCE_CMD}   |  Column: ${RECLAIMED_COL}   |  Skip summary lines: ${SKIP_SUMMARY_LINES}"
  echo "--------------------------------------------------------------------------"

  # shellcheck disable=SC2086
  eval "$SOURCE_CMD" | awk -v RC="$RECLAIMED_COL" -v SKIPN="$SKIP_SUMMARY_LINES" -v DEBUG="$DEBUG" '
    BEGIN { IGNORECASE=1; skip=0 }

    # Human-readable (IEC)
    function human(n,   u,i){ split("B KiB MiB GiB TiB PiB",u," "); i=1; while(n>=1024 && i<6){n/=1024;i++} return (i==1)?sprintf("%d %s",n,u[i]):sprintf("%.2f %s",n,u[i]) }

    # ---- IGNORE "Cleaner summary" blocks ----
    /^[[:space:]]*Cleaner[[:space:]]+summary/ {
      skip = SKIPN
      if (DEBUG) printf("[DEBUG] Entering summary skip: %d lines\n", skip) > "/dev/stderr"
      next
    }
    skip > 0 { skip--; next }

    # ---- GROUP DETECTION ----
    /[[:space:]]*Resource[[:space:]]+Group/ {
      split($0, parts, ":")
      grp = (length(parts)>=2?parts[2]:$NF)
      gsub(/^[[:space:]]+|[[:space:]]+$/,"", grp); gsub(/:/,"", grp)
      if (grp!="") {
        curgrp = grp
        if (!(grp in seen)) { order[++norder]=grp; seen[grp]=1 }
        if (DEBUG) printf("[DEBUG] Group detected: \"%s\"\n", curgrp) > "/dev/stderr"
      }
      next
    }

    # ---- DATA ROWS: sum RC only if numeric ----
    {
      # Guard against short lines
      if (NF < RC) next

      raw = $RC

      # Ignore header echoes (field literally says reclaimed)
      if (tolower(raw) ~ /^reclaimed(\(bytes\))?$/) next

      # Normalize number
      gsub(/,/, "", raw)

      # Accept only rows where RC starts with a digit (pure bytes)
      if (match(raw, /^[[:space:]]*([0-9]+)/, m)) {
        bytes = m[1] + 0
        if (curgrp != "" && bytes != 0) {
          total[curgrp] += bytes
          grand += bytes
          if (DEBUG && nsample < 5) {
            printf("[DEBUG] +%d bytes (grp=%s) from field %d: \"%s\"\n", bytes, curgrp, RC, raw) > "/dev/stderr"
            nsample++
          }
        }
      }
    }

    END {
      for (i=1; i<=norder; i++) {
        g = order[i]; v = (g in total ? total[g] : 0)
        printf "%-8s total reclaimed: %s\n", g, human(v)
      }
      printf "GRAND   total reclaimed: %s\n", human(grand + 0)
    }
  '

  echo
  echo "(Ctrl-C to exit)  Refresh every ${INTERVAL}s"
  sleep "$INTERVAL"
done
