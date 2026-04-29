#!/bin/bash
# =============================================================================
# monitor.sh — Linux system resource logger (CPU, memory, power, GPU)
# Usage:
#   ./monitor.sh                        # logs to auto-named file, runs until Ctrl+C
#   ./monitor.sh -o my_run.csv          # custom output file
#   ./monitor.sh -i 2                   # sample every 2 seconds (default: 1)
#   ./monitor.sh -d 60                  # run for 60 seconds then stop
#   ./monitor.sh -o out.csv -i 1 -d 30  # combine options
# =============================================================================

# intentionally no set -euo pipefail — we handle errors per-command instead
# so a single failed tool doesn't kill the whole script

# ── defaults ──────────────────────────────────────────────────────────────────
INTERVAL=1
DURATION=0
OUTFILE=""

# ── argument parsing ──────────────────────────────────────────────────────────
usage() {
  echo "Usage: $0 [-o output.csv] [-i interval_seconds] [-d duration_seconds]"
  exit 1
}

while getopts "o:i:d:h" opt; do
  case $opt in
    o) OUTFILE="$OPTARG" ;;
    i) INTERVAL="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

if [[ -z "$OUTFILE" ]]; then
  OUTFILE="monitor_$(date +%Y%m%d_%H%M%S).csv"
fi

# ── detect available tools ────────────────────────────────────────────────────
HAS_NVIDIA=false
HAS_SENSORS=false
HAS_POWERSTAT=false

command -v nvidia-smi &>/dev/null && HAS_NVIDIA=true
command -v sensors    &>/dev/null && HAS_SENSORS=true
command -v powerstat  &>/dev/null && HAS_POWERSTAT=true

# use id -u instead of $EUID — more portable
IS_ROOT=false
if [[ "$(id -u)" -eq 0 ]]; then
  IS_ROOT=true
fi

if $HAS_POWERSTAT && ! $IS_ROOT; then
  echo "Warning: powerstat needs sudo for power readings. Re-run with sudo for wattage."
  HAS_POWERSTAT=false
fi

echo "=============================================="
echo " monitor.sh — System Resource Logger"
echo "=============================================="
echo " Output file : $OUTFILE"
echo " Interval    : ${INTERVAL}s"
echo " Duration    : $([ "$DURATION" -eq 0 ] && echo 'until Ctrl+C' || echo "${DURATION}s")"
echo "----------------------------------------------"
echo " CPU usage   : yes (via /proc)"
echo " CPU freq    : yes (via /sys/cpufreq)"
echo " CPU temp    : $HAS_SENSORS (via lm-sensors)"
echo " Memory      : yes (via free)"
echo " Power (W)   : $HAS_POWERSTAT (via RAPL)"
echo " GPU         : $HAS_NVIDIA (via nvidia-smi)"
echo "=============================================="
echo ""

# ── cleanup ───────────────────────────────────────────────────────────────────
cleanup() {
  echo ""
  echo "Stopping..."
  echo "Saved to: $OUTFILE"
  exit 0
}
trap cleanup SIGINT SIGTERM

# ── CSV header ────────────────────────────────────────────────────────────────
build_header() {
  local h="timestamp,elapsed_s"
  h+=",cpu_usr_pct,cpu_sys_pct,cpu_idl_pct,cpu_wai_pct"
  h+=",cpu_freq_mhz_avg,cpu_freq_mhz_min,cpu_freq_mhz_max"
  h+=",mem_total_mb,mem_used_mb,mem_free_mb,mem_cache_mb,swap_used_mb"
  h+=",load_1m,load_5m,load_15m"
  h+=",procs_running,procs_total"
  if $HAS_POWERSTAT; then
    h+=",cpu_power_w"
  fi
  if $HAS_SENSORS; then
    h+=",cpu_temp_c"
  fi
  if $HAS_NVIDIA; then
    h+=",gpu_util_pct,gpu_mem_used_mb,gpu_mem_total_mb,gpu_power_w,gpu_temp_c,gpu_clock_mhz,gpu_mem_clock_mhz"
  fi
  echo "$h"
}

build_header > "$OUTFILE"

# ── helper: cpu usage ─────────────────────────────────────────────────────────
# handles both "%Cpu(s): X.X us" and "%Cpu: X.X us" formats
get_cpu_usage() {
  top -bn1 | grep -E "^(%Cpu|Cpu)" | head -1 | \
    awk '{
      for(i=1;i<=NF;i++) {
        if ($i=="us,") usr=$(i-1)
        if ($i=="sy,") sys=$(i-1)
        if ($i=="id,") idl=$(i-1)
        if ($i=="wa,") wai=$(i-1)
      }
      printf "%s,%s,%s,%s", usr, sys, idl, wai
    }'
}

