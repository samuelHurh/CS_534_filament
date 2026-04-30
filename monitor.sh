#!/bin/bash
# =============================================================================
# monitor.sh - Timed benchmark runner + Linux system resource logger
#
# Default behavior:
#   - launches gltf_viewer with Sponza scene
#   - logs metrics for 60 seconds
#   - writes CSV and stops gltf_viewer
#
# Usage examples:
#   ./monitor.sh
#   ./monitor.sh --runtime 90
#   ./monitor.sh --runtime 60 --foveation --foveal-radius 0.2 --peripheral-radius 0.35 \
#     --transition-keep 0.5 --outer-keep 0.125
#   ./monitor.sh --lock-fovea-center
#   ./monitor.sh -o run.csv --interval 2 --camera orbit
#   ./monitor.sh --output-dir logs
#   ./monitor.sh --viewer /path/to/gltf_viewer --scene /path/to/model.gltf
# =============================================================================

# intentionally no set -euo pipefail - we handle per command to keep logging resilient

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Defaults
INTERVAL=1
DURATION=60
OUTFILE=""
OUTPUT_DIR=""

VIEWER="${SCRIPT_DIR}/out/cmake-debug/samples/gltf_viewer"
SCENE="${SCRIPT_DIR}/external-gltf-assets/Models/Sponza/glTF/Sponza.gltf"
API="opengl"
ACTUAL_SIZE=true
CAMERA_MODE="flight"

HIDE_LEFT_PANEL=false
FORWARD_ARGS=()

ENABLE_FOVEATION=false
DISABLE_FOVEATION=false
LOCK_FOVEA_CENTER=false
FOVEAL_RADIUS=""
PERIPHERAL_RADIUS=""
TRANSITION_KEEP=""
OUTER_KEEP=""

VIEWER_PID=""
RAPL_PATH=""
RAPL_STATE_FILE=""

# Tool availability
HAS_NVIDIA=false
HAS_SENSORS=false
HAS_POWERSTAT=false

usage() {
  cat <<EOF
Usage:
  $0 [options]

Benchmark options:
  --runtime SECONDS          Benchmark duration (default: 60)
  --viewer PATH              gltf_viewer binary path
  --scene PATH               glTF scene path
  --api BACKEND              Render backend passed as -a (default: opengl)
  --camera MODE              Camera mode (default: flight)
  --no-actual-size           Do not pass -s to gltf_viewer
  --hide-left-panel          Start viewer with left UI panel hidden

Foveation options (all optional):
  --foveation
  --no-foveation
  --lock-fovea-center
  --foveal-radius VALUE
  --peripheral-radius VALUE
  --transition-keep VALUE
  --outer-keep VALUE

Monitoring options:
  -o, --output FILE          Output CSV path
  --output-dir DIR           Output directory for auto-named CSVs
  -i, --interval SECONDS     Sampling interval (default: 1)
  -d, --duration SECONDS     Alias for --runtime
  -h, --help                 Show this message
EOF
  exit 1
}

is_positive_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

slug_token() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}

float_token() {
  echo "$1" | sed -E 's/\./p/g; s/[^0-9p-]//g'
}

