#!/bin/zsh
# FanPilot soak test (plan §12, hardware check 8): leave FanPilot in Daily and run this.
# Usage: scripts/soak.sh [hours]   (default 8)
# Read-only: samples memory/CPU of the app and helper, the helper PID (restarts), and fan mode/RPM
# every 30 s, then summarizes memory growth and engage/release cycles. Keeps the Mac awake.
HOURS=${1:-8}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTL="$(swift build --package-path "$ROOT/Packages/FanCore" --product fanpilotctl --show-bin-path 2>/dev/null)/fanpilotctl"
[[ -x $CTL ]] || { echo "Build fanpilotctl first: swift build --package-path Packages/FanCore --product fanpilotctl"; exit 1 }
OUT="${TMPDIR:-/tmp}/fanpilot-soak-$(date +%Y%m%d-%H%M%S).csv"
SECS=$((HOURS*3600))
/usr/bin/caffeinate -i -t $((SECS+120)) &
CAF=$!
trap 'kill $CAF 2>/dev/null' EXIT
echo "epoch,app_rss_kb,app_cpu,helper_pid,helper_rss_kb,helper_cpu,fan0_mode,fan1_mode,fan0_rpm,fan1_rpm,max_temp" > "$OUT"
echo "Soak log: $OUT"
START=$SECONDS
while (( SECONDS - START < SECS )); do
  AP=$(pgrep -x FanPilot | head -1); HP=$(pgrep -f /Library/PrivilegedHelperTools/com.fanpilot.helper | head -1)
  A=$(ps -o rss=,%cpu= -p "${AP:-0}" 2>/dev/null | awk '{print $1","$2}'); : ${A:=,}
  H=$(ps -o rss=,%cpu= -p "${HP:-0}" 2>/dev/null | awk '{print $1","$2}'); : ${H:=,}
  D=$($CTL dump 2>/dev/null)
  F0=$(print -r -- "$D" | grep -E "^  (Left|Fan 1)" | head -1); F1=$(print -r -- "$D" | grep -E "^  (Right|Fan 2)" | head -1)
  m() { print -r -- "$1" | sed -E 's/.*mode ([0-9]+).*/\1/'; }; r() { print -r -- "$1" | sed -E 's/^[^:]*: ([0-9]+) RPM.*/\1/'; }
  T=$(print -r -- "$D" | grep "Control temperature" | sed -E 's/.*: ([0-9.]+).*/\1/')
  echo "$(date +%s),$A,${HP:-},$H,$(m "$F0"),$(m "$F1"),$(r "$F0"),$(r "$F1"),$T" >> "$OUT"
  sleep 30
done
python3 - "$OUT" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
def col(k): return [float(r[k]) for r in rows if r[k] not in ("", None)]
n = len(rows); q = max(1, n // 10)
for name, key in (("app", "app_rss_kb"), ("helper", "helper_rss_kb")):
    v = col(key)
    if v: print(f"{name} RSS: first-10% mean {sum(v[:q])/q/1024:.1f} MB -> last-10% mean {sum(v[-q:])/q/1024:.1f} MB (max {max(v)/1024:.1f} MB)")
pids = {r["helper_pid"] for r in rows}
print(f"samples {n}; distinct helper PIDs {len(pids)} (1 = no restarts)")
modes = [r["fan0_mode"] for r in rows]
flips = sum(1 for a, b in zip(modes, modes[1:]) if a != b)
print(f"fan0 mode transitions: {flips}; time in manual (mode 1): {sum(m=='1' for m in modes)/max(n,1):.0%}")
PY