# ── helper: cpu freq ──────────────────────────────────────────────────────────
get_cpu_freq() {
  local freqs=()
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
    [[ -f "$f" ]] && freqs+=( "$(cat "$f")" )
  done
  if [[ ${#freqs[@]} -eq 0 ]]; then
    echo "0,0,0"; return
  fi
  local sum=0 min=${freqs[0]} max=${freqs[0]}
  for v in "${freqs[@]}"; do
    sum=$(( sum + v ))
    (( v < min )) && min=$v
    (( v > max )) && max=$v
  done
  local avg=$(( sum / ${#freqs[@]} ))
  echo "$(( avg / 1000 )),$(( min / 1000 )),$(( max / 1000 ))"
}

# ── helper: cpu temp ──────────────────────────────────────────────────────────
get_cpu_temp() {
  local temp
  temp=$(sensors 2>/dev/null \
    | grep -E "Tctl|Package id 0|CPU Temperature" \
    | head -1 | grep -oP '[0-9]+\.[0-9]+' | head -1)
  echo "${temp:-0}"
}

# ── helper: cpu power via RAPL direct read ────────────────────────────────────
# state is stored in tmp files because subshell calls lose global variable updates
RAPL_PATH=""
RAPL_STATE_FILE=""

find_rapl_path() {
  if [[ -f /sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj ]]; then
    RAPL_PATH="/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj"
  else
    RAPL_PATH=$(find /sys/class/powercap/ -name "energy_uj" 2>/dev/null | head -1 || true)
  fi
  RAPL_STATE_FILE=$(mktemp /tmp/rapl_state.XXXXXX)
  # seed initial state: energy_uj timestamp_ns
  echo "$(cat "$RAPL_PATH") $(date +%s%N)" > "$RAPL_STATE_FILE"
}

get_cpu_power() {
  [[ -z "$RAPL_PATH" || -z "$RAPL_STATE_FILE" ]] && { echo "0"; return; }
  [[ ! -f "$RAPL_PATH" || ! -f "$RAPL_STATE_FILE" ]] && { echo "0"; return; }

  local curr_energy curr_time prev_energy prev_time elapsed_ns energy_uj watts
  curr_energy=$(cat "$RAPL_PATH" 2>/dev/null) || { echo "0"; return; }
  curr_time=$(date +%s%N)

  read -r prev_energy prev_time < "$RAPL_STATE_FILE"

  elapsed_ns=$(( curr_time - prev_time ))
  energy_uj=$(( curr_energy - prev_energy ))

  # update state file for next call
  echo "$curr_energy $curr_time" > "$RAPL_STATE_FILE"

  if [[ $energy_uj -le 0 || $elapsed_ns -eq 0 ]]; then
    echo "0"
  else
    watts=$(awk "BEGIN {printf \"%.2f\", ($energy_uj / ($elapsed_ns / 1000))}")
    echo "$watts"
  fi
}

# ── init ──────────────────────────────────────────────────────────────────────
if $HAS_POWERSTAT; then
  find_rapl_path
  if [[ -z "$RAPL_PATH" ]]; then
    echo "Warning: no RAPL energy path found, power readings unavailable."
    HAS_POWERSTAT=false
  else
    echo "RAPL path: $RAPL_PATH"
  fi
fi

START_TIME=$(date +%s)

echo "Logging... (Ctrl+C to stop)"
echo ""

# ── main loop ─────────────────────────────────────────────────────────────────
while true; do
  NOW=$(date +%s)
  ELAPSED=$(( NOW - START_TIME ))
  TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

  # cpu usage
  cpu_usage=$(get_cpu_usage)
  cpu_idl=$(echo "$cpu_usage" | cut -d, -f3)

  # cpu freq
  cpu_freq=$(get_cpu_freq)

  # memory
  mem=$(free -m | awk '
    /^Mem:/  { printf "%s,%s,%s,%s,", $2, $3, $4, $6 }
    /^Swap:/ { print $3 }
  ')

  # load + procs
  read -r load1 load5 load15 procs _ < /proc/loadavg
  procs_running="${procs%/*}"
  procs_total="${procs#*/}"

  # build row
  ROW="\"$TIMESTAMP\",$ELAPSED"
  ROW+=",$cpu_usage"
  ROW+=",$cpu_freq"
  ROW+=",$mem"
  ROW+=",$load1,$load5,$load15"
  ROW+=",$procs_running,$procs_total"

  # cpu power
  if $HAS_POWERSTAT; then
    ROW+=",$(get_cpu_power)"
  fi

  # cpu temp
  if $HAS_SENSORS; then
    ROW+=",$(get_cpu_temp)"
  fi

  # gpu
  if $HAS_NVIDIA; then
    gpu=$(nvidia-smi \
      --query-gpu=utilization.gpu,memory.used,memory.total,power.draw,temperature.gpu,clocks.sm,clocks.mem \
      --format=csv,noheader,nounits 2>/dev/null \
      | head -1 | tr -d ' ' | sed 's/W//') || gpu="0,0,0,0,0,0,0"
    ROW+=",$gpu"
  fi

  echo "$ROW" >> "$OUTFILE"

  # live terminal summary
  printf "\r[+%3ds] CPU: %s%% idle | Freq: %s MHz | RAM: %s MB used | Load: %s" \
    "$ELAPSED" "$cpu_idl" "$(echo "$cpu_freq" | cut -d, -f1)" \
    "$(echo "$mem" | cut -d, -f2)" "$load1"

  # duration check
  if [[ "$DURATION" -gt 0 && "$ELAPSED" -ge "$DURATION" ]]; then
    cleanup
  fi

  sleep "$INTERVAL"
done
