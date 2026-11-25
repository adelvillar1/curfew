#!/bin/bash
# L3.5 — the live crash test.
#
# Kills `curfew apply --execute` with SIGKILL *between* the journal intent and the outcome, then asks
# the tool to recover. The stop recipe is `/bin/sleep 5` and the start recipe `/bin/true`, so nothing
# on this machine is touched: the only real state is the journal.
#
# Usage: scripts/crash-test.sh [path-to-curfew-binary]

set -u

CURFEW="${1:-.build/debug/curfew}"
[ -x "$CURFEW" ] || { echo "no curfew binary at $CURFEW — build first"; exit 2; }
CURFEW="$(cd "$(dirname "$CURFEW")" && pwd)/$(basename "$CURFEW")"

WORK="$(mktemp -d /tmp/curfew-crash.XXXXXX)"
CATALOG="$WORK/catalog"
JOURNAL="$WORK/journal.jsonl"
mkdir -p "$CATALOG"
trap 'rm -rf "$WORK"; [ -n "${SLEEP_PID:-}" ] && kill "$SLEEP_PID" 2>/dev/null' EXIT

cat > "$CATALOG/crash.yaml" <<'YAML'
entries:
  - id: com.curfew.crash-test
    kind: agent
    lever: disable
    supervised: launchd
    status: verified
    evidence: "2026-11-24 · this Mac · crash-test harness, not a real service"
    hazards: []
    stop:
      run: [/bin/sleep, 5]
      verify:
        kind: label_not_running
        value: com.curfew.crash-test
    start:
      run: [/usr/bin/true]
      meansReady: nothing — this is a harness
YAML

cat > "$CATALOG/bundles.yaml" <<'YAML'
bundles:
  - name: crash-test
    kind: stop
    summary: a harness bundle that stops nothing real
    members: [com.curfew.crash-test]
YAML

fail() { echo "FAIL: $1"; exit 1; }

echo "== 1. start an apply and kill it mid-action =="
CURFEW_JOURNAL="$JOURNAL" "$CURFEW" apply --bundle crash-test --execute --yes --dir "$CATALOG" > "$WORK/apply.log" 2>&1 &
APPLY_PID=$!
# Wait for the intent to land, not for a fixed delay: the executor runs a full inventory (~1.2 s)
# before it writes anything, and killing before the intent would test nothing.
for _ in $(seq 1 150); do
  [ -s "$JOURNAL" ] && grep -q '"kind":"intent"' "$JOURNAL" 2>/dev/null && break
  sleep 0.1
done
grep -q '"kind":"intent"' "$JOURNAL" 2>/dev/null || fail "no intent appeared — nothing to crash"
kill -9 "$APPLY_PID" 2>/dev/null
wait "$APPLY_PID" 2>/dev/null
echo "   killed pid $APPLY_PID; journal has $(wc -l < "$JOURNAL" 2>/dev/null || echo 0) record(s)"

echo "== 2. the machine is left holding an unresolved intent =="
STATUS=$(CURFEW_JOURNAL="$JOURNAL" "$CURFEW" status --json)
UNRESOLVED=$(printf '%s' "$STATUS" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["unresolved"]))')
[ "$UNRESOLVED" = "1" ] || fail "expected 1 unresolved intent after SIGKILL, got $UNRESOLVED"
echo "   unresolved after crash: $UNRESOLVED"

echo "== 3. a second apply is refused while the journal is unwritable? (sanity: journal is writable) =="
CURFEW_JOURNAL="$JOURNAL" "$CURFEW" status > /dev/null 2>&1 && echo "   status reads fine" || echo "   status exited non-zero (expected: unresolved present)"

echo "== 4. resume puts the machine back =="
CURFEW_JOURNAL="$JOURNAL" "$CURFEW" resume --execute --yes --dir "$CATALOG" > "$WORK/resume.log" 2>&1 \
  || fail "resume failed: $(cat "$WORK/resume.log")"
grep -q "executed+verified" "$WORK/resume.log" || fail "resume did not execute the start recipe: $(cat "$WORK/resume.log")"

echo "== 5. nothing is left unresolved =="
AFTER=$(CURFEW_JOURNAL="$JOURNAL" "$CURFEW" status --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["unresolved"]))')
[ "$AFTER" = "0" ] || fail "expected 0 unresolved after resume, got $AFTER"
echo "   unresolved after resume: $AFTER"

echo "== 6. a second resume is a no-op =="
SECOND=$(CURFEW_JOURNAL="$JOURNAL" "$CURFEW" resume --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["outcomes"]))')
[ "$SECOND" = "0" ] || fail "a second resume did something ($SECOND outcomes)"
echo "   second resume outcomes: $SECOND"

echo
echo "PASS — SIGKILL between intent and outcome left the machine recoverable, and resume restored it"
