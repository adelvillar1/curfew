#!/bin/bash
# session-close-hygiene.sh — the fleet session-close leg, for Curfew.
#
# Fleet's version (docs/plans/2026-11-06-session-close-hygiene.md) runs once a goal is complete and a
# recap is written, on the principle **if you spin it up, you shut it down cleanly**: the run shuts down
# the processes it spawned, disposes what it accumulated, cleans the disk, and reports the numbers.
#
# Curfew's four legs, and what each may touch:
#
#   1. WHAT THE SESSION SPAWNED — the verification daemon (cua-driver) if it is running, and any test
#      instance of the app started with a seam flag (--open-help, --press, --pane, --render-window).
#      The *installed* app is never touched: it is the product, not litter. Reported, not assumed.
#   2. ORPHANS — reap-orphans.sh in report mode, so keep-alives whose owner is gone are named.
#   3. THE DISK — repo-hygiene.sh in report mode (the build artifacts), plus this session's screenshots
#      in /tmp, which are copies of files already in docs/evidence.
#   4. WHAT CURFEW ITSELF GREW — the journal, the decision log, the disagreement log and the quarantine
#      store, sized and aged. These are RECORDS: reported, never deleted. A quarantine entry is a file
#      the owner may want back; a decision log is an audit trail.
#
# Modes:
#   (none)   the report (default)
#   --live   stop the verification daemon and the test instances, remove this session's /tmp captures
#
# Exit 0 always: a close that finds nothing is a success.

set -u

LIVE=0
[ "${1:-}" = "--live" ] && LIVE=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$HOME/Library/Application Support/Curfew"
LOG="$HOME/Library/Logs/curfew-session-close.log"
mkdir -p "$(dirname "$LOG")"
say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
mb() { awk -v k="$1" 'BEGIN{printf "%.1f", k/1024}'; }
size_of() { du -sk "$1" 2>/dev/null | awk '{print $1+0}'; }

echo "== 1. processes this session may have spawned =="

daemon=""
if command -v cua-driver >/dev/null 2>&1; then
  if cua-driver status 2>/dev/null | grep -q 'daemon is running'; then daemon="running"; fi
fi
echo "  cua-driver daemon: ${daemon:-not running}"
[ "$daemon" = "running" ] && [ "$LIVE" -eq 1 ] && { cua-driver stop >/dev/null 2>&1; say "stopped cua-driver daemon"; echo "  → stopped"; }

app_pids=$(pgrep -f 'Curfew.app/Contents/MacOS/Curfew' 2>/dev/null | tr '\n' ' ')
echo "  installed app:    ${app_pids:-not running}  (the product — never stopped here)"

test_pids=$(ps -Axo pid=,command= 2>/dev/null | grep -E 'Curfew --(open-help|press|pane|render)' | grep -v grep | awk '{print $1}' | tr '\n' ' ')
echo "  test instances:   ${test_pids:-none}"
if [ -n "$test_pids" ] && [ "$LIVE" -eq 1 ]; then
  for p in $test_pids; do kill -TERM "$p" 2>/dev/null && say "stopped test instance $p"; done
  echo "  → stopped"
fi

echo ""
echo "== 2. orphans =="
"$ROOT/scripts/reap-orphans.sh" 2>/dev/null | sed 's/^/  /'
[ "$LIVE" -eq 1 ] && "$ROOT/scripts/reap-orphans.sh" --live >/dev/null 2>&1 && say "reaped orphans live"

echo ""
echo "== 3. the disk =="
"$ROOT/scripts/repo-hygiene.sh" --report 2>/dev/null | sed 's/^/  /'

shots=$(ls /tmp/*.png 2>/dev/null | wc -l | tr -d ' ')
shot_k=0
for f in /tmp/*.png; do [ -f "$f" ] && shot_k=$((shot_k + $(size_of "$f"))); done
echo ""
echo "  session captures in /tmp: ${shots} file(s), $(mb "$shot_k") MB   (copies live in docs/evidence/)"
if [ "$LIVE" -eq 1 ] && [ "$shots" -gt 0 ]; then
  rm -f /tmp/*.png; say "removed $shots session capture(s), ${shot_k}K"
  echo "  → removed"
fi

echo ""
echo "== 4. what Curfew itself grew (records — reported, never deleted) =="
for item in "journal.jsonl" "decisions.jsonl" "disagreements.jsonl"; do
  f="$STATE/$item"
  if [ -f "$f" ]; then
    printf '  %-22s %8s KB   modified %s\n' "$item" "$(awk -v b="$(stat -f %z "$f")" 'BEGIN{printf "%.0f", b/1024}')" "$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$f")"
  else
    printf '  %-22s %8s\n' "$item" "absent"
  fi
done
q="$STATE/quarantine"
if [ -d "$q" ]; then
  entries=$(ls -1 "$q" 2>/dev/null | wc -l | tr -d ' ')
  printf '  %-22s %8s KB   %s entr(ies)\n' "quarantine/" "$(size_of "$q")" "$entries"
  old=$(find "$q" -maxdepth 1 -mindepth 1 -mtime +30 2>/dev/null | wc -l | tr -d ' ')
  [ "$old" -gt 0 ] && echo "  note: $old quarantine entr(ies) older than 30 days — they are the owner's to keep or restore"
else
  printf '  %-22s %8s\n' "quarantine/" "absent"
fi

echo ""
if [ "$LIVE" -eq 1 ]; then
  echo "close: applied. Records above were left intact."
else
  echo "close: report only — nothing was stopped or removed. Add --live to apply legs 1 and 3."
fi
