#!/bin/zsh
# FanPilot sustained-load acceptance test (plan §12, hardware check 3).
# Select Daily (or Turbo) in FanPilot first, then run:  scripts/loadtest.sh [minutes] [abort_celsius]
# Spawns one CPU burner per core, logs temperature / fan RPM / kernel_task CPU every 5 s to a CSV,
# and stops the load early if the hottest sensor reaches abort_celsius (default 105).
MINUTES=${1:-20}; ABORT=${2:-105}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CTL="$(swift build --package-path "$ROOT/Packages/FanCore" --product fanpilotctl --show-bin-path 2>/dev/null)/fanpilotctl"
[[ -x $CTL ]] || { echo "Build fanpilotctl first: swift build --package-path Packages/FanCore --product fanpilotctl"; exit 1 }
OUT="${TMPDIR:-/tmp}/fanpilot-loadtest-$(date +%Y%m%d-%H%M%S).csv"
CORES=$(sysctl -n hw.ncpu); PIDS=()
cleanup() { for p in $PIDS; do kill $p 2>/dev/null; done; echo "Load stopped. Log: $OUT" }
trap cleanup EXIT INT TERM
echo "elapsed_s,max_temp_c,fan0_rpm,fan1_rpm,fan0_mode,kernel_task_cpu" > "$OUT"
for i in $(seq $CORES); do yes > /dev/null & PIDS+=($!); done
echo "Running $CORES burners for $MINUTES min (abort at ${ABORT}°C)…"
END=$((SECONDS + MINUTES*60)); START=$SECONDS
while (( SECONDS < END )); do
  J=$($CTL dump --json)
  ROW=$(print -r -- "$J" | python3 "$(dirname "$0")/_row.py")
  KT=$(top -l 2 -s 1 -pid 0 -stats pid,cpu 2>/dev/null | awk '$1==0{v=$2} END{print v}')
  echo "$((SECONDS-START)),$ROW,$KT" | tee -a "$OUT"
  T=${${ROW%%,*}%.*}
  if [[ -n $T ]] && (( T >= ABORT )); then echo "ABORT: ${T}°C reached"; exit 2; fi
  sleep 5
done
echo "Completed $MINUTES minutes."