build_default_outfile() {
  local timestamp fov_state actual_size_token
  local parts=()

  timestamp="$(date +%Y%m%d_%H%M%S)"

  if $ENABLE_FOVEATION; then
    fov_state="on"
  elif $DISABLE_FOVEATION; then
    fov_state="off"
  else
    fov_state="default"
  fi

  if $ACTUAL_SIZE; then
    actual_size_token="asz1"
  else
    actual_size_token="asz0"
  fi

  parts+=("monitor")
  parts+=("rt${DURATION}s")
  parts+=("i$(float_token "$INTERVAL")s")
  parts+=("api-$(slug_token "$API")")
  parts+=("cam-$(slug_token "$CAMERA_MODE")")
  parts+=("${actual_size_token}")
  parts+=("fov-${fov_state}")
  if $LOCK_FOVEA_CENTER; then
    parts+=("fovea-center-on")
  fi

  if [[ -n "$FOVEAL_RADIUS" ]]; then
    parts+=("fr$(float_token "$FOVEAL_RADIUS")")
  fi
  if [[ -n "$PERIPHERAL_RADIUS" ]]; then
    parts+=("pr$(float_token "$PERIPHERAL_RADIUS")")
  fi
  if [[ -n "$TRANSITION_KEEP" ]]; then
    parts+=("tk$(float_token "$TRANSITION_KEEP")")
  fi
  if [[ -n "$OUTER_KEEP" ]]; then
    parts+=("ok$(float_token "$OUTER_KEEP")")
  fi

  parts+=("${timestamp}")

  local joined
  joined="$(IFS=_; echo "${parts[*]}")"
  echo "${joined}.csv"
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output)
      [[ -n "${2:-}" ]] || usage
      OUTFILE="$2"
      shift 2
      ;;
    --output-dir)
      [[ -n "${2:-}" ]] || usage
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -i|--interval)
      [[ -n "${2:-}" ]] || usage
      INTERVAL="$2"
      shift 2
      ;;
    --runtime|-d|--duration)
      [[ -n "${2:-}" ]] || usage
      DURATION="$2"
      shift 2
      ;;
    --viewer)
      [[ -n "${2:-}" ]] || usage
      VIEWER="$2"
      shift 2
      ;;
    --scene)
      [[ -n "${2:-}" ]] || usage
      SCENE="$2"
      shift 2
      ;;
    --api)
      [[ -n "${2:-}" ]] || usage
      API="$2"
      shift 2
      ;;
    --camera)
      [[ -n "${2:-}" ]] || usage
      CAMERA_MODE="$2"
      shift 2
      ;;
    --no-actual-size)
      ACTUAL_SIZE=false
      shift
      ;;
    --hide-left-panel)
      HIDE_LEFT_PANEL=true
      shift
      ;;
    --foveation)
      ENABLE_FOVEATION=true
      shift
      ;;
    --no-foveation)
      DISABLE_FOVEATION=true
      shift
      ;;
    --lock-fovea-center)
      LOCK_FOVEA_CENTER=true
      shift
      ;;
    --foveal-radius)
      [[ -n "${2:-}" ]] || usage
      FOVEAL_RADIUS="$2"
      shift 2
      ;;
    --peripheral-radius)
      [[ -n "${2:-}" ]] || usage
      PERIPHERAL_RADIUS="$2"
      shift 2
      ;;
    --transition-keep)
      [[ -n "${2:-}" ]] || usage
      TRANSITION_KEEP="$2"
      shift 2
      ;;
    --outer-keep)
      [[ -n "${2:-}" ]] || usage
      OUTER_KEEP="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      # Forward unknown options to the viewer.
      if [[ "$1" == --* ]] && [[ -n "${2:-}" ]] && [[ "${2:0:1}" != "-" ]]; then
        FORWARD_ARGS+=("$1" "$2")
        shift 2
      else
        FORWARD_ARGS+=("$1")
        shift
      fi
      ;;
  esac
done

if ! is_positive_number "$INTERVAL"; then
  echo "Error: interval must be a positive number."
  exit 1
fi

if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [[ "$DURATION" -le 0 ]]; then
  echo "Error: runtime/duration must be a positive integer in seconds."
  exit 1
fi

