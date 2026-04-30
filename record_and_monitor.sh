#!/usr/bin/env bash
set -euo pipefail

# record_and_monitor.sh
# Usage: ./record_and_monitor.sh [--runtime N] [--output-dir DIR] [--video-size WxH] [--framerate N] [--sudo-monitor]
#        -- [monitor args...]

RUNTIME=60
OUTDIR=benchmarks/baseline_off
VIDEO_SIZE="1920x1080"
FRAMERATE=30
USE_SUDO_MONITOR=0
MONITOR_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)
      RUNTIME="$2"; shift 2;;
    --output-dir)
      OUTDIR="$2"; shift 2;;
    --video-size)
      VIDEO_SIZE="$2"; shift 2;;
    --framerate)
      FRAMERATE="$2"; shift 2;;
    --sudo-monitor)
      USE_SUDO_MONITOR=1; shift;;
    --)
      shift; MONITOR_ARGS=("$@"); break;;
    *)
      # forward unknown args to monitor
      MONITOR_ARGS+=("$1"); shift;;
  esac
done

mkdir -p "$OUTDIR"
TS=$(date +%Y%m%d_%H%M%S)
VIDEO_OUT="$OUTDIR/screen_capture_${TS}.mkv"

# detect X11
if [[ -z "${DISPLAY-}" ]]; then
  echo "No DISPLAY set. This script currently supports X11 (x11grab)." >&2
  exit 1
fi

# Sanitize DISPLAY for ffmpeg x11grab. ffmpeg prefers ":0.0" style (strip hostname like "localhost:")
FF_DISPLAY="$DISPLAY"
if [[ "$FF_DISPLAY" == *:* && "$FF_DISPLAY" != :* ]]; then
  FF_DISPLAY=":${FF_DISPLAY#*:}"
fi

# Try to auto-detect screen resolution so we don't request a capture area outside the screen.
SCREEN_RES=""
if command -v xdpyinfo >/dev/null 2>&1; then
  SCREEN_RES=$(xdpyinfo | awk '/dimensions:/ {print $2; exit}') || true
fi
if [[ -z "$SCREEN_RES" && $(command -v xrandr >/dev/null 2>&1; echo $?) -eq 0 ]]; then
  SCREEN_RES=$(xrandr | awk '/\*/ {print $1; exit}') || true
fi
if [[ -n "$SCREEN_RES" ]]; then
  SCREEN_W=${SCREEN_RES%x*}
  SCREEN_H=${SCREEN_RES#*x}
  # parse requested VIDEO_SIZE
  REQ_W=${VIDEO_SIZE%x*}
  REQ_H=${VIDEO_SIZE#*x}
  if [[ $REQ_W -gt $SCREEN_W || $REQ_H -gt $SCREEN_H ]]; then
    echo "Requested video size $VIDEO_SIZE exceeds detected screen ${SCREEN_W}x${SCREEN_H}, clamping to screen size."
    VIDEO_SIZE="${SCREEN_W}x${SCREEN_H}"
  fi
fi

MON_CMD=("./monitor.sh" "--runtime" "$RUNTIME" "--output-dir" "$OUTDIR" "${MONITOR_ARGS[@]}")
if [[ $USE_SUDO_MONITOR -eq 1 ]]; then
  # run monitor with sudo while exporting DISPLAY/XAUTHORITY
  MON_CMD=(sudo "DISPLAY=$DISPLAY" "XAUTHORITY=${XAUTHORITY-}" "${MON_CMD[@]}")
fi

# cleanup function
pids=()
trap 'echo "Cleaning up..."; for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done' EXIT

# start monitor
echo "Starting monitor: ${MON_CMD[*]}"
"${MON_CMD[@]}" &
MON_PID=$!
pids+=("$MON_PID")

# start ffmpeg recording (x11grab)
echo "Starting ffmpeg recording to $VIDEO_OUT"
ffmpeg -y -video_size "$VIDEO_SIZE" -framerate "$FRAMERATE" -f x11grab -i "$DISPLAY" -t "$RUNTIME" "$VIDEO_OUT" &
FFMPEG_PID=$!
pids+=("$FFMPEG_PID")

# wait for monitor to finish, then ensure ffmpeg stopped
wait "$MON_PID" || true
sleep 1
if kill -0 "$FFMPEG_PID" 2>/dev/null; then
  echo "Stopping ffmpeg..."
  kill "$FFMPEG_PID" || true
  wait "$FFMPEG_PID" || true
fi

echo "Run complete. Outputs in: $OUTDIR"

echo "Done. CSV(s) from monitor.sh and video: $VIDEO_OUT"
