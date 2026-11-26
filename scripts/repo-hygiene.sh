#!/bin/bash
# repo-hygiene.sh — Curfew's copy of the projects-wide habit from fleet
# (docs/plans/2026-10-27-projects-repo-hygiene.md).
#
# Prune regenerable artifact directories from a repo whose work has gone stale, and report the numbers.
# The rules are the fleet pass's, unchanged:
#
#   - The artifact list is CLOSED. Curfew's build outputs are the ones SwiftPM and `make app` write:
#       .build        the SwiftPM build directory (debug + release + module cache)
#       build         the .app bundle `make app` assembles
#       .swiftpm      SwiftPM's own scratch
#     `.build` holds the only binary the test suite runs and `build/` holds the only copy of the app
#     before it is installed — but both are reproduced by `make app` / `swift build`, so both are
#     artifacts, not sources. Anything else found is NAMED in the log, never removed.
#   - A repo is stale when its last commit is older than STALE_DAYS (21); an artifact dir is prunable
#     when its mtime is older than MTIME_DAYS (14). BOTH must hold, so an active repo's hot artifacts
#     survive even when its last commit is old.
#   - Uncommitted work is never touched: only the listed directories are, and a dirty tree is reported.
#
# Modes:
#   --report   the survey (default; changes nothing)
#   --dry-run  what --live would do, named
#   --live     apply, logging each action with its size
#   --purge P  one named artifact dir, verified against the list and the repo, then removed
#   --root D   the repository (default: this repo)

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="report"
STATE="$HOME/Library/Application Support/Curfew/repo-hygiene.state"
LOG="$HOME/Library/Logs/curfew-repo-hygiene.log"
STALE_DAYS=21
MTIME_DAYS=14

# The closed list. Extending it is a plan decision, not a whim.
ARTIFACTS=".build build .swiftpm"

while [ $# -gt 0 ]; do
  case "$1" in
    --report|--dry-run|--live) MODE="${1#--}"; shift ;;
    --purge) MODE="purge"; PURGE="${2:-}"; shift 2 ;;
    --root) ROOT="${2:-}"; shift 2 ;;
    *) echo "repo-hygiene: unknown argument $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$(dirname "$LOG")"
say() { printf '%s\n' "$*" >> "$LOG"; }

now=$(date +%s)
day=$((60 * 60 * 24))

dir_age_days() {
  local m
  m=$(stat -f %m "$1" 2>/dev/null || echo "$now")
  echo $(( (now - m) / day ))
}

commit_age_days() {
  local t
  t=$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null)
  [ -z "$t" ] && { echo 9999; return; }
  echo $(( (now - t) / day ))
}

on_list() {
  local a
  for a in $ARTIFACTS; do [ "$1" = "$a" ] && return 0; done
  return 1
}

sizeof_k() { du -sk "$1" 2>/dev/null | awk '{print $1 + 0}'; }
mb() { awk "BEGIN{printf \"%.1f\", $1/1024}"; }

git_days=$(commit_age_days)
churn=$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')

if [ "$MODE" = "report" ]; then
  printf '%-34s %10s %12s %9s\n' ARTIFACT SIZE AGE_DAYS ON_LIST
  for a in $ARTIFACTS; do
    [ -d "$ROOT/$a" ] || continue
    printf '%-34s %9sM %12s %9s\n' "$a" "$(mb "$(sizeof_k "$ROOT/$a")")" "$(dir_age_days "$ROOT/$a")" yes
  done
  total=0
  for a in $ARTIFACTS; do [ -d "$ROOT/$a" ] && total=$((total + $(sizeof_k "$ROOT/$a"))); done
  echo ""
  echo "repo:      $(basename "$ROOT")"
  echo "last commit: ${git_days}d ago   stale threshold: ${STALE_DAYS}d"
  echo "artifact total: $(mb "$total") MB   prune threshold (mtime): ${MTIME_DAYS}d"
  echo "uncommitted: ${churn} path(s)  — never touched"
  exit 0
fi

if [ "$MODE" = "purge" ]; then
  p="${PURGE%/}"
  [ -n "$p" ] || { echo "repo-hygiene: --purge needs a path" >&2; exit 2; }
  case "$p" in "$ROOT"/*) ;; *) echo "repo-hygiene: $p is outside $ROOT — refused" >&2; exit 1 ;; esac
  on_list "$(basename "$p")" || { echo "repo-hygiene: $(basename "$p") is not on the artifact list — refused" >&2; exit 1; }
  [ -d "$p" ] || { echo "repo-hygiene: $p is not there" >&2; exit 1; }
  k=$(sizeof_k "$p"); rm -rf "$p"
  say "$(date -u +%FT%TZ) purge $p ${k}K"
  printf 'purged %s (%.1f MB)\n' "$p" "$(mb "$k")"
  exit 0
fi

# --dry-run / --live: the rules.
: >> "$LOG"
[ "$MODE" = "live" ] && say "# repo-hygiene live $(date -u +%FT%TZ)"
pruned_k=0; named=0
for a in $ARTIFACTS; do
  d="$ROOT/$a"
  [ -d "$d" ] || continue
  k=$(sizeof_k "$d"); age=$(dir_age_days "$d")
  if [ "$git_days" -lt "$STALE_DAYS" ]; then
    printf 'keep   %-22s %8sM  repo is active (%sd < %sd)\n' "$a" "$(mb "$k")" "$git_days" "$STALE_DAYS"
    continue
  fi
  if [ "$age" -lt "$MTIME_DAYS" ]; then
    printf 'keep   %-22s %8sM  warm (%sd < %sd)\n' "$a" "$(mb "$k")" "$age" "$MTIME_DAYS"
    continue
  fi
  if [ "$MODE" = "live" ]; then
    rm -rf "$d"; say "$(date -u +%FT%TZ) prune $d ${k}K (repo ${git_days}d, artifact ${age}d)"
    printf 'prune  %-22s %8sM  (repo %sd, artifact %sd)\n' "$a" "$(mb "$k")" "$git_days" "$age"
  else
    printf 'would  %-22s %8sM  (repo %sd, artifact %sd)\n' "$a" "$(mb "$k")" "$git_days" "$age"
  fi
  pruned_k=$((pruned_k + k))
done

# Anything not on the list is named, never removed — the generated/ lesson.
for d in "$ROOT"/*/; do
  [ -d "$d" ] || continue
  name=$(basename "$d")
  on_list "$name" && continue
  case "$name" in .git|Sources|Tests|catalog|docs|scripts) continue ;; esac
  [ "$(dir_age_days "$d")" -ge "$MTIME_DAYS" ] || continue
  k=$(sizeof_k "$d")
  [ "$k" -lt 1024 ] && continue          # under a megabyte is not worth a line
  echo "named  $name ($(mb "$k") MB) — not on the artifact list, left alone"
  named=$((named + 1))
done

echo ""
if [ "$MODE" = "live" ]; then
  echo "pruned $(mb "$pruned_k") MB · named ${named} unknown dir(s)"
else
  echo "would prune $(mb "$pruned_k") MB · named ${named} unknown dir(s) · nothing was removed"
fi