if [[ -n "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR" || {
    echo "Error: could not create output directory: $OUTPUT_DIR"
    exit 1
  }
fi

if [[ -z "$OUTFILE" ]]; then
  if [[ -n "$OUTPUT_DIR" ]]; then
    OUTFILE="${OUTPUT_DIR%/}/$(build_default_outfile)"
  else
    OUTFILE="$(build_default_outfile)"
  fi
elif [[ -n "$OUTPUT_DIR" && "$OUTFILE" != /* && "$OUTFILE" != */* ]]; then
  # If output-dir is provided and output is just a filename, place it in that directory.
  OUTFILE="${OUTPUT_DIR%/}/$OUTFILE"
fi

if [[ ! -x "$VIEWER" ]]; then
  echo "Error: gltf_viewer not found or not executable at: $VIEWER"
  echo "Tip: run ./build.sh debug first, or pass --viewer /path/to/gltf_viewer"
  exit 1
fi

if [[ ! -f "$SCENE" ]]; then
  echo "Error: scene file not found at: $SCENE"
  echo "Tip: pass --scene /path/to/your_scene.gltf"
  exit 1
fi

if $ENABLE_FOVEATION && $DISABLE_FOVEATION; then
  echo "Error: use only one of --foveation or --no-foveation."
  exit 1
fi

command -v nvidia-smi &>/dev/null && HAS_NVIDIA=true
command -v sensors &>/dev/null && HAS_SENSORS=true
command -v powerstat &>/dev/null && HAS_POWERSTAT=true

IS_ROOT=false
if [[ "$(id -u)" -eq 0 ]]; then
  IS_ROOT=true
fi

if $HAS_POWERSTAT && ! $IS_ROOT; then
  echo "Warning: powerstat/RAPL usually needs root for power readings; disabling CPU power metric."
  HAS_POWERSTAT=false
fi

cleanup() {
  local code=${1:-0}

  if [[ -n "$VIEWER_PID" ]] && kill -0 "$VIEWER_PID" 2>/dev/null; then
    kill "$VIEWER_PID" 2>/dev/null || true
    sleep 1
    if kill -0 "$VIEWER_PID" 2>/dev/null; then
      kill -9 "$VIEWER_PID" 2>/dev/null || true
    fi
  fi

  if [[ -n "$RAPL_STATE_FILE" && -f "$RAPL_STATE_FILE" ]]; then
    rm -f "$RAPL_STATE_FILE"
  fi

  echo
  echo "Saved metrics to: $OUTFILE"
  exit "$code"
}
trap 'cleanup 0' SIGINT SIGTERM

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

get_cpu_usage() {
  top -bn1 | grep -E "^(%Cpu|Cpu)" | head -1 | awk '{
    for(i=1;i<=NF;i++) {
      if ($i=="us,") usr=$(i-1)
      if ($i=="sy,") sys=$(i-1)
      if ($i=="id,") idl=$(i-1)
      if ($i=="wa,") wai=$(i-1)
    }
    printf "%s,%s,%s,%s", usr, sys, idl, wai
  }'
}

get_cpu_freq() {
  local freqs=()
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
    [[ -f "$f" ]] && freqs+=("$(cat "$f")")
  done
  if [[ ${#freqs[@]} -eq 0 ]]; then
    echo "0,0,0"
    return
  fi

  local sum=0
  local min=${freqs[0]}
  local max=${freqs[0]}
  local v
  for v in "${freqs[@]}"; do
    sum=$((sum + v))
    (( v < min )) && min=$v
    (( v > max )) && max=$v
  done
  local avg=$((sum / ${#freqs[@]}))
  echo "$((avg / 1000)),$((min / 1000)),$((max / 1000))"
}

get_cpu_temp() {
  local temp
  temp=$(sensors 2>/dev/null | grep -E "Tctl|Package id 0|CPU Temperature" | head -1 | grep -oP '[0-9]+\.[0-9]+' | head -1)
  echo "${temp:-0}"
}

find_rapl_path() {
  if [[ -f /sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj ]]; then
    RAPL_PATH="/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj"
  else
    RAPL_PATH=$(find /sys/class/powercap/ -name "energy_uj" 2>/dev/null | head -1 || true)
  fi

  RAPL_STATE_FILE=$(mktemp /tmp/rapl_state.XXXXXX)
  echo "$(cat "$RAPL_PATH") $(date +%s%N)" > "$RAPL_STATE_FILE"
}

get_cpu_power() {
  [[ -z "$RAPL_PATH" || -z "$RAPL_STATE_FILE" ]] && { echo "0"; return; }
  [[ ! -f "$RAPL_PATH" || ! -f "$RAPL_STATE_FILE" ]] && { echo "0"; return; }

  local curr_energy curr_time prev_energy prev_time elapsed_ns energy_uj watts

  curr_energy=$(cat "$RAPL_PATH" 2>/dev/null) || { echo "0"; return; }
  curr_time=$(date +%s%N)

  read -r prev_energy prev_time < "$RAPL_STATE_FILE"

  elapsed_ns=$((curr_time - prev_time))
  energy_uj=$((curr_energy - prev_energy))

  echo "$curr_energy $curr_time" > "$RAPL_STATE_FILE"

  if [[ $energy_uj -le 0 || $elapsed_ns -eq 0 ]]; then
    echo "0"
  else
    watts=$(awk "BEGIN {printf \"%.2f\", ($energy_uj / ($elapsed_ns / 1000))}")
    echo "$watts"
  fi
}

build_header > "$OUTFILE"

if $HAS_POWERSTAT; then
  find_rapl_path
  if [[ -z "$RAPL_PATH" ]]; then
    echo "Warning: no RAPL energy path found; power readings disabled."
    HAS_POWERSTAT=false
  fi
fi

GLTF_ARGS=("-a" "$API")
if $ACTUAL_SIZE; then
  GLTF_ARGS+=("-s")
fi
GLTF_ARGS+=("--camera" "$CAMERA_MODE")

if $ENABLE_FOVEATION; then
  GLTF_ARGS+=("--foveation")
fi
if $DISABLE_FOVEATION; then
  GLTF_ARGS+=("--no-foveation")
fi
if $LOCK_FOVEA_CENTER; then
  GLTF_ARGS+=("--lock-fovea-center")
fi
if [[ -n "$FOVEAL_RADIUS" ]]; then
  GLTF_ARGS+=("--foveal-radius" "$FOVEAL_RADIUS")
fi
if [[ -n "$PERIPHERAL_RADIUS" ]]; then
  GLTF_ARGS+=("--peripheral-radius" "$PERIPHERAL_RADIUS")
fi
if [[ -n "$TRANSITION_KEEP" ]]; then
  GLTF_ARGS+=("--transition-keep" "$TRANSITION_KEEP")
fi
if [[ -n "$OUTER_KEEP" ]]; then
  GLTF_ARGS+=("--outer-keep" "$OUTER_KEEP")
fi
if $HIDE_LEFT_PANEL; then
  GLTF_ARGS+=("--hide-left-panel")
fi
if [[ ${#FORWARD_ARGS[@]} -gt 0 ]]; then
  GLTF_ARGS+=("${FORWARD_ARGS[@]}")
fi
GLTF_ARGS+=("$SCENE")

echo "=============================================="
echo " monitor.sh - Timed Benchmark + Resource Logger"
echo "=============================================="
echo " Output file : $OUTFILE"
echo " Runtime     : ${DURATION}s"
echo " Interval    : ${INTERVAL}s"
echo " Viewer      : $VIEWER"
echo " Scene       : $SCENE"
echo "----------------------------------------------"
echo " CPU usage   : yes"
echo " CPU freq    : yes"
echo " CPU temp    : $HAS_SENSORS"
echo " Memory      : yes"
echo " Power (W)   : $HAS_POWERSTAT"
echo " GPU         : $HAS_NVIDIA"
echo "=============================================="
echo

echo "Starting gltf_viewer..."
"$VIEWER" "${GLTF_ARGS[@]}" > "${OUTFILE%.csv}_viewer.log" 2>&1 &
VIEWER_PID=$!

sleep 1
if ! kill -0 "$VIEWER_PID" 2>/dev/null; then
  echo "Error: gltf_viewer exited immediately. Check ${OUTFILE%.csv}_viewer.log"
  cleanup 1
fi

echo "Monitoring for ${DURATION}s..."
START_TIME=$(date +%s)

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TIME))
  TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

  if ! kill -0 "$VIEWER_PID" 2>/dev/null; then
    echo
    echo "gltf_viewer exited before runtime completed."
    cleanup 0
  fi

  cpu_usage=$(get_cpu_usage)
  cpu_idl=$(echo "$cpu_usage" | cut -d, -f3)
  cpu_freq=$(get_cpu_freq)

  mem=$(free -m | awk '
    /^Mem:/  { printf "%s,%s,%s,%s,", $2, $3, $4, $6 }
    /^Swap:/ { print $3 }
  ')

  read -r load1 load5 load15 procs _ < /proc/loadavg
  procs_running="${procs%/*}"
  procs_total="${procs#*/}"

  ROW="\"$TIMESTAMP\",$ELAPSED"
  ROW+=",$cpu_usage"
  ROW+=",$cpu_freq"
  ROW+=",$mem"
  ROW+=",$load1,$load5,$load15"
  ROW+=",$procs_running,$procs_total"

  if $HAS_POWERSTAT; then
    ROW+=",$(get_cpu_power)"
  fi

  if $HAS_SENSORS; then
    ROW+=",$(get_cpu_temp)"
  fi

  if $HAS_NVIDIA; then
    gpu=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,power.draw,temperature.gpu,clocks.sm,clocks.mem --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' | sed 's/W//')
    [[ -z "$gpu" ]] && gpu="0,0,0,0,0,0,0"
    ROW+=",$gpu"
  fi

  echo "$ROW" >> "$OUTFILE"

  printf "\r[+%3ds/%3ds] CPU idle: %s%% | Freq: %s MHz | RAM used: %s MB | Load: %s" \
    "$ELAPSED" "$DURATION" "$cpu_idl" "$(echo "$cpu_freq" | cut -d, -f1)" "$(echo "$mem" | cut -d, -f2)" "$load1"

  if [[ "$ELAPSED" -ge "$DURATION" ]]; then
    echo
    echo "Runtime reached (${DURATION}s). Stopping..."
    cleanup 0
  fi

  sleep "$INTERVAL"
done
