#!/bin/bash
# reap-orphans.sh — stop keep-alive processes whose parent is gone.
#
# From the 2026-11-21 incident on this machine: 1,232 orphaned `tail -f /dev/null` keep-alives (ppid 1,
# 580 MB RSS, 46% of maxprocperuid) had accumulated over ~55 days, leaving ~95 MB free RAM and 5.7 GB of
# swap in use. A keep-alive's whole job is to outlive something; when the something is gone, the
# keep-alive is litter that costs memory until the next reboot.
#
# The rules, and they are deliberately narrow:
#
#   - The command must match EXACTLY (default: "tail -f /dev/null"). A near-match is never touched: this
#     script must not guess what a process was for.
#   - The parent must be gone (ppid 1). A process with a live parent is never touched — its owner may be
#     about to read from it.
#   - The process must be yours. Another user's processes are none of this script's business.
#   - Dry run by default; --live is required to signal anything, and every signal is logged with the RSS
#     released.
#
# Modes:
#   (none)          report what matches, change nothing
#   --live          SIGTERM the matches, then report what is left
#   --command CMD   match this exact command instead (quoted)
#
# Exit: 0 always — a report that finds nothing is a success.

set -u

MATCH="tail -f /dev/null"
LIVE=0
LOG="$HOME/Library/Logs/curfew-reap-orphans.log"

while [ $# -gt 0 ]; do
  case "$1" in
    --live) LIVE=1; shift ;;
    --command) MATCH="${2:-}"; shift 2 ;;
    *) echo "reap-orphans: unknown argument $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$(dirname "$LOG")"
me=$(id -u)
mb() { awk -v k="$1" 'BEGIN{printf "%.1f", k/1024}'; }
say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

# pid, ppid, uid, rss(KB), command — command last because it contains spaces.
rows=$(ps -Axo pid=,ppid=,uid=,rss=,command= 2>/dev/null | awk -v want="$MATCH" -v me="$me" '
  {
    pid=$1; ppid=$2; uid=$3; rss=$4
    cmd=$0
    sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+/, "", cmd)
    if (ppid == 1 && uid == me && cmd == want) printf "%s %s %s\n", pid, rss, cmd
  }')

count=$(printf '%s' "$rows" | grep -c . || true)
total_k=$(printf '%s' "$rows" | awk '{s+=$2} END{print s+0}')

echo "pattern : $MATCH"
echo "orphans : ${count} process(es), $(mb "$total_k") MB RSS"

if [ "$count" -eq 0 ]; then
  echo "nothing to reap"
  exit 0
fi

if [ "$LIVE" -eq 0 ]; then
  printf '%s\n' "$rows" | awk '{printf "  pid %-8s %6.1f MB  %s\n", $1, $2/1024, substr($0, index($0,$3))}'
  echo ""
  echo "dry run — nothing was signalled. Add --live to stop these."
  exit 0
fi

stopped=0; freed=0
while read -r pid rss _rest; do
  [ -n "$pid" ] || continue
  if kill -TERM "$pid" 2>/dev/null; then
    stopped=$((stopped + 1)); freed=$((freed + rss))
    say "reaped pid $pid (${rss}K)"
  else
    say "could not signal pid $pid"
  fi
done <<< "$rows"

sleep 1
left=$(ps -Axo pid=,ppid=,uid=,command= 2>/dev/null | awk -v want="$MATCH" -v me="$me" '
  { cmd=$0; sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[0-9]+[ \t]+/, "", cmd)
    if ($2 == 1 && $3 == me && cmd == want) n++ } END{print n+0}')
echo "reaped ${stopped} process(es), $(mb "$freed") MB RSS released · ${left} left"
say "live run: ${stopped} reaped, ${freed}K released, ${left} left"
