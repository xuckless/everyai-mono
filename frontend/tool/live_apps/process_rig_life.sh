#!/bin/bash
# Dev only (macOS): the app's life and death with supervised children alive, on the process rig built as the app
# (tool/live_apps/process_rig.dart in RIG_MODE=life; its data folder is redirected, so the user's own data and
# ledger are never touched). Quit (a quit Apple event to that pid only), SIGTERM, SIGKILL (the watchdog), SIGKILL
# of the app and its watchdog (the next launch's sweep). Writes $1/results.json. Sends no input to the desktop.
#   flutter build macos --debug -t tool/live_apps/process_rig.dart
#   tool/live_apps/process_rig_life.sh /tmp/life
set -uo pipefail
OUT=${1:?usage: process_rig_life.sh <out dir>}
APPBIN="$(cd "$(dirname "$0")/../.." && pwd)/build/macos/Build/Products/Debug/EveryAI.app/Contents/MacOS/EveryAI"
DATA="$OUT/data"
mkdir -p "$OUT"
RESULTS="$OUT/results.jsonl"
: > "$RESULTS"

cat > "$OUT/quitpid.swift" <<'EOF'
import AppKit
let pid = pid_t(CommandLine.arguments[1])!
guard let app = NSRunningApplication(processIdentifier: pid) else { print("no app \(pid)"); exit(1) }
print("terminate \(pid): \(app.terminate())")
EOF
swiftc -O -o "$OUT/quitpid" "$OUT/quitpid.swift" || exit 1

now() { python3 -c 'import time; print(time.time())'; }
alive() { ps -o pid= -p "$(echo "$*" | tr ' ' ',')" 2>/dev/null | tr -s ' \n' ' ' | sed 's/^ //;s/ $//'; }
check() { # name passed evidence(json)
  python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "passed": sys.argv[2] == "1", "evidence": json.loads(sys.argv[3])}))' \
    "$1" "$2" "$3" >> "$RESULTS"
  echo "$([ "$2" = 1 ] && echo PASS || echo FAIL) $1"
}

# Starts the rig in life mode as case $1; sets APP C1 C2 GC WD.
launch() {
  mkdir -p "$OUT/$1"; rm -f "$OUT/$1/life.json"
  (cd "$OUT" && env -u EVERYAI_EXEC_HELPER RIG_OUT="$OUT/$1" RIG_DATA="$DATA" RIG_MODE=life "$APPBIN" \
    > "$OUT/$1/stdout.txt" 2>&1 &)
  for _ in $(seq 1 120); do [ -s "$OUT/$1/life.json" ] && break; sleep 0.5; done
  read -r APP C1 C2 GC WD < <(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); c=d["children"]
print(d["app"], c["shell"], c["ignores TERM"], c["grandchild"], d["watchdog"])' "$OUT/$1/life.json")
}

waitgone() { # seconds pids... -> prints elapsed when all are gone
  local limit=$1; shift; local t0; t0=$(now)
  for _ in $(seq 1 $((limit * 10))); do [ -z "$(alive "$@")" ] && break; sleep 0.1; done
  python3 -c "print(round($(now) - $t0, 2))"
}

quitjson() { cat "$DATA/processes/quit.json" 2>/dev/null || echo '"missing"'; }

# (a) quit
launch a
"$OUT/quitpid" "$APP" > /dev/null
t=$(waitgone 10 "$APP"); t2=$(waitgone 10 "$C1" "$C2" "$GC" "$WD")
left=$(alive "$C1" "$C2" "$GC" "$WD")
q=$(quitjson)
ok=0; [ -z "$left" ] && echo "$q" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if not d["survived"] and not d["scanFailed"] and len(d["ended"]) == 2 else 1)' && ok=1
check "3a quit (quit event): children ended, quit.json clean" $ok \
  "{\"app gone s\": $t, \"left\": \"$left\", \"quit.json\": $q, \"ledger files\": \"$(ls "$DATA/processes" | tr '\n' ' ')\"}"

# (b) SIGTERM
launch b
kill -TERM "$APP"
t=$(waitgone 10 "$APP"); waitgone 10 "$C1" "$C2" "$GC" "$WD" > /dev/null
left=$(alive "$C1" "$C2" "$GC" "$WD"); q=$(quitjson)
ok=0; [ -z "$left" ] && grep -q "$C2" <<< "$q" && echo "$q" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if not d["survived"] else 1)' && ok=1
check "3b SIGTERM: same quit sequence, children ended" $ok \
  "{\"app gone s\": $t, \"left\": \"$left\", \"quit.json\": $q, \"steps logged\": $(grep -c 'Quit: ' "$OUT/b/stdout.txt")}"

# (c) SIGKILL: the watchdog ends every group, the TERM-ignoring child's grandchild too
launch c
kill -KILL "$APP"
t=$(waitgone 15 "$C1" "$C2" "$GC")
left=$(alive "$C1" "$C2" "$GC")
ok=0; [ -z "$left" ] && ok=1
check "3c SIGKILL: the watchdog ends the children (incl. grandchild)" $ok \
  "{\"children gone s after SIGKILL\": $t, \"left\": \"$left\", \"pids\": \"$C1 $C2 $GC\", \"watchdog\": $WD}"
waitgone 10 "$WD" > /dev/null

# (d) SIGKILL of the app and its watchdog: children survive; the next launch's sweep ends them
launch d
kill -KILL "$WD"; kill -KILL "$APP"; sleep 3
survivors=$(alive "$C1" "$C2" "$GC"); S1=$C1; S2=$C2; S3=$GC
launch e
left=$(alive "$S1" "$S2" "$S3")
sweep=$(cat "$OUT"/e/sweep-*.json)
ok=0; [ "$survivors" = "$S1 $S2 $S3" ] && [ -z "$left" ] && grep -q "Cleaned up 3 processes" <<< "$sweep" && ok=1
check "3d app + watchdog killed: children survive, the next launch sweeps them" $ok \
  "{\"survived the kill\": \"$survivors\", \"left after relaunch\": \"$left\", \"sweep\": $sweep}"
"$OUT/quitpid" "$APP" > /dev/null
waitgone 10 "$APP" "$C1" "$C2" "$GC" "$WD" > /dev/null

python3 -c 'import json,sys; print(json.dumps([json.loads(l) for l in open(sys.argv[1])], indent=2))' "$RESULTS" \
  > "$OUT/results.json"
echo "left running: '$(alive "$APP" "$C1" "$C2" "$GC" "$WD")'"
